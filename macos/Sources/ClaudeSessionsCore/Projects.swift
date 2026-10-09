import Foundation

public func repoOf(_ path: String) -> String {
	path.components(separatedBy: "/.claude/worktrees/")[0]
}

public func shellQuoted(_ text: String) -> String {
	text.allSatisfy({ $0.isLetter || $0.isNumber || "@%+=:,./-_".contains($0) })
		? text : "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
}
