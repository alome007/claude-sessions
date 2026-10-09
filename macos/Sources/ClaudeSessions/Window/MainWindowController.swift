import AppKit
import ClaudeSessionsCore

enum Mode: Int { case sessions, plans }

final class MainWindowController: NSWindowController, ToolbarControllerDelegate, SidebarControllerDelegate,
                                  ResultsControllerDelegate, PlanReaderControllerDelegate {
	let toolbarController = ToolbarController()
	let sidebar = SidebarController()
	let results: ResultsController
	let reader: PlanReaderController
	let store: PlanStore
	private(set) var mode = Mode.sessions
	private let paths: ClaudePaths
	private let work = DispatchQueue(label: "index", qos: .userInitiated)
	private var index: SessionIndex?
	private var projects: [(path: String, count: Int)] = []
	private var detailItem: NSSplitViewItem!

	init(paths: ClaudePaths) {
		self.paths = paths
		store = PlanStore(paths: paths)
		results = ResultsController(transcripts: Transcripts(root: paths.projects))
		reader = PlanReaderController(store: store)
		let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
		                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
		                      backing: .buffered, defer: false)
		super.init(window: window)
		shouldCascadeWindows = false
		toolbarController.delegate = self
		sidebar.delegate = self
		results.delegate = self
		reader.delegate = self
		buildWindow(window)
	}
	required init?(coder: NSCoder) { fatalError() }

	private func buildWindow(_ window: NSWindow) {
		window.title = "Claude Sessions"
		window.minSize = NSSize(width: 760, height: 420)
		window.center()
		window.toolbarStyle = .unified

		let split = NSSplitViewController()
		let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
		sidebarItem.minimumThickness = 210
		sidebarItem.maximumThickness = 320
		sidebarItem.canCollapse = true
		split.addSplitViewItem(sidebarItem)
		let listItem = NSSplitViewItem(viewController: results)
		listItem.minimumThickness = 320
		split.addSplitViewItem(listItem)
		detailItem = NSSplitViewItem(viewController: reader)
		detailItem.minimumThickness = 360
		detailItem.isCollapsed = true
		split.addSplitViewItem(detailItem)
		window.contentViewController = split
		window.setContentSize(NSSize(width: 1120, height: 720))
		window.center()
		window.toolbar = toolbarController.makeToolbar()
	}

	func present() {
		window?.makeKeyAndOrderFront(nil)
		window?.makeFirstResponder(toolbarController.search)
	}

	func start() {
		window?.subtitle = "Indexing transcripts..."
		indexing("Indexing Claude Code transcripts") {
			let index = SessionIndex(paths: self.paths)
			self.index = index
			index.refresh { done, total in
				DispatchQueue.main.async { self.window?.subtitle = "Indexing \(done) of \(total)..." }
			}
			let found = index.projectCounts(), names = index.branchList()
			DispatchQueue.main.async {
				self.projects = found
				self.reader.projects = found
				self.loadPlans()
				self.toolbarController.setBranches(names)
				self.sidebar.update(projects: found, archived: self.store.archived)
				self.reload()
			}
		}
	}

	private func indexing(_ reason: String, _ body: @escaping () -> Void) {
		work.async { ProcessInfo.processInfo.performActivity(options: .userInitiated, reason: reason, using: body) }
	}

	private func loadPlans() {
		store.load()
		let missing = store.unresolved
		if !missing.isEmpty {
			indexing("Finding the project that wrote each plan") {
				guard let found = self.index?.writersOf(missing) else { return }
				DispatchQueue.main.async { self.store.applyScan(found); self.reload() }
			}
		}
	}

	func reload() {
		if mode == .plans { return reloadPlans() }
		let query = toolbarController.query, role = toolbarController.role
		let project = sidebar.selectedProject, hidden = store.archived
		let hiddenCount = projects.filter { hidden.contains($0.path) }.reduce(0) { $0 + $1.count }
		let branch = toolbarController.branch
		let days = toolbarController.days, sort = toolbarController.sort
		work.async {
			guard let index = self.index else { return }
			let found = index.search(query: query, role: role, project: project, hidden: hidden,
			                         branch: branch, days: days, sort: sort)
			let total = index.total() - hiddenCount
			DispatchQueue.main.async {
				self.results.showSessions(found)
				self.window?.subtitle = found.count == total
					? "\(total) sessions"
					: "\(found.count) of \(total) sessions"
			}
		}
	}

	private func reloadPlans() {
		let needle = toolbarController.query.lowercased()
		let project = sidebar.selectedProject, hidden = store.archived
		let shown = store.plans.filter { plan in
			(project.isEmpty ? !hidden.contains(plan.project) : plan.project == project)
				&& (needle.isEmpty || plan.title.lowercased().contains(needle)
					|| plan.body.lowercased().contains(needle)
					|| plan.tags.contains { $0.lowercased().contains(needle) })
		}
		results.showPlans(shown)
		window?.subtitle = shown.count == store.plans.count
			? "\(store.plans.count) plans"
			: "\(shown.count) of \(store.plans.count) plans"
		if let id = reader.shownPlan { results.select(planID: id, reveal: false) }
	}

	private func confirmDelete(_ ids: [String]) {
		let alert = NSAlert()
		alert.messageText = ids.count == 1
			? "Delete this plan?" : "Delete \(ids.count) plans?"
		alert.informativeText = "The markdown file is removed from ~/.claude/plans. This cannot be undone."
		alert.addButton(withTitle: "Delete")
		alert.addButton(withTitle: "Cancel")
		alert.alertStyle = .warning
		guard alert.runModal() == .alertFirstButtonReturn else { return }
		store.delete(ids)
		reader.forgetShownPlan()
		reload()
	}

	@objc func rebuild() {
		window?.subtitle = "Rebuilding index..."
		indexing("Rebuilding the transcript index") {
			guard let index = self.index else { return }
			index.clear()
			index.refresh { done, total in
				DispatchQueue.main.async { self.window?.subtitle = "Indexing \(done) of \(total)..." }
			}
			DispatchQueue.main.async { self.reload() }
		}
	}

	@objc func focusSearch() {
		window?.makeFirstResponder(toolbarController.search)
	}

	@objc func copySelected() {
		results.copySelected()
	}

	@objc func copyResume() {
		results.copyResume()
	}

	func toolbarFiltersDidChange() {
		reload()
	}

	func toolbarDidRequestRebuild() {
		rebuild()
	}

	func sidebarSelectionDidChange() {
		reload()
	}

	func sidebar(didSwitchTo mode: Mode) {
		self.mode = mode
		results.mode = mode
		toolbarController.showPlaceholder(for: mode)
		detailItem.isCollapsed = mode == .sessions
		reload()
	}

	func sidebar(didToggleArchiveFor path: String) {
		let archiving = !store.archived.contains(path)
		store.setArchived(path, archiving)
		sidebar.update(projects: projects, archived: store.archived)
		reload()
		window?.subtitle = "\(archiving ? "Archived" : "Unarchived") \((path as NSString).lastPathComponent)"
	}

	func results(didSelect plan: Plan) {
		reader.show(plan)
	}

	func results(didRequestDeleting ids: [String]) {
		confirmDelete(ids)
	}

	func results(showNote note: String) {
		window?.subtitle = note
	}

	func readerDidChangePlan() {
		reload()
	}

	func readerDidSaveBody() {
		loadPlans()
		reload()
	}

	func reader(didOpenRelated id: String) {
		results.select(planID: id, reveal: true)
	}

	func reader(didRequestDeleting ids: [String]) {
		confirmDelete(ids)
	}
}
