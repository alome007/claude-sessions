import Foundation
import Testing
@testable import ClaudeSessionsCore

struct SessionIndexTests {
	let home: TestHome

	init() throws {
		home = try TestHome()
	}

	func ids(_ index: SessionIndex, query: String = "", role: String = "", project: String = "",
	         hidden: Set<String> = [], branch: String = "", days: [String] = []) -> Set<String> {
		Set(index.search(query: query, role: role, project: project, hidden: hidden,
		                 branch: branch, days: days, sort: 0).map(\.id))
	}

	@Test func onlyChangedTranscriptsAreReindexed() {
		let index = SessionIndex(paths: home.paths)
		#expect(index.refresh() == 2)
		#expect(index.refresh() == 0)
	}

	@Test func deletedTranscriptsLeaveTheIndex() throws {
		let index = home.index()
		try FileManager.default.removeItem(at: home.project.appendingPathComponent("bbb.jsonl"))
		index.refresh()
		#expect(index.total() == 1)
	}

	@Test func onlySpokenTextIsSearchable() {
		let index = home.index()
		#expect(ids(index, query: "pangolin") == ["aaa"])
		#expect(ids(index, query: "hidden memo").isEmpty)
		#expect(ids(index, query: "buried").isEmpty)
		#expect(ids(index, query: "unspoken output").isEmpty)
	}

	@Test func everyWordMustAppearSomewhereInTheSession() {
		let index = home.index()
		#expect(ids(index, query: "kotlin") == ["aaa", "bbb"])
		#expect(ids(index, query: "kotlin debugger") == ["aaa"])
		#expect(ids(index, query: "attach pangolin") == ["aaa"])
		#expect(ids(index, query: "attach nonexistentword").isEmpty)
	}

	@Test func phrasesAndPrefixes() {
		let index = home.index()
		#expect(ids(index, query: #""attach the kotlin""#) == ["aaa"])
		#expect(ids(index, query: #""kotlin attach""#).isEmpty)
		#expect(ids(index, query: "debug*") == ["aaa"])
	}

	@Test func whoSaidIt() {
		let index = home.index()
		#expect(ids(index, query: "kotlin", role: "user") == ["aaa", "bbb"])
		#expect(ids(index, query: "JDI", role: "user").isEmpty)
	}

	@Test func filtersByDayProjectAndBranch() {
		let index = home.index()
		#expect(ids(index, days: ["2026-09-16"]) == ["aaa"])
		#expect(ids(index, project: "/other") == ["bbb"])
		#expect(ids(index, branch: "stage") == ["aaa"])
	}

	@Test func resultsCarryTitlesCountsAndSnippets() throws {
		let index = home.index()
		let hit = try #require(index.search(query: "debugger", role: "", project: "", hidden: [],
		                                    branch: "", days: [], sort: 0).first { $0.id == "aaa" })
		#expect(hit.title == "Kotlin debugger spike")
		#expect(hit.turns == 4)
		#expect(hit.snippet.contains("\u{1}debugger\u{2}"))
	}

	@Test func worktreesAreGroupedAndArchivedProjectsHidden() throws {
		try home.addWorktreeSession()
		let index = home.index()
		#expect(index.projectCounts().map(\.path) == ["/tmp/demo", "/other"])
		#expect(ids(index, project: "/tmp/demo") == ["aaa", "ccc"])
		#expect(ids(index, hidden: ["/tmp/demo"]) == ["bbb"])
	}

	@Test func theEarliestSessionToWriteAPlanOwnsIt() {
		#expect(home.index().writersOf(["alpha", "beta"]) == ["alpha": "/tmp/demo"])
	}
}

struct SymlinkedHomeTests {
	@Test func sessionsAreFoundThroughASymlinkedFolder() throws {
		let home = try TestHome()
		let link = home.root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
		try FileManager.default.createSymbolicLink(at: link, withDestinationURL: home.root)
		defer { try? FileManager.default.removeItem(at: link) }
		let index = SessionIndex(paths: .under(home: link))
		#expect(index.refresh() == 2)
		#expect(Set(index.search(query: "", role: "", project: "", hidden: [], branch: "", days: [], sort: 0).map(\.id)) == ["aaa", "bbb"])
		#expect(index.transcripts.mainTranscript(of: "aaa")?.lastPathComponent == "aaa.jsonl")
	}
}
