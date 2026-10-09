import Foundation

public struct Transcripts {
	public let root: URL

	public init(root: URL) {
		self.root = root
	}

	public func grouped() -> [String: [URL]] {
		var groups: [String: [URL]] = [:]
		let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
		guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
		else { return groups }
		for case let url as URL in walker where url.pathExtension == "jsonl" {
			let parts = url.pathComponents.suffix(walker.level)
			guard parts.count >= 2 else { continue }
			let sid = parts[parts.startIndex + 1].replacingOccurrences(of: ".jsonl", with: "")
			groups[sid, default: []].append(url)
		}
		return groups
	}

	public func mainTranscript(of sessionID: String) -> URL? {
		grouped()[sessionID]?.min(by: { $0.pathComponents.count < $1.pathComponents.count })
	}
}
