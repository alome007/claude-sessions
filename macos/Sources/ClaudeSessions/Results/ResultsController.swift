import AppKit
import ClaudeSessionsCore

protocol ResultsControllerDelegate: AnyObject {
	func results(didSelect plan: Plan)
	func results(didRequestDeleting ids: [String])
	func results(showNote note: String)
}

final class ResultsController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
	weak var delegate: ResultsControllerDelegate?
	let table = ListTable()
	var mode = Mode.sessions
	private(set) var rows: [Session] = []
	private(set) var plans: [Plan] = []
	private var copiedID: String?
	private let transcripts: Transcripts

	init(transcripts: Transcripts) {
		self.transcripts = transcripts
		super.init(nibName: nil, bundle: nil)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func loadView() {
		let column = NSTableColumn(identifier: .init("session"))
		column.resizingMask = .autoresizingMask
		table.addTableColumn(column)
		table.headerView = nil
		table.style = .inset
		table.rowHeight = 46
		table.usesAlternatingRowBackgroundColors = false
		table.dataSource = self
		table.delegate = self
		table.target = self
		table.doubleAction = #selector(copySelected)
		table.allowsMultipleSelection = true
		table.onDelete = { [weak self] in self?.deleteSelectedPlans() }

		let menu = NSMenu()
		menu.addItem(withTitle: "Copy Session ID", action: #selector(copySelected), keyEquivalent: "")
		menu.addItem(withTitle: "Copy Resume Command", action: #selector(copyResume), keyEquivalent: "")
		menu.addItem(.separator())
		menu.addItem(withTitle: "Show Transcript in Finder", action: #selector(revealTranscript),
		             keyEquivalent: "")
		menu.items.forEach { $0.target = self }
		table.menu = menu

		let scroll = NSScrollView()
		scroll.documentView = table
		scroll.hasVerticalScroller = true
		scroll.drawsBackground = false
		scroll.automaticallyAdjustsContentInsets = true
		view = scroll
	}

	func showSessions(_ sessions: [Session]) {
		rows = sessions
		table.reloadData()
	}

	func showPlans(_ shown: [Plan]) {
		plans = shown
		table.reloadData()
	}

	func select(planID id: String, reveal: Bool) {
		guard let at = plans.firstIndex(where: { $0.id == id }) else { return }
		table.selectRowIndexes([at], byExtendingSelection: false)
		if reveal { table.scrollRowToVisible(at) }
	}

	private var actedRow: Int? {
		let clicked = table.clickedRow
		let row = clicked >= 0 ? clicked : table.selectedRow
		return row >= 0 && row < rows.count ? row : nil
	}

	@objc func copySelected() {
		guard mode == .sessions, let row = actedRow else { return }
		let id = rows[row].id
		put(id, id: id, note: "Copied session id")
	}

	@objc func copyResume() {
		guard mode == .sessions, let row = actedRow else { return }
		let session = rows[row]
		put("cd \(shellQuoted(session.project.isEmpty ? "." : session.project)) && claude --resume \(session.id)",
		    id: session.id, note: "Copied resume command")
	}

	@objc func revealTranscript() {
		guard mode == .sessions, let row = actedRow else { return }
		guard let file = transcripts.mainTranscript(of: rows[row].id) else { return }
		NSWorkspace.shared.activateFileViewerSelecting([file])
	}

	private func deleteSelectedPlans() {
		guard mode == .plans else { return }
		let ids = table.selectedRowIndexes.compactMap { $0 < plans.count ? plans[$0].id : nil }
		if !ids.isEmpty { delegate?.results(didRequestDeleting: ids) }
	}

	private func put(_ text: String, id: String, note: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
		delegate?.results(showNote: note)
		copiedID = id
		flashRow(of: id)
		let job = DispatchWorkItem { [weak self] in
			guard let self else { return }
			self.copiedID = nil
			self.flashRow(of: id)
			self.delegate?.results(showNote: "\(self.rows.count) sessions")
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: job)
	}

	private func flashRow(of id: String) {
		guard let row = rows.firstIndex(where: { $0.id == id }) else { return }
		table.reloadData(forRowIndexes: [row], columnIndexes: [0])
	}

	func numberOfRows(in tableView: NSTableView) -> Int {
		mode == .plans ? plans.count : rows.count
	}

	func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
		if mode == .plans { return 52 }
		return rows[row].snippet.isEmpty ? 44 : 62
	}

	func tableViewSelectionDidChange(_ note: Notification) {
		guard mode == .plans, table.selectedRow >= 0, table.selectedRow < plans.count else { return }
		delegate?.results(didSelect: plans[table.selectedRow])
	}

	func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
		mode == .plans ? planView(tableView, plans[row]) : sessionView(tableView, rows[row])
	}

	private func planView(_ tableView: NSTableView, _ plan: Plan) -> NSView {
		let view = tableView.makeView(withIdentifier: .init("plan"), owner: self) as? PlanRow
			?? { let fresh = PlanRow(); fresh.identifier = .init("plan"); return fresh }()
		view.titleField.stringValue = plan.title
		view.pinField.stringValue = plan.pinned ? "\u{25CF}" : ""
		var detail = [(plan.project as NSString).lastPathComponent]
		if detail[0].isEmpty { detail[0] = "Unassigned" }
		if !plan.status.isEmpty { detail.append(plan.status) }
		if !plan.tags.isEmpty { detail.append(plan.tags.joined(separator: ", ")) }
		detail.append(DateFormatter.localizedString(
			from: Date(timeIntervalSince1970: plan.modified), dateStyle: .medium, timeStyle: .none))
		view.subField.stringValue = detail.joined(separator: "   ")
		view.progress.doubleValue = plan.progress >= 1 ? 0 : plan.progress
		view.needsLayout = true
		return view
	}

	private func sessionView(_ tableView: NSTableView, _ session: Session) -> NSView {
		let view = tableView.makeView(withIdentifier: .init("row"), owner: self) as? SessionRow
			?? { let fresh = SessionRow(); fresh.identifier = .init("row"); return fresh }()
		view.titleField.stringValue = session.title
		let copied = copiedID == session.id
		view.idField.stringValue = copied ? "Copied to clipboard" : session.id
		view.idField.textColor = copied ? .controlAccentColor : .tertiaryLabelColor
		let stamp = DateFormatter.localizedString(
			from: Date(timeIntervalSince1970: session.modified), dateStyle: .medium, timeStyle: .short)
		var detail = [stamp, session.turns == 1 ? "1 message" : "\(session.turns) messages"]
		if !session.branch.isEmpty { detail.append(session.branch) }
		if session.hits > 0 { detail.append("\(session.hits) mentions") }
		view.subField.stringValue = detail.joined(separator: "   ")
		view.snippetField.attributedStringValue = session.snippet.isEmpty
			? NSAttributedString() : highlighted(session.snippet)
		view.needsLayout = true
		return view
	}
}
