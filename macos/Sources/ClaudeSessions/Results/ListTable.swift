import AppKit

final class ListTable: NSTableView {
	var onDelete: (() -> Void)?
	override func keyDown(with event: NSEvent) {
		if event.keyCode == 51 || event.keyCode == 117 { onDelete?() } else { super.keyDown(with: event) }
	}
}
