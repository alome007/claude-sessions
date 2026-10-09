import Foundation

extension SessionIndex {
	public func writersOf(_ planIds: [String]) -> [String: String] {
		guard !planIds.isEmpty else { return [:] }
		var earliest: [String: (stamp: Double, sid: String)] = [:]
		for (sid, urls) in transcripts.grouped() {
			for url in urls {
				guard let blob = try? Data(contentsOf: url), Needle.plans.found(in: blob) else { continue }
				for line in blob.split(separator: Needle.newline) where Needle.write.found(in: line) {
					for id in planIds where Needle(".claude/plans/\(id).md").found(in: line) {
						guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
							let stamp = parseStamp(record["timestamp"]) else { continue }
						if stamp < (earliest[id]?.stamp ?? .greatestFiniteMagnitude) {
							earliest[id] = (stamp, sid)
						}
					}
				}
			}
		}
		var paths: [String: String] = [:]
		for (id, hit) in earliest {
			db.each("select project from sessions where id = ?", [hit.sid]) { row in
				let project = column(row, 0)
				if !project.isEmpty { paths[id] = project }
			}
		}
		return paths
	}
}
