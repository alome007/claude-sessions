import AppKit
import ClaudeSessionsCore

final class AppDelegate: NSObject, NSApplicationDelegate {
	private var windowController: MainWindowController?

	func applicationDidFinishLaunching(_ note: Notification) {
		NSApp.mainMenu = MainMenu.make()
		let controller = MainWindowController(paths: .standard)
		windowController = controller
		controller.present()
		controller.start()
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}
