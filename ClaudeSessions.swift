import AppKit
import CryptoKit
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func repoOf(_ path: String) -> String {
	path.components(separatedBy: "/.claude/worktrees/")[0]
}

struct Needle {
	static let newline = UInt8(ascii: "\n")
	static let aiTitle = Needle("\"ai-title\"")
	static let user = Needle("\"user\"")
	static let assistant = Needle("\"assistant\"")
	static let plans = Needle(".claude/plans/")
	static let write = Needle("\"name\":\"Write\"")

	let bytes: [UInt8]
	init(_ text: String) { bytes = Array(text.utf8) }

	func found(in data: Data) -> Bool {
		data.withUnsafeBytes { raw in
			guard let base = raw.baseAddress else { return false }
			return memmem(base, raw.count, bytes, bytes.count) != nil
		}
	}
}

struct Session {
	var id = "", title = "", project = "", branch = "", days = ""
	var modified = 0.0, size = 0, turns = 0, hits = 0, snippet = ""
}

final class Database {
	private var handle: OpaquePointer?

	init(path: String) {
		sqlite3_open(path, &handle)
		exec("""
			create table if not exists sessions(
				id text primary key, title text, project text, branch text,
				started real, modified real, size integer, turns integer,
				days text, indexed real);
			create virtual table if not exists msgs using fts5(
				text, sid unindexed, role unindexed, ts unindexed,
				tokenize='porter unicode61');
		""")
	}

	func exec(_ sql: String) { sqlite3_exec(handle, sql, nil, nil, nil) }

	func each(_ sql: String, _ args: [String] = [], _ body: (OpaquePointer) -> Void) {
		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
		defer { sqlite3_finalize(stmt) }
		for (i, arg) in args.enumerated() {
			sqlite3_bind_text(stmt, Int32(i + 1), arg, -1, SQLITE_TRANSIENT)
		}
		while sqlite3_step(stmt) == SQLITE_ROW { body(stmt!) }
	}

	func write(_ sql: String, _ args: [Any]) {
		var stmt: OpaquePointer?
		guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { return }
		defer { sqlite3_finalize(stmt) }
		for (i, arg) in args.enumerated() {
			let slot = Int32(i + 1)
			switch arg {
			case let value as String: sqlite3_bind_text(stmt, slot, value, -1, SQLITE_TRANSIENT)
			case let value as Int: sqlite3_bind_int64(stmt, slot, Int64(value))
			case let value as Double: sqlite3_bind_double(stmt, slot, value)
			default: sqlite3_bind_null(stmt, slot)
			}
		}
		sqlite3_step(stmt)
	}
}

func column(_ stmt: OpaquePointer, _ i: Int32) -> String {
	guard let text = sqlite3_column_text(stmt, i) else { return "" }
	return String(cString: text)
}

enum Transcripts {
	static let root = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent(".claude/projects")

	/// Every jsonl grouped by the session it belongs to, subagent transcripts included.
	static func grouped() -> [String: [URL]] {
		var groups: [String: [URL]] = [:]
		let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
		guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys)
		else { return groups }
		for case let url as URL in walker where url.pathExtension == "jsonl" {
			let parts = url.pathComponents.suffix(from: root.pathComponents.count)
			guard parts.count >= 2 else { continue }
			let sid = parts[parts.startIndex + 1].replacingOccurrences(of: ".jsonl", with: "")
			groups[sid, default: []].append(url)
		}
		return groups
	}
}

let noise = try! NSRegularExpression(
	pattern: "<system-reminder>.*?</system-reminder>"
		+ "|<command-name>.*?</command-name>"
		+ "|<local-command-stdout>.*?</local-command-stdout>"
		+ "|<command-message>.*?</command-message>"
		+ "|<command-args>.*?</command-args>"
		+ "|<local-command-caveat>.*?</local-command-caveat>"
		+ "|<task-notification>.*?</task-notification>"
		+ "|<persisted-output>.*?</persisted-output>",
	options: [.dotMatchesLineSeparators])

