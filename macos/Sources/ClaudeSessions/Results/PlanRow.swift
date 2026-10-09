import AppKit

final class PlanRow: NSTableCellView {
	let titleField = makeLabel(13, .medium, .labelColor)
	let subField = makeLabel(11, .regular, .secondaryLabelColor)
	let pinField = makeLabel(11, .regular, .secondaryLabelColor, align: .right)
	let progress = NSProgressIndicator()

	override init(frame: NSRect) {
		super.init(frame: frame)
		progress.isIndeterminate = false
		progress.minValue = 0
		progress.maxValue = 1
		progress.controlSize = .small
		[titleField, subField, pinField].forEach(addSubview)
		addSubview(progress)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layout() {
		let width = bounds.width, top = bounds.height - 19
		titleField.frame = NSRect(x: 0, y: top, width: max(40, width - 22), height: 16)
		pinField.frame = NSRect(x: width - 20, y: top, width: 20, height: 16)
		subField.frame = NSRect(x: 0, y: top - 16, width: width, height: 14)
		progress.frame = NSRect(x: 0, y: top - 26, width: width, height: 6)
		progress.isHidden = progress.doubleValue <= 0
	}
}
