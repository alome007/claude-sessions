import AppKit

final class SidebarRow: NSTableCellView {
	let nameField = makeLabel(12, .regular, .labelColor)
	let countField = makeLabel(11, .regular, .tertiaryLabelColor, align: .right)

	override init(frame: NSRect) {
		super.init(frame: frame)
		addSubview(nameField); addSubview(countField)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layout() {
		let countWidth: CGFloat = 38
		nameField.frame = NSRect(x: 0, y: 3, width: max(20, bounds.width - countWidth - 6), height: 16)
		countField.frame = NSRect(x: bounds.width - countWidth, y: 3, width: countWidth, height: 16)
	}
}

enum SideRow {
	case all
	case project(path: String, count: Int, archived: Bool)
	case archivedHeader(count: Int)
}
