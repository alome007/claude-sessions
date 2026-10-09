import AppKit
import ClaudeSessionsCore

protocol PlanReaderControllerDelegate: AnyObject {
	func readerDidChangePlan()
	func readerDidSaveBody()
	func reader(didOpenRelated id: String)
	func reader(didRequestDeleting ids: [String])
}

final class PlanReaderController: NSViewController, NSTextViewDelegate {
	weak var delegate: PlanReaderControllerDelegate?
	var projects: [(path: String, count: Int)] = []
	private(set) var shownPlan: String?
	private let store: PlanStore
	private let readerTitle = makeLabel(17, .semibold, .labelColor)
	private let readerMeta = makeLabel(11, .regular, .tertiaryLabelColor)
	private let statusPopup = NSPopUpButton(), projectPopup = NSPopUpButton()
	private let pinButton = NSButton(), editButton = NSButton()
	private let tagsField = NSTextField()
	private let reader = NSTextView()
	private let relatedStack = NSStackView()
	private let readerScroll = NSScrollView()
	private var editing = false
	private var progressSave: DispatchWorkItem?
	private var restyle: DispatchWorkItem?

	init(store: PlanStore) {
		self.store = store
		super.init(nibName: nil, bundle: nil)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func loadView() {
		pinButton.bezelStyle = .accessoryBarAction
		pinButton.setButtonType(.toggle)
		pinButton.image = NSImage(systemSymbolName: "pin", accessibilityDescription: "Pin")
		pinButton.alternateImage = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: "Pinned")
		pinButton.target = self
		pinButton.action = #selector(togglePin)

		statusPopup.addItems(withTitles: ["No status", "Active", "Completed"])
		projectPopup.addItem(withTitle: "Unassigned")
		for control in [statusPopup, projectPopup] {
			control.target = self
			control.controlSize = .small
			control.font = .systemFont(ofSize: 11)
		}
		statusPopup.action = #selector(changeStatus)
		projectPopup.action = #selector(changeProject)

		editButton.title = "Edit"
		editButton.bezelStyle = .accessoryBarAction
		editButton.target = self
		editButton.action = #selector(toggleEdit)

		let openButton = NSButton(title: "Open in Editor", target: self, action: #selector(openInEditor))
		let deleteButton = NSButton(title: "Delete", target: self, action: #selector(deleteCurrentPlan))
		for button in [openButton, deleteButton] { button.bezelStyle = .accessoryBarAction }

		tagsField.placeholderString = "tags, comma separated"
		tagsField.font = .systemFont(ofSize: 11)
		tagsField.isBezeled = true
		tagsField.bezelStyle = .roundedBezel
		tagsField.target = self
		tagsField.action = #selector(changeTags)

		_ = reader.layoutManager
		reader.isEditable = false
		reader.isRichText = true
		reader.drawsBackground = false
		reader.delegate = self
		reader.textContainerInset = NSSize(width: 22, height: 18)
		reader.isVerticallyResizable = true
		reader.isHorizontallyResizable = false
		reader.autoresizingMask = [.width]
		reader.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
		                        height: CGFloat.greatestFiniteMagnitude)
		reader.textContainer?.widthTracksTextView = true

		readerScroll.documentView = reader
		readerScroll.hasVerticalScroller = true
		readerScroll.drawsBackground = false
		readerScroll.automaticallyAdjustsContentInsets = true
		readerScroll.contentView.postsBoundsChangedNotifications = true
		NotificationCenter.default.addObserver(
			self, selector: #selector(readerScrolled),
			name: NSView.boundsDidChangeNotification, object: readerScroll.contentView)

		relatedStack.orientation = .horizontal
		relatedStack.spacing = 6

		let controls = NSStackView(views: [pinButton, statusPopup, projectPopup,
		                                   openButton, editButton, deleteButton, NSView()])
		controls.spacing = 7
		let stack = NSStackView(views: [readerTitle, readerMeta, controls, tagsField,
		                                readerScroll, relatedStack])
		stack.orientation = .vertical
		stack.alignment = .leading
		stack.spacing = 8
		stack.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 14, right: 0)
		stack.setHuggingPriority(.defaultLow, for: .vertical)
		stack.translatesAutoresizingMaskIntoConstraints = false
		for label in [readerTitle, readerMeta] {
			label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
			label.setContentHuggingPriority(.defaultLow, for: .horizontal)
			label.cell?.usesSingleLineMode = false
			label.cell?.wraps = true
		}
		tagsField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		relatedStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
		let pinned: [NSView] = [readerTitle, readerMeta, tagsField, readerScroll, controls, relatedStack]
		for view in pinned {
			view.translatesAutoresizingMaskIntoConstraints = false
			view.leadingAnchor.constraint(equalTo: stack.leadingAnchor, constant: 18).isActive = true
			view.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -18).isActive = true
		}
		let container = NSView()
		container.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
			stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
		])
		view = container
	}

	func forgetShownPlan() {
		shownPlan = nil
	}

	func show(_ plan: Plan) {
		shownPlan = plan.id
		editing = false
		editButton.title = "Edit"
		reader.isEditable = false
		readerTitle.stringValue = plan.title
		let stamp = DateFormatter.localizedString(
			from: Date(timeIntervalSince1970: plan.modified), dateStyle: .medium, timeStyle: .short)
		readerMeta.stringValue = "\(plan.id)   \(stamp)   \(plan.size / 1024) KB"
		pinButton.state = plan.pinned ? .on : .off
		statusPopup.selectItem(at: ["": 0, "active": 1, "completed": 2][plan.status] ?? 0)
		projectPopup.removeAllItems()
		projectPopup.addItem(withTitle: "Unassigned")
		projectPopup.addItems(withTitles: projects.map { ($0.path as NSString).lastPathComponent })
		if let at = projects.firstIndex(where: { $0.path == plan.project }) {
			projectPopup.selectItem(at: at + 1)
		}
		tagsField.stringValue = plan.tags.joined(separator: ", ")
		reader.textStorage?.setAttributedString(Markdown.render(plan.body))
		showRelated(to: plan)
		DispatchQueue.main.async {
			let height = self.reader.frame.height - self.readerScroll.contentSize.height
			if plan.progress > 0, height > 0 {
				self.readerScroll.contentView.scroll(to: NSPoint(x: 0, y: height * plan.progress))
			}
		}
	}

	private func showRelated(to plan: Plan) {
		relatedStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
		let related = store.related(to: plan)
		guard !related.isEmpty else { return }
		let caption = makeLabel(11, .regular, .tertiaryLabelColor)
		caption.stringValue = "Related:"
		relatedStack.addArrangedSubview(caption)
		for other in related.prefix(4) {
			let button = NSButton(title: String(other.title.prefix(26)),
			                      target: self, action: #selector(openRelated(_:)))
			button.bezelStyle = .accessoryBarAction
			button.font = .systemFont(ofSize: 11)
			button.identifier = .init(other.id)
			relatedStack.addArrangedSubview(button)
		}
	}

	@objc func openRelated(_ sender: NSButton) {
		guard let id = sender.identifier?.rawValue else { return }
		delegate?.reader(didOpenRelated: id)
	}

	@objc func readerScrolled() {
		guard let id = shownPlan, !editing else { return }
		let height = reader.frame.height - readerScroll.contentSize.height
		guard height > 0 else { return }
		let fraction = min(1, max(0, readerScroll.contentView.bounds.origin.y / height))
		progressSave?.cancel()
		let job = DispatchWorkItem { [weak self] in self?.store.update(id) { $0.progress = fraction } }
		progressSave = job
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: job)
	}

	@objc func togglePin() {
		guard let id = shownPlan else { return }
		store.update(id) { $0.pinned = self.pinButton.state == .on }
		delegate?.readerDidChangePlan()
	}

	@objc func changeStatus() {
		guard let id = shownPlan else { return }
		store.update(id) { $0.status = ["", "active", "completed"][self.statusPopup.indexOfSelectedItem] }
		delegate?.readerDidChangePlan()
	}

	@objc func changeTags() {
		guard let id = shownPlan else { return }
		let tags = tagsField.stringValue.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		store.update(id) { $0.tags = tags }
		delegate?.readerDidChangePlan()
	}

	@objc func changeProject() {
		guard let id = shownPlan, projectPopup.indexOfSelectedItem > 0 else { return }
		store.setProject(id, path: projects[projectPopup.indexOfSelectedItem - 1].path)
		delegate?.readerDidChangePlan()
	}

	@objc func toggleEdit() {
		guard let id = shownPlan, let at = store.index(of: id) else { return }
		editing.toggle()
		editButton.title = editing ? "Save" : "Edit"
		reader.isEditable = editing
		guard let storage = reader.textStorage else { return }
		if editing {
			reader.isAutomaticQuoteSubstitutionEnabled = false
			reader.isAutomaticDashSubstitutionEnabled = false
			reader.isAutomaticTextReplacementEnabled = false
			reader.isAutomaticSpellingCorrectionEnabled = false
			storage.setAttributedString(NSAttributedString(string: store.plans[at].body))
			Markdown.highlight(storage)
			view.window?.makeFirstResponder(reader)
		} else {
			store.save(id, body: reader.string)
			delegate?.readerDidSaveBody()
			if let refreshed = store.plans.first(where: { $0.id == id }) { show(refreshed) }
		}
	}

	func textDidChange(_ note: Notification) {
		guard editing, let storage = reader.textStorage else { return }
		restyle?.cancel()
		let job = DispatchWorkItem { [weak self] in
			guard let self, self.editing else { return }
			let caret = self.reader.selectedRanges
			Markdown.highlight(storage)
			self.reader.selectedRanges = caret
			self.reader.typingAttributes = [.font: Markdown.body,
			                                .foregroundColor: NSColor.labelColor]
		}
		restyle = job
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: job)
	}

	@objc func openInEditor() {
		guard let id = shownPlan else { return }
		NSWorkspace.shared.open(store.file(for: id))
	}

	@objc func deleteCurrentPlan() {
		guard let id = shownPlan else { return }
		delegate?.reader(didRequestDeleting: [id])
	}
}
