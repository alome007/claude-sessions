import Foundation

public struct Plan {
	public var id = "", title = "", body = "", project = "", status = ""
	public var tags: [String] = []
	public var pinned = false, progress = 0.0, modified = 0.0, size = 0
}
