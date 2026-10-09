import AppKit
import ClaudeSessionsCore

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
				out.append(NSAttributedString(string: label, attributes: isWebLink(target) ? [
					.font: font, .foregroundColor: NSColor.linkColor,
					.link: target, .underlineStyle: NSUnderlineStyle.single.rawValue] : plain))
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
