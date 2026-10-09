import AppKit

extension Markdown {
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