func strip(_ text: String) -> String {
	let cleaned = noise.stringByReplacingMatches(
		in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
	return cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
}

/// Spoken text only: no tool calls, tool results, thinking or injected context.
func spokenText(_ message: Any?) -> [String] {
	guard let message = message as? [String: Any] else { return [] }
	if let single = message["content"] as? String {
		let clean = strip(single)
		return clean.isEmpty ? [] : [clean]
	}
	guard let blocks = message["content"] as? [[String: Any]] else { return [] }
	return blocks.compactMap { block in
		guard block["type"] as? String == "text",
		      let text = block["text"] as? String else { return nil }
		let clean = strip(text)
		return clean.isEmpty ? nil : clean
	}
}

let isoParser: ISO8601DateFormatter = {
	let parser = ISO8601DateFormatter()
	parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
	return parser
}()
let isoPlain = ISO8601DateFormatter()

func parseStamp(_ value: Any?) -> Double? {
	guard let text = value as? String else { return nil }
	if let date = isoParser.date(from: text) ?? isoPlain.date(from: text) {
		return date.timeIntervalSince1970
	}
	return nil
}

let dayFormatter: DateFormatter = {
	let formatter = DateFormatter()
	formatter.dateFormat = "yyyy-MM-dd"
	return formatter
}()

final class Index {
	let db: Database
	static let path = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent(".claude/session-index.db").path

	init() { db = Database(path: Index.path) }

	/// Re-reads only the transcripts whose mtime moved. Returns sessions rebuilt.
	@discardableResult
	func refresh(progress: ((Int, Int) -> Void)? = nil) -> Int {
		var known: [String: Double] = [:]
		db.each("select id, indexed from sessions") { known[column($0, 0)] = sqlite3_column_double($0, 1) }

		let groups = Transcripts.grouped()
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

	/// User text -> safe FTS5 terms. Quoted runs stay phrases, trailing * is a prefix.
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

	func search(query: String, role: String, project: String, hidden: Set<String>, branch: String,
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
			// Each term is matched separately so a session qualifies when every term
			// appears somewhere in it, not all inside one message.
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

		// "active on" is a property of the session, not of the matching message
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

	/// The project that created each plan: the earliest session whose Write tool wrote the file.
	func writersOf(_ planIds: [String]) -> [String: String] {
		guard !planIds.isEmpty else { return [:] }
		var earliest: [String: (stamp: Double, sid: String)] = [:]
		for (sid, urls) in Transcripts.grouped() {
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

	func projectCounts() -> [(path: String, count: Int)] {
		var counts: [String: Int] = [:]
		db.each("select project from sessions where project != ''") { counts[repoOf(column($0, 0)), default: 0] += 1 }
		return counts
			.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
			.map { (path: $0.key, count: $0.value) }
	}

	func branchList() -> [String] {
		var out: [String] = []
		db.each("select branch from sessions where branch != '' group by branch order by count(*) desc")
			{ out.append(column($0, 0)) }
		return out
	}

	func total() -> Int {
		var count = 0
		db.each("select count(*) from sessions") { count = Int(sqlite3_column_int64($0, 0)) }
		return count
	}
}

struct Plan {
	var id = "", title = "", body = "", project = "", status = ""
	var tags: [String] = []
	var pinned = false, progress = 0.0, modified = 0.0, size = 0
}

/// Plans are markdown files; their pins, tags, status and reading position live in the
/// sidecar `.plan-manager.json` that the old Plan Manager app wrote, so nothing is lost.
final class PlanStore {
	static let folder = FileManager.default.homeDirectoryForCurrentUser
		.appendingPathComponent(".claude/plans")
	static let sidecar = folder.appendingPathComponent(".plan-manager.json")

	private(set) var plans: [Plan] = []
	private var meta: [String: Any] = [:]

	private static func readMeta() -> [String: Any] {
		(try? JSONSerialization.jsonObject(with: Data(contentsOf: sidecar))) as? [String: Any] ?? [:]
	}

	func load() {
		meta = PlanStore.readMeta()
		let entries = meta["plans"] as? [String: Any] ?? [:]
		let projects = meta["projects"] as? [String: Any] ?? [:]
		let overrides = meta["planProjectOverrides"] as? [String: String] ?? [:]
		let scanned = (meta["projectScan"] as? [String: Any])?["assignments"] as? [String: String] ?? [:]

		let urls = (try? FileManager.default.contentsOfDirectory(
			at: PlanStore.folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]))
			?? []
		plans = urls.filter { $0.pathExtension == "md" }.map { url in
			var plan = Plan()
			plan.id = url.deletingPathExtension().lastPathComponent
			plan.body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
			plan.title = plan.body.split(separator: "\n")
				.first { $0.hasPrefix("# ") }
				.map { String($0.dropFirst(2)) } ?? plan.id
			let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
			plan.modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
			plan.size = values?.fileSize ?? 0

			let entry = entries[plan.id] as? [String: Any] ?? [:]
			plan.status = entry["status"] as? String ?? ""
			plan.pinned = entry["pinned"] as? Bool ?? false
			plan.tags = entry["tags"] as? [String] ?? []
			plan.progress = entry["readingProgress"] as? Double ?? 0

			if let hash = overrides[plan.id] ?? scanned[plan.id],
			   let record = projects[hash] as? [String: Any],
			   let path = record["path"] as? String {
				plan.project = repoOf(path)
			}
			return plan
		}
		sort()
	}

	private func sort() {
		plans.sort { left, right in
			left.pinned == right.pinned ? left.modified > right.modified : left.pinned
		}
	}

	var unresolved: [String] { plans.filter { $0.project.isEmpty }.map(\.id) }

	/// Records who wrote each plan, so the scan only ever runs once per plan.
	func applyScan(_ found: [String: String]) {
		guard !found.isEmpty else { return }
		meta = PlanStore.readMeta()
		var scan = meta["projectScan"] as? [String: Any] ?? [:]
		var assignments = scan["assignments"] as? [String: String] ?? [:]
		for (id, path) in found {
			assignments[id] = key(for: path)
			if let at = index(of: id) { plans[at].project = repoOf(path) }
		}
		scan["assignments"] = assignments
		scan["scannedAt"] = isoPlain.string(from: Date())
		meta["projectScan"] = scan
		persist()
	}

	private func key(for path: String) -> String {
		var projects = meta["projects"] as? [String: Any] ?? [:]
		if let known = projects.first(where: { ($0.value as? [String: Any])?["path"] as? String == path })?.key {
			return known
		}
		let hash = String(SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
		projects[hash] = ["name": (path as NSString).lastPathComponent, "path": path, "pinned": false]
		meta["projects"] = projects
		return hash
	}

	var archived: Set<String> {
		let projects = meta["projects"] as? [String: Any] ?? [:]
		return Set(projects.values.compactMap { value in
			guard let record = value as? [String: Any], record["archived"] as? Bool == true else { return nil }
			return record["path"] as? String
		})
	}

	func setArchived(_ path: String, _ on: Bool) {
		meta = PlanStore.readMeta()
		let hash = key(for: path)
		var projects = meta["projects"] as? [String: Any] ?? [:]
		var record = projects[hash] as? [String: Any] ?? [:]
		record["archived"] = on
		projects[hash] = record
		meta["projects"] = projects
		persist()
	}

	func index(of id: String) -> Int? { plans.firstIndex { $0.id == id } }

	func update(_ id: String, _ change: (inout Plan) -> Void) {
		guard let at = index(of: id) else { return }
		meta = PlanStore.readMeta()
		change(&plans[at])
		var entries = meta["plans"] as? [String: Any] ?? [:]
		var entry = entries[id] as? [String: Any] ?? [:]
		entry["status"] = plans[at].status
		entry["pinned"] = plans[at].pinned
		entry["tags"] = plans[at].tags
		entry["readingProgress"] = plans[at].progress
		entry["lastReadAt"] = isoPlain.string(from: Date())
		entries[id] = entry
		meta["plans"] = entries
		persist()
		sort()
	}

	func setProject(_ id: String, path: String) {
		guard let at = index(of: id) else { return }
		meta = PlanStore.readMeta()
		plans[at].project = path
		let hash = key(for: path)
		var overrides = meta["planProjectOverrides"] as? [String: String] ?? [:]
		overrides[id] = hash
		meta["planProjectOverrides"] = overrides
		persist()
	}

	func delete(_ ids: [String]) {
		meta = PlanStore.readMeta()
		for id in ids {
			try? FileManager.default.removeItem(
				at: PlanStore.folder.appendingPathComponent("\(id).md"))
		}
		var entries = meta["plans"] as? [String: Any] ?? [:]
		ids.forEach { entries.removeValue(forKey: $0) }
		meta["plans"] = entries
		persist()
		plans.removeAll { ids.contains($0.id) }
	}

	func save(_ id: String, body: String) {
		guard let at = index(of: id) else { return }
		try? body.write(to: PlanStore.folder.appendingPathComponent("\(id).md"),
		                atomically: true, encoding: .utf8)
		plans[at].body = body
	}

	/// Plans sharing this one's project or any of its tags.
	func related(to plan: Plan) -> [Plan] {
		plans.filter {
			$0.id != plan.id
				&& ($0.project == plan.project || !Set($0.tags).isDisjoint(with: plan.tags))
		}
	}

	private func persist() {
		guard let data = try? JSONSerialization.data(
			withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return }
		try? FileManager.default.createDirectory(at: PlanStore.folder, withIntermediateDirectories: true)
		try? data.write(to: PlanStore.sidecar, options: .atomic)
	}
}

func makeLabel(_ size: CGFloat, _ weight: NSFont.Weight, _ color: NSColor,
               mono: Bool = false, align: NSTextAlignment = .left) -> NSTextField {
	let field = NSTextField(labelWithString: "")
	field.font = mono ? .monospacedSystemFont(ofSize: size, weight: weight)
	                  : .systemFont(ofSize: size, weight: weight)
	field.textColor = color
	field.alignment = align
	field.lineBreakMode = .byTruncatingTail
	return field
}

func highlighted(_ raw: String) -> NSAttributedString {
	let out = NSMutableAttributedString()
	let plain: [NSAttributedString.Key: Any] = [
		.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
	let marked: [NSAttributedString.Key: Any] = [
		.font: NSFont.systemFont(ofSize: 11, weight: .medium),
		.foregroundColor: NSColor.labelColor,
		.backgroundColor: NSColor.controlAccentColor.withAlphaComponent(0.22)]
	var inMark = false
	for chunk in raw.split(omittingEmptySubsequences: false, whereSeparator: {
		$0 == "\u{1}" || $0 == "\u{2}" }) {
		out.append(NSAttributedString(string: String(chunk), attributes: inMark ? marked : plain))
		inMark.toggle()
	}
	return out
}

enum Markdown {
	static let body = NSFont.systemFont(ofSize: 13)
	static let mono = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)

	static func render(_ text: String) -> NSAttributedString {
		let out = NSMutableAttributedString()
		let lines = text.components(separatedBy: "\n")
		var at = 0
		while at < lines.count {
			let line = lines[at]
			if line.hasPrefix("```") {
				var code: [String] = []
				at += 1
				while at < lines.count, !lines[at].hasPrefix("```") {
					code.append(lines[at]); at += 1
				}
				at += 1
				out.append(codeBlock(code))
			} else if isTableRow(line), at + 1 < lines.count, isDivider(lines[at + 1]) {
				var rows: [[String]] = [cells(line)]
				at += 2
				while at < lines.count, isTableRow(lines[at]) {
					rows.append(cells(lines[at])); at += 1
				}
				out.append(table(rows))
			} else {
				out.append(block(line))
				at += 1
			}
		}
		return out
	}

	private static func isTableRow(_ line: String) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		return trimmed.hasPrefix("|") && trimmed.dropFirst().contains("|")
	}

	private static func isDivider(_ line: String) -> Bool {
		let trimmed = line.trimmingCharacters(in: .whitespaces)
		return trimmed.hasPrefix("|") && trimmed.allSatisfy { "|-: ".contains($0) }
	}

	private static func cells(_ line: String) -> [String] {
		var parts = line.trimmingCharacters(in: .whitespaces).split(separator: "|",
			omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
		if parts.first?.isEmpty == true { parts.removeFirst() }
		if parts.last?.isEmpty == true { parts.removeLast() }
		return parts
	}

	private static func table(_ rows: [[String]]) -> NSAttributedString {
		let columns = rows.map(\.count).max() ?? 1
		let grid = NSTextTable()
		grid.numberOfColumns = columns
		grid.layoutAlgorithm = .automaticLayoutAlgorithm
		grid.collapsesBorders = true
		grid.hidesEmptyCells = false

		let out = NSMutableAttributedString()
		for (r, row) in rows.enumerated() {
			for column in 0..<columns {
				let cell = NSTextTableBlock(table: grid, startingRow: r, rowSpan: 1,
				                            startingColumn: column, columnSpan: 1)
				cell.setBorderColor(.separatorColor)
				cell.setWidth(1, type: .absoluteValueType, for: .border)
				cell.setWidth(7, type: .absoluteValueType, for: .padding)
				if r == 0 { cell.backgroundColor = .quaternaryLabelColor.withAlphaComponent(0.10) }
				let paragraph = NSMutableParagraphStyle()
				paragraph.textBlocks = [cell]
				paragraph.lineSpacing = 1
				let text = column < row.count ? row[column] : ""
				let attributed = NSMutableAttributedString(attributedString: inline(
					text, font: r == 0 ? .systemFont(ofSize: 12, weight: .semibold)
					                   : .systemFont(ofSize: 12)))
				attributed.append(NSAttributedString(string: "\n"))
				attributed.addAttribute(.paragraphStyle, value: paragraph,
				                        range: NSRange(location: 0, length: attributed.length))
				out.append(attributed)
			}
		}
		out.append(spacer(8))
		return out
	}

	private static func codeBlock(_ lines: [String]) -> NSAttributedString {
		let paragraph = NSMutableParagraphStyle()
		paragraph.firstLineHeadIndent = 14
		paragraph.headIndent = 14
		paragraph.lineSpacing = 1
		let text = lines.joined(separator: "\n")
		let out = NSMutableAttributedString(string: text + "\n", attributes: [
			.font: mono, .foregroundColor: NSColor.labelColor,
			.paragraphStyle: paragraph,
			.backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.12)])
		out.append(spacer(8))
		return out
	}

	private static func spacer(_ height: CGFloat) -> NSAttributedString {
		NSAttributedString(string: "\n", attributes: [.font: NSFont.systemFont(ofSize: height / 2)])
	}

	private static func block(_ line: String) -> NSAttributedString {
		let paragraph = NSMutableParagraphStyle()
		paragraph.lineSpacing = 2.5
		paragraph.paragraphSpacing = 7

		var content = line, font = body, color = NSColor.labelColor
		for (marker, size, weight, space) in [("#### ", 12.5, NSFont.Weight.semibold, 10.0),
		                                      ("### ", 13.5, .semibold, 14.0),
		                                      ("## ", 17.0, .semibold, 18.0),
		                                      ("# ", 22.0, .bold, 10.0)] {
			if line.hasPrefix(marker) {
				content = String(line.dropFirst(marker.count))
				font = .systemFont(ofSize: size, weight: weight)
				paragraph.paragraphSpacingBefore = space
				paragraph.paragraphSpacing = 5
				break
			}
		}
		if font == body {
			let trimmed = line.drop { $0 == " " }
			let depth = (line.count - trimmed.count) / 2
			if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
				content = "\u{2022}  " + String(trimmed.dropFirst(2))
				paragraph.firstLineHeadIndent = 14 + CGFloat(depth) * 18
				paragraph.headIndent = 28 + CGFloat(depth) * 18
				paragraph.paragraphSpacing = 3
			} else if let dot = trimmed.firstIndex(of: "."),
			          trimmed[trimmed.startIndex..<dot].allSatisfy(\.isNumber),
			          !trimmed[trimmed.startIndex..<dot].isEmpty {
				content = String(trimmed)
				paragraph.firstLineHeadIndent = 14 + CGFloat(depth) * 18
				paragraph.headIndent = 30 + CGFloat(depth) * 18
				paragraph.paragraphSpacing = 3
			} else if trimmed.hasPrefix("> ") {
				content = String(trimmed.dropFirst(2))
				color = .secondaryLabelColor
				paragraph.firstLineHeadIndent = 18
				paragraph.headIndent = 18
			} else if trimmed.hasPrefix("---") || trimmed.hasPrefix("***") {
				let rule = NSMutableParagraphStyle()
				rule.paragraphSpacing = 10
				rule.paragraphSpacingBefore = 10
				return NSAttributedString(string: String(repeating: "\u{2500}", count: 60) + "\n",
					attributes: [.font: NSFont.systemFont(ofSize: 9),
					             .foregroundColor: NSColor.quaternaryLabelColor,
					             .paragraphStyle: rule])
			}
		}
		let out = NSMutableAttributedString(attributedString:
			inline(content, font: font, color: color))
		out.append(NSAttributedString(string: "\n"))
		out.addAttribute(.paragraphStyle, value: paragraph,
		                 range: NSRange(location: 0, length: out.length))
		return out
	}

	/// Single pass over `code`, **bold**, *italic* and [text](url).
	static func inline(_ text: String, font: NSFont,
	                   color: NSColor = .labelColor) -> NSAttributedString {
		let out = NSMutableAttributedString()
		let plain: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
		var buffer = ""
		var cursor = text.startIndex

		func flush() {
			if !buffer.isEmpty { out.append(NSAttributedString(string: buffer, attributes: plain)) }
			buffer = ""
		}
		func take(_ open: String, _ close: String) -> String? {
			guard text[cursor...].hasPrefix(open) else { return nil }
			let from = text.index(cursor, offsetBy: open.count)
			guard from < text.endIndex,
			      let end = text.range(of: close, range: from..<text.endIndex) else { return nil }
			cursor = end.upperBound
			return String(text[from..<end.lowerBound])
		}

		while cursor < text.endIndex {
			if let code = take("`", "`") {
				flush()
				out.append(NSAttributedString(string: code, attributes: [
					.font: NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular),
					.foregroundColor: NSColor.systemPink,
					.backgroundColor: NSColor.quaternaryLabelColor.withAlphaComponent(0.14)]))
			} else if let bold = take("**", "**") {
				flush()
				out.append(NSAttributedString(string: bold, attributes: [
					.font: NSFont.systemFont(ofSize: font.pointSize, weight: .bold),
					.foregroundColor: color]))
			} else if text[cursor] == "[", let close = text.range(of: "](", range: cursor..<text.endIndex),
			          let end = text.range(of: ")", range: close.upperBound..<text.endIndex) {
				flush()
				let label = String(text[text.index(after: cursor)..<close.lowerBound])
				let target = String(text[close.upperBound..<end.lowerBound])
				out.append(NSAttributedString(string: label, attributes: [
					.font: font, .foregroundColor: NSColor.linkColor,
					.link: target, .underlineStyle: NSUnderlineStyle.single.rawValue]))
				cursor = end.upperBound
			} else if text[cursor] == "*", let italic = take("*", "*") {
				flush()
				let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
				out.append(NSAttributedString(string: italic, attributes: [
					.font: NSFont(descriptor: descriptor, size: font.pointSize) ?? font,
					.foregroundColor: color]))
			} else {
				buffer.append(text[cursor])
				cursor = text.index(after: cursor)
			}
		}
		flush()
		return out
	}
}

extension Markdown {
	/// Styles raw markdown in place. Characters are never changed, so what gets saved is
	/// exactly what was typed - the syntax stays visible but faint, and content looks rendered.
	static func highlight(_ storage: NSTextStorage) {
		let text = storage.string as NSString
		let whole = NSRange(location: 0, length: text.length)
		storage.beginEditing()
		storage.setAttributes([.font: body, .foregroundColor: NSColor.labelColor], range: whole)

		let faint: [NSAttributedString.Key: Any] = [.foregroundColor: NSColor.tertiaryLabelColor]
		var inFence = false
		text.enumerateSubstrings(in: whole, options: [.byLines, .substringNotRequired]) {
			_, lineRange, _, _ in
			let line = text.substring(with: lineRange)
			let trimmed = line.trimmingCharacters(in: .whitespaces)

			if trimmed.hasPrefix("```") {
				inFence.toggle()
				storage.addAttributes([.font: mono], range: lineRange)
				storage.addAttributes(faint, range: lineRange)
				return
			}
			if inFence {
				storage.addAttributes([.font: mono, .foregroundColor: NSColor.labelColor,
				                       .backgroundColor: NSColor.quaternaryLabelColor
					.withAlphaComponent(0.12)], range: lineRange)
				return
			}
			if trimmed.hasPrefix("|") {
				// monospace makes the pipes line up into columns while staying editable text
				storage.addAttributes([.font: mono], range: lineRange)
				mark(storage, line: line, at: lineRange, pattern: "|", attributes: faint)
				return
			}
			for (marker, size, weight) in [("#### ", 12.5, NSFont.Weight.semibold),
			                               ("### ", 13.5, .semibold),
			                               ("## ", 17.0, .semibold),
			                               ("# ", 22.0, .bold)] where line.hasPrefix(marker) {
				storage.addAttribute(.font, value: NSFont.systemFont(ofSize: size, weight: weight),
				                     range: lineRange)
				storage.addAttributes(faint,
				                      range: NSRange(location: lineRange.location, length: marker.count))
				return
			}
			if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("> ") {
				let offset = line.count - trimmed.count
				storage.addAttributes(faint,
				                      range: NSRange(location: lineRange.location + offset, length: 2))
			}
			span(storage, text: text, line: lineRange, open: "`", close: "`",
			     inner: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
			             .foregroundColor: NSColor.systemPink], marker: faint)
			span(storage, text: text, line: lineRange, open: "**", close: "**",
			     inner: [.font: NSFont.systemFont(ofSize: 13, weight: .bold)], marker: faint)
		}
		storage.endEditing()
	}

	private static func mark(_ storage: NSTextStorage, line: String, at range: NSRange,
	                         pattern: String, attributes: [NSAttributedString.Key: Any]) {
		var search = NSRange(location: range.location, length: range.length)
		let text = storage.string as NSString
		while true {
			let hit = text.range(of: pattern, options: [], range: search)
			guard hit.location != NSNotFound else { return }
			storage.addAttributes(attributes, range: hit)
			let next = hit.location + hit.length
			search = NSRange(location: next, length: max(0, range.location + range.length - next))
			if search.length == 0 { return }
		}
	}

	private static func span(_ storage: NSTextStorage, text: NSString, line: NSRange,
	                         open: String, close: String,
	                         inner: [NSAttributedString.Key: Any],
	                         marker: [NSAttributedString.Key: Any]) {
		var cursor = line.location
		let end = line.location + line.length
		while cursor < end {
			let left = text.range(of: open, options: [],
			                      range: NSRange(location: cursor, length: end - cursor))
			guard left.location != NSNotFound else { return }
			let afterLeft = left.location + left.length
			guard afterLeft < end else { return }
			let right = text.range(of: close, options: [],
			                       range: NSRange(location: afterLeft, length: end - afterLeft))
			guard right.location != NSNotFound else { return }
			storage.addAttributes(inner, range: NSRange(location: afterLeft,
			                                            length: right.location - afterLeft))
			storage.addAttributes(marker, range: left)
			storage.addAttributes(marker, range: right)
			cursor = right.location + right.length
		}
	}
}

final class PlanRow: NSTableCellView {
	let titleField = makeLabel(13, .medium, .labelColor)
	let subField = makeLabel(11, .regular, .secondaryLabelColor)
	let pinField = makeLabel(11, .regular, .secondaryLabelColor, align: .right)
	let progress = NSProgressIndicator()

	override init(frame: NSRect) {
		super.init(frame: frame)
		progress.isIndeterminate = false
		progress.minValue = 0
		progress.maxValue = 1
		progress.controlSize = .small
		[titleField, subField, pinField].forEach(addSubview)
		addSubview(progress)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layout() {
		let width = bounds.width, top = bounds.height - 19
		titleField.frame = NSRect(x: 0, y: top, width: max(40, width - 22), height: 16)
		pinField.frame = NSRect(x: width - 20, y: top, width: 20, height: 16)
		subField.frame = NSRect(x: 0, y: top - 16, width: width, height: 14)
		progress.frame = NSRect(x: 0, y: top - 26, width: width, height: 6)
		progress.isHidden = progress.doubleValue <= 0
	}
}

final class RowView: NSTableCellView {
	let titleField = makeLabel(13, .medium, .labelColor)
	let idField = makeLabel(11, .regular, .tertiaryLabelColor, mono: true, align: .right)
	let subField = makeLabel(11, .regular, .secondaryLabelColor)
	let snippetField = makeLabel(11, .regular, .secondaryLabelColor)

	override init(frame: NSRect) {
		super.init(frame: frame)
		[titleField, idField, subField, snippetField].forEach(addSubview)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layout() {
		let width = bounds.width, idWidth: CGFloat = 250
		let top = bounds.height - 19
		titleField.frame = NSRect(x: 0, y: top, width: max(80, width - idWidth - 16), height: 16)
		idField.frame = NSRect(x: width - idWidth, y: top, width: idWidth, height: 16)
		subField.frame = NSRect(x: 0, y: top - 17, width: width, height: 14)
		let hasSnippet = snippetField.attributedStringValue.length > 0
		snippetField.isHidden = !hasSnippet
		snippetField.frame = NSRect(x: 0, y: top - 34, width: width, height: 14)
	}
}

final class SidebarRow: NSTableCellView {
	let nameField = makeLabel(12, .regular, .labelColor)
	let countField = makeLabel(11, .regular, .tertiaryLabelColor, align: .right)

	override init(frame: NSRect) {
		super.init(frame: frame)
		addSubview(nameField); addSubview(countField)
	}
	required init?(coder: NSCoder) { fatalError() }

	override func layout() {
		let countWidth: CGFloat = 38
		nameField.frame = NSRect(x: 0, y: 3, width: max(20, bounds.width - countWidth - 6), height: 16)
		countField.frame = NSRect(x: bounds.width - countWidth, y: 3, width: countWidth, height: 16)
	}
}

extension NSToolbarItem.Identifier {
	static let search = NSToolbarItem.Identifier("search")
	static let speaker = NSToolbarItem.Identifier("speaker")
	static let branch = NSToolbarItem.Identifier("branch")
	static let sorting = NSToolbarItem.Identifier("sorting")
	static let rebuild = NSToolbarItem.Identifier("rebuild")
	static let when = NSToolbarItem.Identifier("when")
}

/// Forwards the delete key so a multi-row selection can be removed in one go.
final class ListTable: NSTableView {
	var onDelete: (() -> Void)?
	override func keyDown(with event: NSEvent) {
		if event.keyCode == 51 || event.keyCode == 117 { onDelete?() } else { super.keyDown(with: event) }
	}
}

enum Mode: Int { case sessions, plans }

enum SideRow {
	case all
	case project(path: String, count: Int, archived: Bool)
	case archivedHeader(count: Int)
}

func shellQuoted(_ text: String) -> String {
	text.allSatisfy({ $0.isLetter || $0.isNumber || "@%+=:,./-_".contains($0) })
		? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTableViewDataSource, NSTableViewDelegate,
                         NSSearchFieldDelegate, NSToolbarDelegate, NSTextViewDelegate, NSMenuDelegate {
	var window: NSWindow!
	let search = NSSearchField()
	let speaker = NSPopUpButton(), branches = NSPopUpButton(), sorting = NSPopUpButton()
	let when = NSSegmentedControl(labels: ["Any day", "Today", "Yesterday", "7 days"],
	                              trackingMode: .selectOne, target: nil, action: nil)
	let table = ListTable(), sidebar = NSTableView()
	let modeSwitch = NSSegmentedControl(labels: ["Sessions", "Plans"],
	                                    trackingMode: .selectOne, target: nil, action: nil)
	var mode = Mode.sessions
	let store = PlanStore()
	var plans: [Plan] = []
	var detailItem: NSSplitViewItem!
	var splitController: NSSplitViewController!
	let readerTitle = makeLabel(17, .semibold, .labelColor)
	let readerMeta = makeLabel(11, .regular, .tertiaryLabelColor)
	let statusPopup = NSPopUpButton(), projectPopup = NSPopUpButton()
	let pinButton = NSButton(), editButton = NSButton()
	let tagsField = NSTextField()
	let reader = NSTextView()
	let relatedStack = NSStackView()
	var readerScroll: NSScrollView!
	var shownPlan: String?
	var editing = false
	var progressSave: DispatchWorkItem?
	var restyle: DispatchWorkItem?
	var copiedID: String?
	let work = DispatchQueue(label: "index", qos: .userInitiated)
	var index: Index!
	var rows: [Session] = []
	var pending: DispatchWorkItem?
	var projects: [(path: String, count: Int)] = []
	var sideRows: [SideRow] = [.all]
	var showArchived = false
	var branchNames: [String] = []

	func applicationDidFinishLaunching(_ note: Notification) {
		buildMenu()
		buildWindow()
		window.subtitle = "Indexing transcripts..."
		indexing("Indexing Claude Code transcripts") {
			self.index = Index()
			self.index.refresh { done, total in
				DispatchQueue.main.async { self.window.subtitle = "Indexing \(done) of \(total)..." }
			}
			let found = self.index.projectCounts(), names = self.index.branchList()
			DispatchQueue.main.async {
				self.projects = found
				self.branchNames = names
				self.loadPlans()
				self.branches.addItems(withTitles: names)
				self.rebuildSidebar()
				self.reload()
			}
		}
	}

	func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

	private func indexing(_ reason: String, _ body: @escaping () -> Void) {
		work.async { ProcessInfo.processInfo.performActivity(options: .userInitiated, reason: reason, using: body) }
	}

	private func buildWindow() {
		window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1120, height: 720),
		                  styleMask: [.titled, .closable, .miniaturizable, .resizable],
		                  backing: .buffered, defer: false)
		window.title = "Claude Sessions"
		window.minSize = NSSize(width: 760, height: 420)
		window.center()
		window.toolbarStyle = .unified

		let split = NSSplitViewController()
		splitController = split
		split.addSplitViewItem(sidebarItem())
		let listItem = NSSplitViewItem(viewController: resultsController())
		listItem.minimumThickness = 320
		split.addSplitViewItem(listItem)
		// a plain item stays user-resizable; an inspector item's edge is not draggable
		detailItem = NSSplitViewItem(viewController: readerController())
		detailItem.minimumThickness = 360
		detailItem.isCollapsed = true
		split.addSplitViewItem(detailItem)
		window.contentViewController = split
		// assigning contentViewController resizes the window to fit, so size it after
		window.setContentSize(NSSize(width: 1120, height: 720))
		window.center()

		// the toolbar asks its delegate for items as soon as it is attached, and the
		// reader separator needs the split view, so attach it only once that exists
		let toolbar = NSToolbar(identifier: "main")
		toolbar.delegate = self
		toolbar.displayMode = .iconOnly
		toolbar.allowsUserCustomization = false
		window.toolbar = toolbar
		window.makeKeyAndOrderFront(nil)
		window.makeFirstResponder(search)
	}

	private func sidebarItem() -> NSSplitViewItem {
		sidebar.addTableColumn(NSTableColumn(identifier: .init("project")))
		sidebar.headerView = nil
		sidebar.style = .sourceList
		sidebar.rowHeight = 24
		sidebar.dataSource = self
		sidebar.delegate = self
		sidebar.selectionHighlightStyle = .regular
		let sideMenu = NSMenu()
		sideMenu.delegate = self
		sidebar.menu = sideMenu

		let scroll = NSScrollView()
		scroll.documentView = sidebar
		scroll.drawsBackground = false
		scroll.hasVerticalScroller = true
		scroll.automaticallyAdjustsContentInsets = true

		modeSwitch.selectedSegment = 0
		modeSwitch.segmentDistribution = .fillEqually
		modeSwitch.target = self
		modeSwitch.action = #selector(changeMode)
		modeSwitch.translatesAutoresizingMaskIntoConstraints = false
		scroll.translatesAutoresizingMaskIntoConstraints = false

		let container = NSView()
		container.addSubview(scroll)
		container.addSubview(modeSwitch)
		NSLayoutConstraint.activate([
			scroll.topAnchor.constraint(equalTo: container.topAnchor),
			scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			scroll.bottomAnchor.constraint(equalTo: modeSwitch.topAnchor, constant: -10),
			modeSwitch.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
			modeSwitch.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
			modeSwitch.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
		])

		let host = NSViewController()
		host.view = container
		let item = NSSplitViewItem(sidebarWithViewController: host)
		item.minimumThickness = 210
		item.maximumThickness = 320
		item.canCollapse = true
		return item
	}

	private func resultsController() -> NSViewController {
		let column = NSTableColumn(identifier: .init("session"))
		column.resizingMask = .autoresizingMask
		table.addTableColumn(column)
		table.headerView = nil
		table.style = .inset
		table.rowHeight = 46
		table.usesAlternatingRowBackgroundColors = false
		table.dataSource = self
		table.delegate = self
		table.target = self
		table.doubleAction = #selector(copySelected)
		table.allowsMultipleSelection = true
		table.onDelete = { [weak self] in self?.deleteSelectedPlans() }

		let menu = NSMenu()
		menu.addItem(withTitle: "Copy Session ID", action: #selector(copySelected), keyEquivalent: "")
		menu.addItem(withTitle: "Copy Resume Command", action: #selector(copyResume), keyEquivalent: "")
		menu.addItem(.separator())
		menu.addItem(withTitle: "Show Transcript in Finder", action: #selector(revealTranscript),
		             keyEquivalent: "")
		menu.items.forEach { $0.target = self }
		table.menu = menu

		let scroll = NSScrollView()
		scroll.documentView = table
		scroll.hasVerticalScroller = true
		scroll.drawsBackground = false
		// let AppKit inset the content under the unified toolbar instead of doing it by hand
		scroll.automaticallyAdjustsContentInsets = true

		let host = NSViewController()
		host.view = scroll
		return host
	}

	private func readerController() -> NSViewController {
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

		// NSTextTable is a TextKit 1 feature; touching layoutManager opts this view out of TextKit 2
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

		readerScroll = NSScrollView()
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
		// labels must not dictate the pane width, or a long plan title pins the divider
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
		// the window draws under the titlebar, so the pane starts at the safe area, not y=0
		let container = NSView()
		container.addSubview(stack)
		NSLayoutConstraint.activate([
			stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
			stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
			stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
			stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
		])
		let host = NSViewController()
		host.view = container
		return host
	}

	@objc func changeMode() {
		mode = Mode(rawValue: modeSwitch.selectedSegment) ?? .sessions
		search.placeholderString = mode == .plans ? "Search plans" : "Search conversations"
		detailItem.isCollapsed = mode == .sessions
		reload()
	}

	private func loadPlans() {
		store.load()
		let missing = store.unresolved
		if !missing.isEmpty {
			indexing("Finding the project that wrote each plan") {
				let found = self.index.writersOf(missing)
				DispatchQueue.main.async { self.store.applyScan(found); self.reload() }
			}
		}
	}

	private func showPlan(_ plan: Plan) {
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

		relatedStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
		let related = store.related(to: plan)
		if !related.isEmpty {
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
		DispatchQueue.main.async {
			let height = self.reader.frame.height - self.readerScroll.contentSize.height
			if plan.progress > 0, height > 0 {
				self.readerScroll.contentView.scroll(to: NSPoint(x: 0, y: height * plan.progress))
			}
		}
	}

	@objc func openRelated(_ sender: NSButton) {
		guard let id = sender.identifier?.rawValue, let at = plans.firstIndex(where: { $0.id == id })
		else { return }
		table.selectRowIndexes([at], byExtendingSelection: false)
		table.scrollRowToVisible(at)
	}

	@objc func readerScrolled() {
		guard let id = shownPlan, !editing else { return }
		let height = reader.frame.height - readerScroll.contentSize.height
		guard height > 0 else { return }
		let fraction = min(1, max(0, readerScroll.contentView.bounds.origin.y / height))
		// coalesce: scrolling fires continuously and each save rewrites the whole sidecar
		progressSave?.cancel()
		let job = DispatchWorkItem { [weak self] in self?.store.update(id) { $0.progress = fraction } }
		progressSave = job
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: job)
	}

	@objc func togglePin() {
		guard let id = shownPlan else { return }
		store.update(id) { $0.pinned = self.pinButton.state == .on }
		reload()
	}

	@objc func changeStatus() {
		guard let id = shownPlan else { return }
		store.update(id) { $0.status = ["", "active", "completed"][self.statusPopup.indexOfSelectedItem] }
		reload()
	}

	@objc func changeTags() {
		guard let id = shownPlan else { return }
		let tags = tagsField.stringValue.split(separator: ",")
			.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
		store.update(id) { $0.tags = tags }
		reload()
	}

	@objc func changeProject() {
		guard let id = shownPlan, projectPopup.indexOfSelectedItem > 0 else { return }
		store.setProject(id, path: projects[projectPopup.indexOfSelectedItem - 1].path)
		reload()
	}

	@objc func toggleEdit() {
		guard let id = shownPlan, let at = store.index(of: id) else { return }
		editing.toggle()
		editButton.title = editing ? "Save" : "Edit"
		reader.isEditable = editing
		guard let storage = reader.textStorage else { return }
		if editing {
			// substitutions would rewrite quotes and dashes inside the markdown, so turn them off
			reader.isAutomaticQuoteSubstitutionEnabled = false
			reader.isAutomaticDashSubstitutionEnabled = false
			reader.isAutomaticTextReplacementEnabled = false
			reader.isAutomaticSpellingCorrectionEnabled = false
			storage.setAttributedString(NSAttributedString(string: store.plans[at].body))
			Markdown.highlight(storage)
			window.makeFirstResponder(reader)
		} else {
			store.save(id, body: reader.string)
			loadPlans()
			reload()
			if let refreshed = store.plans.first(where: { $0.id == id }) { showPlan(refreshed) }
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
		NSWorkspace.shared.open(PlanStore.folder.appendingPathComponent("\(id).md"))
	}

	@objc func deleteCurrentPlan() {
		guard let id = shownPlan else { return }
		confirmDelete([id])
	}

	private func deleteSelectedPlans() {
		guard mode == .plans else { return }
		let ids = table.selectedRowIndexes.compactMap { $0 < plans.count ? plans[$0].id : nil }
		if !ids.isEmpty { confirmDelete(ids) }
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
		shownPlan = nil
		reload()
	}

	func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		[.toggleSidebar, .sidebarTrackingSeparator, .search, .flexibleSpace,
		 .when, .speaker, .branch, .sorting, .rebuild]
	}

	func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
		[.toggleSidebar, .sidebarTrackingSeparator, .search, .flexibleSpace,
		 .when, .speaker, .branch, .sorting, .rebuild]
	}

	func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
	             willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
		switch id {
		case .search:
			let item = NSSearchToolbarItem(itemIdentifier: id)
			search.placeholderString = "Search conversations"
			search.delegate = self
			item.searchField = search
			item.resignsFirstResponderWithCancel = true
			return item
		case .speaker:
			return popupItem(id, speaker, ["Anyone said", "I said", "Claude said"], width: 116)
		case .branch:
			return popupItem(id, branches, ["Any branch"], width: 132)
		case .sorting:
			return popupItem(id, sorting,
			                 ["Best match", "Most recent", "Most mentions", "Longest"], width: 128)
		case .when:
			when.selectedSegment = 0
			when.controlSize = .regular
			when.target = self
			when.action = #selector(reload)
			let item = NSToolbarItem(itemIdentifier: id)
			item.view = when
			item.label = "Active"
			return item
		case .rebuild:
			let item = NSToolbarItem(itemIdentifier: id)
			item.label = "Rebuild Index"
			item.toolTip = "Re-read every transcript from scratch"
			item.image = NSImage(systemSymbolName: "arrow.clockwise",
			                     accessibilityDescription: "Rebuild index")
			item.target = self
			item.action = #selector(rebuild)
			item.isBordered = true
			return item
		default:
			return nil
		}
	}

	private func popupItem(_ id: NSToolbarItem.Identifier, _ popup: NSPopUpButton,
	                       _ titles: [String], width: CGFloat) -> NSToolbarItem {
		if popup.numberOfItems == 0 { popup.addItems(withTitles: titles) }
		popup.target = self
		popup.action = #selector(reload)
		popup.bezelStyle = .toolbar
		popup.controlSize = .regular
		popup.setFrameSize(NSSize(width: width, height: 24))
		let item = NSToolbarItem(itemIdentifier: id)
		item.view = popup
		item.label = titles.first ?? ""
		item.visibilityPriority = .low
		return item
	}

	private func buildMenu() {
		let main = NSMenu()
		let appItem = NSMenuItem()
		let appMenu = NSMenu()
		appMenu.addItem(withTitle: "About Claude Sessions",
		                action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
		                keyEquivalent: "")
		appMenu.addItem(.separator())
		appMenu.addItem(withTitle: "Rebuild Index", action: #selector(rebuild), keyEquivalent: "r")
		appMenu.addItem(.separator())
		appMenu.addItem(withTitle: "Hide Claude Sessions",
		                action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
		appMenu.addItem(withTitle: "Quit Claude Sessions",
		                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
		appItem.submenu = appMenu
		main.addItem(appItem)

		let editItem = NSMenuItem()
		let editMenu = NSMenu(title: "Edit")
		editMenu.addItem(withTitle: "Copy Session ID", action: #selector(copySelected),
		                 keyEquivalent: "c")
		editMenu.addItem(withTitle: "Copy Resume Command", action: #selector(copyResume),
		                 keyEquivalent: "C")
		editMenu.addItem(withTitle: "Find", action: #selector(focusSearch), keyEquivalent: "f")
		editItem.submenu = editMenu
		main.addItem(editItem)

		let viewItem = NSMenuItem()
		let viewMenu = NSMenu(title: "View")
		viewMenu.addItem(withTitle: "Toggle Sidebar",
		                 action: #selector(NSSplitViewController.toggleSidebar(_:)),
		                 keyEquivalent: "s")
		viewItem.submenu = viewMenu
		main.addItem(viewItem)
		NSApp.mainMenu = main
	}

	private func daySpan() -> [String] {
		let calendar = Calendar.current, today = calendar.startOfDay(for: Date())
		let day = { (back: Int) in
			dayFormatter.string(from: calendar.date(byAdding: .day, value: -back, to: today)!) }
		switch when.selectedSegment {
		case 1: return [day(0)]
		case 2: return [day(1)]
		case 3: return (0..<7).map(day)
		default: return []
		}
	}

	@objc func reload() {
		if mode == .plans { return reloadPlans() }
		let query = search.stringValue
		let role = ["", "user", "assistant"][speaker.indexOfSelectedItem]
		let project = selectedProject, hidden = store.archived
		let hiddenCount = projects.filter { hidden.contains($0.path) }.reduce(0) { $0 + $1.count }
		let branch = branches.indexOfSelectedItem > 0
			? branchNames[branches.indexOfSelectedItem - 1] : ""
		let days = daySpan(), sort = sorting.indexOfSelectedItem
		work.async {
			guard let index = self.index else { return }
			let found = index.search(query: query, role: role, project: project, hidden: hidden,
			                         branch: branch, days: days, sort: sort)
			let total = index.total() - hiddenCount
			DispatchQueue.main.async {
				self.rows = found
				self.table.reloadData()
				self.window.subtitle = found.count == total
					? "\(total) sessions"
					: "\(found.count) of \(total) sessions"
			}
		}
	}

	private func reloadPlans() {
		let needle = search.stringValue.lowercased()
		let project = selectedProject, hidden = store.archived
		plans = store.plans.filter { plan in
			(project.isEmpty ? !hidden.contains(plan.project) : plan.project == project)
				&& (needle.isEmpty || plan.title.lowercased().contains(needle)
					|| plan.body.lowercased().contains(needle)
					|| plan.tags.contains { $0.lowercased().contains(needle) })
		}
		table.reloadData()
		window.subtitle = plans.count == store.plans.count
			? "\(store.plans.count) plans"
			: "\(plans.count) of \(store.plans.count) plans"
		if let id = shownPlan, let at = plans.firstIndex(where: { $0.id == id }) {
			table.selectRowIndexes([at], byExtendingSelection: false)
		}
	}

	@objc func rebuild() {
		window.subtitle = "Rebuilding index..."
		indexing("Rebuilding the transcript index") {
			self.index.db.exec("delete from msgs; delete from sessions;")
			self.index.refresh { done, total in
				DispatchQueue.main.async { self.window.subtitle = "Indexing \(done) of \(total)..." }
			}
			DispatchQueue.main.async { self.reload() }
		}
	}

	@objc func focusSearch() { window.makeFirstResponder(search) }

	/// The row the user acted on: the right-clicked one, else the selection.
	private var actedRow: Int? {
		let clicked = table.clickedRow
		let row = clicked >= 0 ? clicked : table.selectedRow
		return row >= 0 && row < rows.count ? row : nil
	}

	private func put(_ text: String, id: String, note: String) {
		NSPasteboard.general.clearContents()
		NSPasteboard.general.setString(text, forType: .string)
		window.subtitle = note
		copiedID = id
		// reload just this row: a full reloadData would drop the selection
		flashRow(of: id)
		let job = DispatchWorkItem { [weak self] in
			guard let self else { return }
			self.copiedID = nil
			self.flashRow(of: id)
			self.window.subtitle = "\(self.rows.count) sessions"
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + 1.4, execute: job)
	}

	private func flashRow(of id: String) {
		guard let row = rows.firstIndex(where: { $0.id == id }) else { return }
		table.reloadData(forRowIndexes: [row], columnIndexes: [0])
	}

	@objc func copySelected() {
		guard mode == .sessions, let row = actedRow else { return }
		let id = rows[row].id
		put(id, id: id, note: "Copied session id")
	}

	@objc func copyResume() {
		guard mode == .sessions, let row = actedRow else { return }
		let session = rows[row]
		put("cd \(shellQuoted(session.project.isEmpty ? "." : session.project)) && claude --resume \(session.id)",
		    id: session.id, note: "Copied resume command")
	}

	@objc func revealTranscript() {
		guard mode == .sessions, let row = actedRow else { return }
		guard let file = Transcripts.grouped()[rows[row].id]?.min(by: { $0.pathComponents.count < $1.pathComponents.count })
		else { return }
		NSWorkspace.shared.activateFileViewerSelecting([file])
	}

	private var selectedProject: String {
		let row = sidebar.selectedRow
		guard row >= 0, row < sideRows.count, case .project(let path, _, _) = sideRows[row] else { return "" }
		return path
	}

	private func rebuildSidebar() {
		let keep = selectedProject, hidden = store.archived
		sideRows = [.all] + projects.filter { !hidden.contains($0.path) }
			.map { .project(path: $0.path, count: $0.count, archived: false) }
		let archivedProjects = projects.filter { hidden.contains($0.path) }
		if !archivedProjects.isEmpty {
			sideRows.append(.archivedHeader(count: archivedProjects.count))
			if showArchived {
				sideRows += archivedProjects.map { .project(path: $0.path, count: $0.count, archived: true) }
			}
		}
		sidebar.reloadData()
		let row = sideRows.firstIndex {
			if case .project(let path, _, _) = $0 { return path == keep }
			return false
		} ?? 0
		sidebar.selectRowIndexes([row], byExtendingSelection: false)
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		let row = sidebar.clickedRow
		guard row >= 0, row < sideRows.count, case .project(let path, _, let archived) = sideRows[row] else { return }
		let item = NSMenuItem(title: archived ? "Unarchive Project" : "Archive Project",
		                      action: #selector(toggleArchive(_:)), keyEquivalent: "")
		item.target = self
		item.representedObject = path
		menu.addItem(item)
	}

	@objc func toggleArchive(_ sender: NSMenuItem) {
		guard let path = sender.representedObject as? String else { return }
		let archiving = !store.archived.contains(path)
		store.setArchived(path, archiving)
		if store.archived.isEmpty { showArchived = false }
		rebuildSidebar()
		reload()
		window.subtitle = "\(archiving ? "Archived" : "Unarchived") \((path as NSString).lastPathComponent)"
	}

	func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
		guard tableView === sidebar, case .archivedHeader = sideRows[row] else { return true }
		DispatchQueue.main.async {
			self.showArchived.toggle()
			self.rebuildSidebar()
		}
		return false
	}

	func controlTextDidChange(_ note: Notification) {
		pending?.cancel()
		let job = DispatchWorkItem { [weak self] in self?.reload() }
		pending = job
		DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: job)
	}

	func numberOfRows(in tableView: NSTableView) -> Int {
		if tableView === sidebar { return sideRows.count }
		return mode == .plans ? plans.count : rows.count
	}

	func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
		if tableView === sidebar { return 24 }
		if mode == .plans { return 52 }
		return rows[row].snippet.isEmpty ? 44 : 62
	}

	func tableViewSelectionDidChange(_ note: Notification) {
		if note.object as AnyObject === sidebar { return reload() }
		guard mode == .plans, table.selectedRow >= 0, table.selectedRow < plans.count else { return }
		showPlan(plans[table.selectedRow])
	}

	func tableView(_ tableView: NSTableView, viewFor column: NSTableColumn?, row: Int) -> NSView? {
		if tableView === sidebar {
			let view = tableView.makeView(withIdentifier: .init("side"), owner: self) as? SidebarRow
				?? { let fresh = SidebarRow(); fresh.identifier = .init("side"); return fresh }()
			view.nameField.font = .systemFont(ofSize: 12)
			view.nameField.textColor = .labelColor
			view.nameField.toolTip = nil
			switch sideRows[row] {
			case .all:
				let visible = sideRows.reduce(0) { total, entry in
					if case .project(_, let count, false) = entry { return total + count }
					return total
				}
				view.nameField.stringValue = "All projects"
				view.countField.stringValue = "\(visible)"
			case .archivedHeader(let count):
				view.nameField.stringValue = (showArchived ? "\u{25BE}  " : "\u{25B8}  ") + "Archived"
				view.nameField.font = .systemFont(ofSize: 11, weight: .semibold)
				view.nameField.textColor = .secondaryLabelColor
				view.countField.stringValue = "\(count)"
			case .project(let path, let count, let archived):
				view.nameField.stringValue = (path as NSString).lastPathComponent
				view.nameField.textColor = archived ? .secondaryLabelColor : .labelColor
				view.nameField.toolTip = path
				view.countField.stringValue = "\(count)"
			}
			view.needsLayout = true
			return view
		}
		if mode == .plans {
			let plan = plans[row]
			let view = tableView.makeView(withIdentifier: .init("plan"), owner: self) as? PlanRow
				?? { let fresh = PlanRow(); fresh.identifier = .init("plan"); return fresh }()
			view.titleField.stringValue = plan.title
			view.pinField.stringValue = plan.pinned ? "\u{25CF}" : ""
			var detail = [(plan.project as NSString).lastPathComponent]
			if detail[0].isEmpty { detail[0] = "Unassigned" }
			if !plan.status.isEmpty { detail.append(plan.status) }
			if !plan.tags.isEmpty { detail.append(plan.tags.joined(separator: ", ")) }
			detail.append(DateFormatter.localizedString(
				from: Date(timeIntervalSince1970: plan.modified), dateStyle: .medium, timeStyle: .none))
			view.subField.stringValue = detail.joined(separator: "   ")
			view.progress.doubleValue = plan.progress >= 1 ? 0 : plan.progress
			view.needsLayout = true
			return view
		}
		let session = rows[row]
		let view = tableView.makeView(withIdentifier: .init("row"), owner: self) as? RowView
			?? { let fresh = RowView(); fresh.identifier = .init("row"); return fresh }()
		view.titleField.stringValue = session.title
		let copied = copiedID == session.id
		view.idField.stringValue = copied ? "Copied to clipboard" : session.id
		view.idField.textColor = copied ? .controlAccentColor : .tertiaryLabelColor
		let stamp = DateFormatter.localizedString(
			from: Date(timeIntervalSince1970: session.modified), dateStyle: .medium, timeStyle: .short)
		var detail = [stamp, session.turns == 1 ? "1 message" : "\(session.turns) messages"]
		if !session.branch.isEmpty { detail.append(session.branch) }
		if session.hits > 0 { detail.append("\(session.hits) mentions") }
		view.subField.stringValue = detail.joined(separator: "   ")
		view.snippetField.attributedStringValue = session.snippet.isEmpty
			? NSAttributedString() : highlighted(session.snippet)
		view.needsLayout = true
		return view
	}
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.activate(ignoringOtherApps: true)
app.run()
