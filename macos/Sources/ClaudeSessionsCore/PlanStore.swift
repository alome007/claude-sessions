import CryptoKit
import Foundation

public final class PlanStore {
	public let folder: URL
	let sidecar: URL

	public private(set) var plans: [Plan] = []
	private var meta: [String: Any] = [:]

	public init(paths: ClaudePaths) {
		folder = paths.plans
		sidecar = paths.sidecar
	}

	private func readMeta() -> [String: Any] {
		(try? JSONSerialization.jsonObject(with: Data(contentsOf: sidecar))) as? [String: Any] ?? [:]
	}

	public func load() {
		meta = readMeta()
		let entries = meta["plans"] as? [String: Any] ?? [:]
		let projects = meta["projects"] as? [String: Any] ?? [:]
		let overrides = meta["planProjectOverrides"] as? [String: String] ?? [:]
		let scanned = (meta["projectScan"] as? [String: Any])?["assignments"] as? [String: String] ?? [:]

		let urls = (try? FileManager.default.contentsOfDirectory(
			at: folder, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]))
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

	public var unresolved: [String] { plans.filter { $0.project.isEmpty }.map(\.id) }

	public func applyScan(_ found: [String: String]) {
		guard !found.isEmpty else { return }
		meta = readMeta()
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

	public var archived: Set<String> {
		let projects = meta["projects"] as? [String: Any] ?? [:]
		return Set(projects.values.compactMap { value in
			guard let record = value as? [String: Any], record["archived"] as? Bool == true else { return nil }
			return record["path"] as? String
		})
	}

	public func setArchived(_ path: String, _ on: Bool) {
		meta = readMeta()
		let hash = key(for: path)
		var projects = meta["projects"] as? [String: Any] ?? [:]
		var record = projects[hash] as? [String: Any] ?? [:]
		record["archived"] = on
		projects[hash] = record
		meta["projects"] = projects
		persist()
	}

	public func index(of id: String) -> Int? { plans.firstIndex { $0.id == id } }

	public func update(_ id: String, _ change: (inout Plan) -> Void) {
		guard let at = index(of: id) else { return }
		meta = readMeta()
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

	public func setProject(_ id: String, path: String) {
		guard let at = index(of: id) else { return }
		meta = readMeta()
		plans[at].project = path
		let hash = key(for: path)
		var overrides = meta["planProjectOverrides"] as? [String: String] ?? [:]
		overrides[id] = hash
		meta["planProjectOverrides"] = overrides
		persist()
	}

	public func delete(_ ids: [String]) {
		meta = readMeta()
		for id in ids {
			try? FileManager.default.removeItem(at: file(for: id))
		}
		var entries = meta["plans"] as? [String: Any] ?? [:]
		ids.forEach { entries.removeValue(forKey: $0) }
		meta["plans"] = entries
		persist()
		plans.removeAll { ids.contains($0.id) }
	}

	public func save(_ id: String, body: String) {
		guard let at = index(of: id) else { return }
		try? body.write(to: file(for: id), atomically: true, encoding: .utf8)
		plans[at].body = body
	}

	public func file(for id: String) -> URL {
		folder.appendingPathComponent("\(id).md")
	}

	public func related(to plan: Plan) -> [Plan] {
		plans.filter {
			$0.id != plan.id
				&& ($0.project == plan.project || !Set($0.tags).isDisjoint(with: plan.tags))
		}
	}

	private func persist() {
		guard let data = try? JSONSerialization.data(
			withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]) else { return }
		try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
		try? data.write(to: sidecar, options: .atomic)
	}
}
