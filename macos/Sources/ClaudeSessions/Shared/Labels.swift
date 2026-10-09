import AppKit

func makeLabel(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
               mono: Bool = false, align: NSTextAlignment = .left) -> NSTextField {
	let field = NSTextField(labelWithString: "")
	field.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight)
	                  : .systemFont(ofSize: size, weight: weight)
	field.textColor = color
	field.alignment = align
	field.lineBreakMode = .byTruncatingTail
	return field
}

func highlighted(_ raw: String) -> NSAttributedString {
	let out = NSMutableAttributedString()
	let plain: [NSAttributedString.Key: Any] = [
		.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
	let marked: [NSAttributedString.Key: Any] = [
		.font: NSFont.systemFont(ofSize: 11, weight: .medium),
		.foregroundColor: NSColor.labelColor,
		.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.22)]
	var inMark = false
	for chunk in raw.split(omittingEmptySubsequences: false, whereSeparator: {
		$0 == "\u{1}" || $0 == "\u{2}" }) {
		out.append(NSAttributedString(string: String(chunk), attributes: inMark ? marked : plain))
		inMark.toggle()
	}
	return out
}
