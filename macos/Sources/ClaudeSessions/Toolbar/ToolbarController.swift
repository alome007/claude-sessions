import AppKit
import ClaudeSessionsCore

protocol ToolbarControllerDelegate: AnyObject {
	func toolbarFiltersDidChange()
	func toolbarDidRequestRebuild()
}

extension NSToolbarItem.Identifier {
	static let search = NSToolbarItem.Identifier("search")
	static let speaker = NSToolbarItem.Identifier("speaker")
	static let branch = NSToolbarItem.Identifier("branch")
	static let sorting = NSToolbarItem.Identifier("sorting")
	static let rebuild = NSToolbarItem.Identifier("rebuild")
	static let when = NSToolbarItem.Identifier("when")
}

final class ToolbarController: NSObject, NSToolbarDelegate, NSSearchFieldDelegate {
	weak var delegate: ToolbarControllerDelegate?
	let search = NSSearchField()
	let speaker = NSPopUpButton(), branches = NSPopUpButton(), sorting = NSPopUpButton()
	let when = NSSegmentedControl(labels: ["Any day", "Today", "Yesterday", "7 days"],
	                              trackingMode: .selectOne, target: nil, action: nil)
	private var branchNames: [String] = []
	private var pending: DispatchWorkItem?
	private var searchItem: NSSearchToolbarItem?

	var query: String { search.stringValue }
	var role: String { ["", "user", "assistant"][speaker.indexOfSelectedItem] }
	var branch: String {
		branches.indexOfSelectedItem > 0 ? branchNames[branches.indexOfSelectedItem - 1] : ""
	}
	var sort: Int { sorting.indexOfSelectedItem }

	var days: [String] {
		let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
		let day = { (back: Int) in
			dayFormatter.string(from: calendar.date(byAdding: .day, value: -back, to: today)!) }
		switch when.selectedSegment {
		case 1: return [day(0)]
		case 2: return [day(1)]
		case 3: return (0..<7).map(day)
		default: return []
		}
	}

	func makeToolbar() -> NSToolbar {
		let toolbar = NSToolbar(identifier: "main")
		toolbar.delegate = self
		toolbar.displayMode = .iconOnly
		toolbar.allowsUserCustomization = false
		return toolbar
	}

	func setBranches(_ names: [String]) {
		branchNames = names
		branches.addItems(withTitles: names)
	}

	func showPlaceholder(for mode: Mode) {
		search.placeholderString = mode == .plans ? "Search plans" : "Search conversations"
	}

	func focusSearch() {
		searchItem?.beginSearchInteraction()
	}

	@objc func filtersChanged() {
		delegate?.toolbarFiltersDidChange()
	}

	@objc func rebuildPressed() {
		delegate?.toolbarDidRequestRebuild()
	}

	func controlTextDidChange(_ note: Notification) {
		pending?.cancel()
		let job = DispatchWorkItem { [weak self] in self?.delegate?.toolbarFiltersDidChange() }
		pending = job
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: job)
	}

	func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		[.toggleSidebar, .sidebarTrackingSeparator, .search, .flexibleSpace,
		 .when, .speaker, .branch, .sorting, .rebuild]
	}

	func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		[.toggleSidebar, .sidebarTrackingSeparator, .search, .flexibleSpace,
		 .when, .speaker, .branch, .sorting, .rebuild]
	}

	func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
	             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
		switch id {
		case .search:
			let item = NSSearchToolbarItem(itemIdentifier: id)
			search.placeholderString = "Search conversations"
			search.delegate = self
			item.searchField = search
			item.resignsFirstResponderWithCancel = true
			searchItem = item
			return item
		case .speaker:
			return popupItem(id, speaker, ["Anyone said", "I said", "Claude said"], width: 116)
		case .branch:
			return popupItem(id, branches, ["Any branch"], width: 132)
		case .sorting:
			return popupItem(id, sorting,
			                 ["Best match", "Most recent", "Most mentions", "Longest"], width: 128)
		case .when:
			when.selectedSegment = 0
			when.controlSize = .regular
			when.target = self
			when.action = #selector(filtersChanged)
			let item = NSToolbarItem(itemIdentifier: id)
			item.view = when
			item.label = "Active"
			return item
		case .rebuild:
			let item = NSToolbarItem(itemIdentifier: id)
			item.label = "Rebuild Index"
			item.toolTip = "Re-read every transcript from scratch"
			item.image = NSImage(systemSymbolName: "arrow.clockwise",
			                     accessibilityDescription: "Rebuild index")
			item.target = self
			item.action = #selector(rebuildPressed)
			item.isBordered = true
			return item
		default:
			return nil
		}
	}

	private func popupItem(_ id: NSToolbarItem.Identifier, _ popup: NSPopUpButton,
	                       _ titles: [String], width: CGFloat) -> NSToolbarItem {
		if popup.numberOfItems == 0 { popup.addItems(withTitles: titles) }
		popup.target = self
		popup.action = #selector(filtersChanged)
		popup.bezelStyle = .toolbar
		popup.controlSize = .regular
		popup.setFrameSize(NSSize(width: width, height: 24))
		let item = NSToolbarItem(itemIdentifier: id)
		item.view = popup
		item.label = titles.first ?? ""
		item.visibilityPriority = .low
		return item
	}
}
