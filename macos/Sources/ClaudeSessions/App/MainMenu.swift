import AppKit

enum MainMenu {
	static func make() -> NSMenu {
		let main = NSMenu()
		main.addItem(submenu(appMenu()))
		main.addItem(submenu(editMenu()))
		main.addItem(submenu(viewMenu()))
		return main
	}

	private static func submenu(_ menu: NSMenu) -> NSMenuItem {
		let item = NSMenuItem()
		item.submenu = menu
		return item
	}

	private static func appMenu() -> NSMenu {
		let menu = NSMenu()
		menu.addItem(withTitle: "About Claude Sessions",
		             action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
		menu.addItem(.separator())
		menu.addItem(withTitle: "Rebuild Index", action: #selector(MainWindowController.rebuild), keyEquivalent: "r")
		menu.addItem(.separator())
		menu.addItem(withTitle: "Hide Claude Sessions", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
		menu.addItem(withTitle: "Quit Claude Sessions", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		return menu
	}

	private static func editMenu() -> NSMenu {
		let menu = NSMenu(title: "Edit")
		menu.addItem(withTitle: "Copy Session ID", action: #selector(MainWindowController.copySelected), keyEquivalent: "c")
		menu.addItem(withTitle: "Copy Resume Command", action: #selector(MainWindowController.copyResume), keyEquivalent: "C")
		menu.addItem(withTitle: "Find", action: #selector(MainWindowController.focusSearch), keyEquivalent: "f")
		return menu
	}

	private static func viewMenu() -> NSMenu {
		let menu = NSMenu(title: "View")
		menu.addItem(withTitle: "Toggle Sidebar",
		             action: #selector(NSSplitViewController.toggleSidebar(_:)), keyEquivalent: "s")
		return menu
	}
}
