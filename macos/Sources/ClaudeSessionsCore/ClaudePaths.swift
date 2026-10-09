import Foundation

public struct ClaudePaths {
	public let projects: URL
	public let index: URL
	public let plans: URL

	public init(projects: URL, index: URL, plans: URL) {
		self.projects = projects
		self.index = index
		self.plans = plans
	}

	public var sidecar: URL { plans.appendingPathComponent(".plan-manager.json") }

	public static func under(home: URL) -> ClaudePaths {
		let claude = home.appendingPathComponent(".claude")
		return ClaudePaths(projects: claude.appendingPathComponent("projects"),
		                   index: claude.appendingPathComponent("session-index.db"),
		                   plans: claude.appendingPathComponent("plans"))
	}

	public static let standard = under(home: FileManager.default.homeDirectoryForCurrentUser)
}
