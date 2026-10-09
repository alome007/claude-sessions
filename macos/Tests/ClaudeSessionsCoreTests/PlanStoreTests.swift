import Foundation
import Testing
@testable import ClaudeSessionsCore

struct PlanStoreTests {
	let home: TestHome
	let store: PlanStore

	init() throws {
		home = try TestHome()
		try home.addPlans()
		store = PlanStore(paths: home.paths)
		store.load()
	}

	func plan(_ id: String, in store: PlanStore? = nil) throws -> Plan {
		try #require((store ?? self.store).plans.first { $0.id == id })
	}

	@Test func plansAreReadWithTheirTitles() throws {
		#expect(try plan("alpha").title == "Alpha plan")
		#expect(try plan("beta").title == "beta")
		#expect(store.unresolved.sorted() == ["alpha", "beta"])
	}

	@Test func scannedProjectsAreSavedAndReloaded() throws {
		store.applyScan(home.index().writersOf(store.unresolved))
		let reopened = PlanStore(paths: home.paths)
		reopened.load()
		#expect(try plan("alpha", in: reopened).project == "/tmp/demo")
		#expect(reopened.unresolved == ["beta"])
	}

	@Test func editsAreSavedAndPinnedPlansComeFirst() throws {
		store.update("beta") { $0.pinned = true; $0.tags = ["spike"]; $0.status = "active" }
		let reopened = PlanStore(paths: home.paths)
		reopened.load()
		#expect(reopened.plans.first?.id == "beta")
		#expect(try plan("beta", in: reopened).tags == ["spike"])
		#expect(try plan("beta", in: reopened).status == "active")
	}

	@Test func oneStoreNeverUndoesAnothersChanges() throws {
		let other = PlanStore(paths: home.paths)
		other.load()
		other.setArchived("/other", true)
		store.update("alpha") { $0.progress = 0.5 }
		let reopened = PlanStore(paths: home.paths)
		reopened.load()
		#expect(reopened.archived == ["/other"])
		#expect(try plan("alpha", in: reopened).progress == 0.5)
	}

	@Test func archivingCanBeUndone() {
		store.setArchived("/other", true)
		#expect(store.archived == ["/other"])
		store.setArchived("/other", false)
		#expect(store.archived.isEmpty)
	}

	@Test func deletingRemovesTheFileAndItsSettings() {
		store.update("beta") { $0.pinned = true }
		store.delete(["beta"])
		#expect(!FileManager.default.fileExists(atPath: store.file(for: "beta").path))
		let reopened = PlanStore(paths: home.paths)
		reopened.load()
		#expect(reopened.plans.map(\.id) == ["alpha"])
	}

	@Test func relatedPlansShareAProjectOrATag() throws {
		store.update("alpha") { $0.tags = ["kotlin"] }
		store.update("beta") { $0.tags = ["kotlin"] }
		#expect(store.related(to: try plan("alpha")).map(\.id) == ["beta"])
	}
}
