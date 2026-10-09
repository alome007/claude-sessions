import Foundation

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

public let dayFormatter: DateFormatter = {
	let formatter = DateFormatter()
	formatter.dateFormat = "yyyy-MM-dd"
	return formatter
}()
