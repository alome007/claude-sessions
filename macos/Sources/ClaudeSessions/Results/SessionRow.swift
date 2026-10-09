import AppKit

final class SessionRow: NSTableCellView {
	let titleField = makeLabel(13, .medium, .labelColor)
	let idField = makeLabel(11, .regular, .tertiaryLabelColor, mono: true, align: .right)
	let subField = makeLabel(11, .regular, .secondaryLabelColor)
	let snippetField = makeLabel(11, .regular, .secondaryLabelColor)

	override init(frame: NSRect) {
		super.init(frame: frame)
		[titleField, idField, subField, snippetField].forEach(addSubview)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layout() {
		let width = bounds.width, idWidth: CGFloat = 250
		let top = bounds.height - 19
		titleField.frame = NSRect(x: 0, y: top, width: max(80, width - idWidth - 16), height: 16)
		idField.frame = NSRect(x: width - idWidth, y: top, width: idWidth, height: 16)
		subField.frame = NSRect(x: 0, y: top - 17, width: width, height: 14)
		let hasSnippet = snippetField.attributedStringValue.length > 0
		snippetField.isHidden = !hasSnippet
		snippetField.frame = NSRect(x: 0, y: top - 34, width: width, height: 14)
	}
}
