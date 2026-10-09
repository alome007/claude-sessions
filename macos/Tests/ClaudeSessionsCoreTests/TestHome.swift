import Foundation
@testable import ClaudeSessionsCore

final class TestHome {
	let root: URL
	let paths: ClaudePaths
	let project: URL

	init() throws {
		root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
		paths = .under(home: root)
		project = paths.projects.appendingPathComponent("-tmp-demo")
		try FileManager.default.createDirectory(at: project.appendingPathComponent("aaa/subagents"),
		                                        withIntermediateDirectories: true)
		try write("aaa.jsonl", [
			#"{"type":"ai-title","aiTitle":"Kotlin debugger spike"}"#,
			#"{"type":"user","timestamp":"2026-09-14T10:00:00Z","cwd":"/tmp/demo","gitBranch":"stage","message":{"content":"how do I attach the kotlin debugger <system-reminder>hidden memo</system-reminder>"}}"#,
			#"{"type":"assistant","timestamp":"2026-09-14T10:01:00Z","cwd":"/tmp/demo","gitBranch":"stage","message":{"content":[{"type":"text","text":"Use JDI to attach."},{"type":"tool_use","name":"Bash","input":{"command":"buried"}}]}}"#,
			#"{"type":"user","timestamp":"2026-09-14T10:02:00Z","message":{"content":[{"type":"tool_result","content":"unspoken output"}]}}"#,
			Self.wrotePlan(at: "2026-09-14T10:04:00Z"),
			#"{"type":"user","timestamp":"2026-09-16T08:00:00Z","message":{"content":"unrelated chatter"}}"#,
		])
		try write("aaa/subagents/agent-1.jsonl", [
			#"{"type":"assistant","timestamp":"2026-09-14T10:03:00Z","message":{"content":[{"type":"text","text":"subagent said pangolin"}]}}"#,
		])
		try write("bbb.jsonl", [
			#"{"type":"user","timestamp":"2026-09-15T09:00:00Z","cwd":"/other","gitBranch":"main","message":{"content":"unrelated kotlin work"}}"#,
			Self.wrotePlan(at: "2026-09-15T09:30:00Z"),
		])
	}

	deinit {
		try? FileManager.default.removeItem(at: root)
	}

	static func wrotePlan(at stamp: String, plan: String = "alpha") -> String {
		#"{"type":"assistant","timestamp":"\#(stamp)","message":{"content":[{"type":"tool_use","name":"Write","input":{"file_path":"/home/u/.claude/plans/\#(plan).md"}}]}}"#
	}

	func write(_ name: String, _ lines: [String]) throws {
		try (lines.joined(separator: "\n") + "\n").write(to: project.appendingPathComponent(name),
		                                                atomically: true, encoding: .utf8)
	}

	func addWorktreeSession() throws {
		try write("ccc.jsonl", [
			#"{"type":"user","timestamp":"2026-09-17T09:00:00Z","cwd":"/tmp/demo/.claude/worktrees/wt","gitBranch":"wt","message":{"content":"worktree chat"}}"#,
		])
	}

	func addPlans() throws {
		try FileManager.default.createDirectory(at: paths.plans, withIntermediateDirectories: true)
		try "# Alpha plan\n\nkotlin body\n".write(to: paths.plans.appendingPathComponent("alpha.md"),
		                                         atomically: true, encoding: .utf8)
		try "no heading here\n".write(to: paths.plans.appendingPathComponent("beta.md"),
		                              atomically: true, encoding: .utf8)
	}

	func index() -> SessionIndex {
		let index = SessionIndex(paths: paths)
		index.refresh()
		return index
	}
}
