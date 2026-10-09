import Foundation
import Testing
@testable import ClaudeSessionsCore

struct TranscriptTextTests {
	@Test func injectedContextIsRemoved() {
		#expect(strip("attach it <system-reminder>hidden memo</system-reminder> now") == "attach it now")
	}

	@Test func toolCallsAndResultsAreNotSpoken() {
		let message: [String: Any] = ["content": [
			["type": "text", "text": "Use JDI."],
			["type": "tool_use", "name": "Bash"],
			["type": "tool_result", "content": "output"],
		]]
		#expect(spokenText(message) == ["Use JDI."])
	}

	@Test func timestampsWithAndWithoutFractions() {
		#expect(parseStamp("1970-01-01T00:00:10Z") == 10)
		#expect(parseStamp("1970-01-01T00:00:10.500Z") == 10.5)
		#expect(parseStamp("yesterday") == nil)
	}

	@Test func needlesSearchBytes() {
		#expect(Needle.user.found(in: Data(#"{"type":"user"}"#.utf8)))
		#expect(!Needle.user.found(in: Data(#"{"type":"assistant"}"#.utf8)))
		#expect(!Needle.user.found(in: Data()))
	}

	@Test func worktreesBelongToTheirRepo() {
		#expect(repoOf("/code/app/.claude/worktrees/fix") == "/code/app")
		#expect(repoOf("/code/app") == "/code/app")
	}

	@Test func resumeCommandsQuotePathsThatNeedIt() {
		#expect(shellQuoted("/code/app") == "/code/app")
		#expect(shellQuoted("/code/my app") == "'/code/my app'")
		#expect(shellQuoted("/code/it's") == #"'/code/it'\''s'"#)
	}
}

struct LinkTests {
	@Test func onlyWebLinksAreOpened() {
		#expect(isWebLink("https://example.com/docs"))
		#expect(isWebLink("http://localhost:8787/"))
		#expect(!isWebLink("file:///Applications/Utilities/Terminal.app"))
		#expect(!isWebLink("x-apple.systempreferences:com.apple.preference.security"))
		#expect(!isWebLink("javascript:alert(1)"))
		#expect(!isWebLink("src/main.swift"))
	}
}
