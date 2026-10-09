import Foundation
import SQLite3

let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

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
