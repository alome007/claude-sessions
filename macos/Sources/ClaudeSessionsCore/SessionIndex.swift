import Foundation
import SQLite3

public final class SessionIndex {
	let db: Database
	public let transcripts: Transcripts

	public init(paths: ClaudePaths) {
		db = Database(path: paths.index.path)
		transcripts = Transcripts(root: paths.projects)
	}

	@discardableResult
	public func refresh(progress: ((Int, Int) -> Void)? = nil) -> Int {
		var known: [String: Double] = [:]
		db.each("select id, indexed from sessions") { known[column($0, 0)] = sqlite3_column_double($0, 1) }

		let groups = transcripts.grouped()
		let stale = groups.filter { sid, urls in
			(known[sid] ?? 0) < newestChange(urls)
		}
		var done = 0
		db.exec("begin")
		for (sid, urls) in stale {
			harvest(sid: sid, urls: urls)
			done += 1
			progress?(done, stale.count)
		}
		for gone in Set(known.keys).subtracting(groups.keys) {
			db.write("delete from msgs where sid = ?", [gone])
			db.write("delete from sessions where id = ?", [gone])
		}
		db.exec("commit")
		return done
	}

	public func clear() {
		db.exec("delete from msgs; delete from sessions;")
	}

	public func projectCounts() -> [(path: String, count: Int)] {
		var counts: [String: Int] = [:]
		db.each("select project from sessions where project != ''") { counts[repoOf(column($0, 0)), default: 0] += 1 }
		return counts
			.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
			.map { (path: $0.key, count: $0.value) }
	}

	public func branchList() -> [String] {
		var out: [String] = []
		db.each("select branch from sessions where branch != '' group by branch order by count(*) desc")
			{ out.append(column($0, 0)) }
		return out
	}

	public func total() -> Int {
		var count = 0
		db.each("select count(*) from sessions") { count = Int(sqlite3_column_int64($0, 0)) }
		return count
	}

	private func newestChange(_ urls: [URL]) -> Double {
		urls.reduce(0.0) { newest, url in
			let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
				.contentModificationDate
			return max(newest, date?.timeIntervalSince1970 ?? 0)
		}
	}

	private func harvest(sid: String, urls: [URL]) {
		var title = "", firstPrompt = "", project = "", branch = ""
		var started = Double.greatestFiniteMagnitude
		var days = Set<String>(), turns = 0, bytes = 0

		db.write("delete from msgs where sid = ?", [sid])
		for url in urls.sorted(by: { $0.path < $1.path }) {
			bytes += (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
			guard let blob = try? Data(contentsOf: url) else { continue }
			for line in blob.split(separator: Needle.newline) {
				if title.isEmpty, Needle.aiTitle.found(in: line) {
					if let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
						let found = record["aiTitle"] as? String { title = found }
				}
				guard Needle.user.found(in: line) || Needle.assistant.found(in: line) else { continue }
				guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
					let role = record["type"] as? String,
					role == "user" || role == "assistant" else { continue }

				let when = parseStamp(record["timestamp"])
				if let when {
					days.insert(dayFormatter.string(from: Date(timeIntervalSince1970: when)))
					started = min(started, when)
				}
				if project.isEmpty { project = record["cwd"] as? String ?? "" }
				if branch.isEmpty { branch = record["gitBranch"] as? String ?? "" }
				for text in spokenText(record["message"]) {
					db.write("insert into msgs(text, sid, role, ts) values (?,?,?,?)",
					         [text, sid, role, when ?? 0])
					if firstPrompt.isEmpty, role == "user" { firstPrompt = String(text.prefix(200)) }
					turns += 1
				}
			}
		}
		let modified = newestChange(urls)
		let name = !title.isEmpty ? title : (!firstPrompt.isEmpty ? firstPrompt : "Untitled session")
		db.write("insert or replace into sessions values (?,?,?,?,?,?,?,?,?,?)",
		         [sid, name, project, branch,
		          started == .greatestFiniteMagnitude ? modified : started,
		          modified, bytes, turns, days.sorted().joined(separator: ","), modified])
	}
}
