import Foundation
import SQLite3

extension SessionIndex {
	func terms(_ text: String) -> [String] {
		var out: [String] = [], current = "", quoting = false
		func flush() {
			let token = current.trimmingCharacters(in: .whitespaces)
			current = ""
			guard !token.isEmpty else { return }
			out.append(token.hasSuffix("*") && !quoting
				? "\"\(token.dropLast())\"*" : "\"\(token)\"")
		}
		for character in text {
			if character == "\"" {
				flush(); quoting.toggle()
			} else if character == " " && !quoting {
				flush()
			} else {
				current.append(character)
			}
		}
		flush()
		return out
	}

	public func search(query: String, role: String, project: String, hidden: Set<String>, branch: String,
	                   days: [String], sort: Int) -> [Session] {
		var all: [String: Session] = [:]
		db.each("select id, title, project, branch, modified, size, turns, days from sessions") { row in
			var session = Session()
			session.id = column(row, 0); session.title = column(row, 1)
			session.project = column(row, 2); session.branch = column(row, 3)
			session.modified = sqlite3_column_double(row, 4)
			session.size = Int(sqlite3_column_int64(row, 5))
			session.turns = Int(sqlite3_column_int64(row, 6))
			session.days = column(row, 7)
			all[session.id] = session
		}

		var keep: [Session]
		let wanted = terms(query)
		if wanted.isEmpty {
			keep = Array(all.values)
		} else {
			let filter = role.isEmpty ? "" : " and role = ?"
			let extra = role.isEmpty ? [] : [role]
			var counts: [[String: Int]] = []
			for term in wanted {
				var found: [String: Int] = [:]
				db.each("select sid, count(*) from msgs where msgs match ?\(filter) group by sid",
				        [term] + extra) { found[column($0, 0)] = Int(sqlite3_column_int64($0, 1)) }
				counts.append(found)
			}
			guard var common = counts.first.map({ Set($0.keys) }) else { return [] }
			for found in counts.dropFirst() { common.formIntersection(found.keys) }

			let pick = wanted[counts.firstIndex(where: { $0.count == counts.map(\.count).min() }) ?? 0]
			var snippets: [String: String] = [:]
			db.each("select sid, snippet(msgs, 0, char(1), char(2), '...', 14) from msgs"
				+ " where msgs match ?\(filter) order by rank", [pick] + extra) { row in
				let sid = column(row, 0)
				if snippets[sid] == nil { snippets[sid] = column(row, 1) }
			}
			keep = common.compactMap { sid in
				guard var session = all[sid] else { return nil }
				session.hits = counts.reduce(0) { $0 + ($1[sid] ?? 0) }
				session.snippet = snippets[sid] ?? ""
				return session
			}
		}

		if !days.isEmpty { keep = keep.filter { session in days.contains { session.days.contains($0) } } }
		keep = project.isEmpty
			? keep.filter { !hidden.contains(repoOf($0.project)) }
			: keep.filter { repoOf($0.project) == project }
		if !branch.isEmpty { keep = keep.filter { $0.branch == branch } }

		switch sort {
		case 1: keep.sort { $0.modified > $1.modified }
		case 2: keep.sort { $0.hits > $1.hits }
		case 3: keep.sort { $0.turns > $1.turns }
		default: wanted.isEmpty ? keep.sort { $0.modified > $1.modified }
		                        : keep.sort { $0.hits > $1.hits }
		}
		return keep
	}
}
