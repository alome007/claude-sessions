from __future__ import annotations

import struct
import sys
import zlib
from pathlib import Path
from typing import List, Tuple

BACKGROUND, ACCENT, DIM = (19, 18, 17), (77, 182, 172), (110, 106, 102)
BARS = [
    (0.28, 0.095, 0.18, 0.64, ACCENT),
    (0.475, 0.075, 0.18, 0.44, DIM),
    (0.605, 0.075, 0.18, 0.56, DIM),
    (0.735, 0.075, 0.18, 0.33, DIM),
]
Image = List[List[Tuple[int, ...]]]


def render(size: int) -> Image:
    pad = size * 0.09
    box = size - 2 * pad
    radius = box * 0.235
    rows = []
    for y in range(size):
        row = []
        for x in range(size):
            ix, iy = x + 0.5 - pad, y + 0.5 - pad
            cx = min(max(ix, radius), box - radius)
            cy = min(max(iy, radius), box - radius)
            inside = 0 <= ix <= box and 0 <= iy <= box and (ix - cx) ** 2 + (iy - cy) ** 2 <= radius ** 2
            pixel = (*BACKGROUND, 255) if inside else (0, 0, 0, 0)
            for top, height, left, width, color in BARS:
                if inside and top * box <= iy < (top + height) * box and left * box <= ix < (left + width) * box:
                    pixel = (*color, 255)
            row.append(pixel)
        rows.append(row)
    return rows


def shrink(rows: Image, factor: int) -> Image:
    size = len(rows) // factor
    out = []
    for y in range(size):
        row = []
        for x in range(size):
            block = [rows[y * factor + j][x * factor + i] for j in range(factor) for i in range(factor)]
            row.append(tuple(sum(pixel[c] for pixel in block) // len(block) for c in range(4)))
        out.append(row)
    return out


def write_png(path: Path, rows: Image) -> None:
    size = len(rows)
    raw = b"".join(b"\x00" + bytes(value for pixel in row for value in pixel) for row in rows)

    def chunk(tag: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data))

    path.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 9))
        + chunk(b"IEND", b"")
    )


def main(iconset: Path) -> None:
    iconset.mkdir(parents=True)
    master = render(1024)
    images = {1024: master}
    for factor in (2, 4, 8, 16, 32, 64):
        images[1024 // factor] = shrink(master, factor)
    for base in (16, 32, 128, 256, 512):
        write_png(iconset / f"icon_{base}x{base}.png", images[base])
        write_png(iconset / f"icon_{base}x{base}@2x.png", images[base * 2])
    print(f"  icon: {len(list(iconset.iterdir()))} sizes")


if __name__ == "__main__":
    main(Path(sys.argv[1]))
