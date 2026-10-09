#!/bin/sh
# Builds "Claude Sessions.app" from ClaudeSessions.swift and installs it to /Applications.
set -e
here=$(cd "$(dirname "$0")" && pwd)
app="/Applications/Claude Sessions.app"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

python3 - "$work" <<'PY'
import struct, sys, zlib
from pathlib import Path

BG, ACCENT, DIM = (19, 18, 17), (77, 182, 172), (110, 106, 102)
BARS = [(0.28, 0.095, 0.18, 0.64, ACCENT),
        (0.475, 0.075, 0.18, 0.44, DIM),
        (0.605, 0.075, 0.18, 0.56, DIM),
        (0.735, 0.075, 0.18, 0.33, DIM)]


def render(size):
	# macOS icons sit inset in their canvas rather than filling it
	pad = size * 0.09
	box = size - 2 * pad
	radius = box * 0.235
	rows = []
	for y in range(size):
		row = []
		for x in range(size):
			ix, iy = x + .5 - pad, y + .5 - pad
			cx = min(max(ix, radius), box - radius)
			cy = min(max(iy, radius), box - radius)
			inside = (0 <= ix <= box and 0 <= iy <= box
			          and (ix - cx) ** 2 + (iy - cy) ** 2 <= radius ** 2)
			pixel = (*BG, 255) if inside else (0, 0, 0, 0)
			for top, height, left, width, color in BARS:
				if inside and top * box <= iy < (top + height) * box \
						and left * box <= ix < (left + width) * box:
					pixel = (*color, 255)
			row.append(pixel)
		rows.append(row)
	return rows


def shrink(rows, factor):
	size = len(rows) // factor
	out = []
	for y in range(size):
		row = []
		for x in range(size):
			block = [rows[y * factor + j][x * factor + i]
			         for j in range(factor) for i in range(factor)]
			row.append(tuple(sum(p[c] for p in block) // len(block) for c in range(4)))
		out.append(row)
	return out


def write_png(path, rows):
	size = len(rows)
	raw = b"".join(b"\x00" + bytes(v for px in row for v in px) for row in rows)
	chunk = lambda tag, data: (struct.pack(">I", len(data)) + tag + data
	                           + struct.pack(">I", zlib.crc32(tag + data)))
	path.write_bytes(b"\x89PNG\r\n\x1a\n"
	                 + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
	                 + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


iconset = Path(sys.argv[1]) / "icon.iconset"
iconset.mkdir(parents=True)
master = render(1024)
images = {1024: master}
for factor in (2, 4, 8, 16, 32, 64):
	images[1024 // factor] = shrink(master, factor)
for base in (16, 32, 128, 256, 512):
	write_png(iconset / f"icon_{base}x{base}.png", images[base])
	write_png(iconset / f"icon_{base}x{base}@2x.png", images[base * 2])
print(f"  icon: {len(list(iconset.iterdir()))} sizes")
PY

iconutil -c icns "$work/icon.iconset" -o "$work/AppIcon.icns"

rm -rf "$work/bundle"
mkdir -p "$work/bundle/Contents/MacOS" "$work/bundle/Contents/Resources"
cp "$work/AppIcon.icns" "$work/bundle/Contents/Resources/"
xcrun swiftc -O -target arm64-apple-macos26.0 \
	"$here/ClaudeSessions.swift" -o "$work/bundle/Contents/MacOS/ClaudeSessions"

cat > "$work/bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
	<key>CFBundleName</key><string>Claude Sessions</string>
	<key>CFBundleDisplayName</key><string>Claude Sessions</string>
	<key>CFBundleIdentifier</key><string>local.claude-sessions</string>
	<key>CFBundleVersion</key><string>1.0</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleExecutable</key><string>ClaudeSessions</string>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>LSMinimumSystemVersion</key><string>26.0</string>
</dict></plist>
PLIST

rm -rf "$app"
cp -R "$work/bundle" "$app"
codesign --force --sign - "$app" 2>/dev/null
touch "$app"
echo "  installed: $app"
