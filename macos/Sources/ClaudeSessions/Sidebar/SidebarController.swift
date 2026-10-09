import AppKit

protocol SidebarControllerDelegate: AnyObject {
	func sidebarSelectionDidChange()
	func sidebar(didSwitchTo mode: Mode)
	func sidebar(didToggleArchiveFor path: String)
}

final class SidebarController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
	weak var delegate: SidebarControllerDelegate?
	let table = NSTableView()
	let modeSwitch = NSSegmentedControl(labels: ["Sessions", "Plans"],
	                                    trackingMode: .selectOne, target: nil, action: nil)
	private var rows: [SideRow] = [.all]
	private var projects: [(path: String, count: Int)] = []
	private var archived: Set<String> = []
	private var showArchived = false

	var selectedProject: String {
		let row = table.selectedRow
		guard row >= 0, row < rows.count, case .project(let path, _, _) = rows[row] else { return "" }
		return path
	}

	override func loadView() {
		table.addTableColumn(NSTableColumn(identifier: .init("project")))
		table.headerView = nil
		table.style = .sourceList
		table.rowHeight = 24
		table.dataSource = self
		table.delegate = self
		table.selectionHighlightStyle = .regular
		let menu = NSMenu()
		menu.delegate = self
		table.menu = menu

		let scroll = NSScrollView()
		scroll.documentView = table
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		scroll.automaticallyAdjustsContentInsets = true

		modeSwitch.selectedSegment = 0
		modeSwitch.segmentDistribution = .fillEqually
		modeSwitch.target = self
		modeSwitch.action = #selector(modeChanged)
		modeSwitch.translatesAutoresizingMaskIntoConstraints = false
		scroll.translatesAutoresizingMaskIntoConstraints = false

		let container = NSView()
		container.addSubview(scroll)
		container.addSubview(modeSwitch)
		NSLayoutConstraint.activate([
			scroll.topAnchor.constraint(equalTo: container.topAnchor),
			scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			scroll.bottomAnchor.constraint(equalTo: modeSwitch.topAnchor, constant: -10),
			modeSwitch.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
			modeSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
			modeSwitch.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
		])
		view = container
	}

	func update(projects: [(path: String, count: Int)], archived: Set<String>) {
		self.projects = projects
		self.archived = archived
		if archived.isEmpty { showArchived = false }
		rebuildRows()
	}

	private func rebuildRows() {
		let keep = selectedProject
		rows = [.all] + projects.filter { !archived.contains($0.path) }
			.map { .project(path: $0.path, count: $0.count, archived: false) }
		let archivedProjects = projects.filter { archived.contains($0.path) }
		if !archivedProjects.isEmpty {
			rows.append(.archivedHeader(count: archivedProjects.count))
			if showArchived {
				rows += archivedProjects.map { .project(path: $0.path, count: $0.count, archived: true) }
			}
		}
		table.reloadData()
		let row = rows.firstIndex {
			if case .project(let path, _, _) = $0 { return path == keep }
			return false
		} ?? 0
		table.selectRowIndexes([row], byExtendingSelection: false)
	}

	@objc func modeChanged() {
		delegate?.sidebar(didSwitchTo: Mode(rawValue: modeSwitch.selectedSegment) ?? .sessions)
	}

	@objc func toggleArchive(_ sender: NSMenuItem) {
		guard let path = sender.representedObject as? String else { return }
		delegate?.sidebar(didToggleArchiveFor: path)
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		let row = table.clickedRow
		guard row >= 0, row < rows.count, case .project(let path, _, let archived) = rows[row] else { return }
		let item = NSMenuItem(title: archived ? "Unarchive Project" : "Archive Project",
		                      action: #selector(toggleArchive(_:)), keyEquivalent: "")
		item.target = self
		item.representedObject = path
		menu.addItem(item)
	}

	func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

	func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 24 }

	func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
		guard case .archivedHeader = rows[row] else { return true }
		DispatchQueue.main.async {
			self.showArchived.toggle()
			self.rebuildRows()
		}
		return false
	}

	func tableViewSelectionDidChange(_ note: Notification) {
		delegate?.sidebarSelectionDidChange()
	}

	func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
		let view = tableView.makeView(withIdentifier: .init("side"), owner: self) as? SidebarRow
			?? { let fresh = SidebarRow(); fresh.identifier = .init("side"); return fresh }()
		view.nameField.font = .systemFont(ofSize: 12)
		view.nameField.textColor = .labelColor
		view.nameField.toolTip = nil
		switch rows[row] {
		case .all:
			let visible = rows.reduce(0) { total, entry in
				if case .project(_, let count, false) = entry { return total + count }
				return total
			}
			view.nameField.stringValue = "All projects"
			view.countField.stringValue = "\(visible)"
		case .archivedHeader(let count):
			view.nameField.stringValue = (showArchived ? "\u{25BE}  " : "\u{25B8}  ") + "Archived"
			view.nameField.font = .systemFont(ofSize: 11, weight: .semibold)
			view.nameField.textColor = .secondaryLabelColor
			view.countField.stringValue = "\(count)"
		case .project(let path, let count, let archived):
			view.nameField.stringValue = (path as NSString).lastPathComponent
			view.nameField.textColor = archived ? .secondaryLabelColor : .labelColor
			view.nameField.toolTip = path
			view.countField.stringValue = "\(count)"
		}
		view.needsLayout = true
		return view
	}
}
