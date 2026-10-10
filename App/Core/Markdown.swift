import Foundation

/// Block-level Markdown for assistant replies: headings, paragraphs, nested
/// lists (with task markers), quotes, fenced code, GFM tables and rules.
/// Inline spans are left as source for `MarkdownInline`. The parser is total:
/// any input, including partial streaming text, yields blocks.
nonisolated indirect enum MarkdownBlock: Hashable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [MarkdownListItem])
    case quote([MarkdownBlock])
    /// `closed` is false while a streamed fence has not ended yet.
    case code(language: String?, text: String, closed: Bool)
    case table(MarkdownTable)
    case rule
}

nonisolated struct MarkdownListItem: Hashable, Sendable {
    var blocks: [MarkdownBlock]
    var checked: Bool?
}

nonisolated struct MarkdownTable: Hashable, Sendable {
    enum Alignment: Hashable, Sendable { case leading, center, trailing }
    var header: [String]
    var alignments: [Alignment]
    var rows: [[String]]
}

nonisolated enum MarkdownParser {
    static let maxDepth = 12

    static func parse(_ source: String) -> [MarkdownBlock] {
        let normalized = source.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        return parse(lines: normalized.components(separatedBy: "\n").map(expandTabs), depth: 0)
    }

    private static func expandTabs(_ line: String) -> String { line.replacingOccurrences(of: "\t", with: "    ") }

    private static func parse(lines: [String], depth: Int) -> [MarkdownBlock] {
        guard depth < maxDepth else {
            let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.paragraph(text)]
        }
        var blocks: [MarkdownBlock] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }
            if let open = fence(line) {
                var body: [String] = []
                var closed = false
                i += 1
                while i < lines.count {
                    if let end = fence(lines[i]), end.marker == open.marker, end.length >= open.length, end.info.isEmpty {
                        closed = true; i += 1; break
                    }
                    body.append(strip(lines[i], upTo: open.indent)); i += 1
                }
                blocks.append(.code(language: open.info.split(separator: " ").first.map(String.init),
                                    text: body.joined(separator: "\n"), closed: closed))
                continue
            }
            if let heading = heading(line) { blocks.append(heading); i += 1; continue }
            if isRule(line) { blocks.append(.rule); i += 1; continue }
            if quoteContent(line) != nil {
                var inner: [String] = []
                while i < lines.count, let content = quoteContent(lines[i]) { inner.append(content); i += 1 }
                blocks.append(.quote(parse(lines: inner, depth: depth + 1)))
                continue
            }
            if i + 1 < lines.count, let table = tableStart(lines[i], lines[i + 1]) {
                var rows: [[String]] = []
                i += 2
                while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
                    rows.append(normalizedRow(cells(lines[i]), count: table.header.count)); i += 1
                }
                blocks.append(.table(MarkdownTable(header: table.header, alignments: table.alignments, rows: rows)))
                continue
            }
            if let marker = listMarker(line) {
                let (block, next) = list(lines, from: i, first: marker, depth: depth)
                blocks.append(block); i = next
                continue
            }
            var paragraph: [String] = []
            while i < lines.count, !isBlank(lines[i]) {
                if !paragraph.isEmpty, let level = setextLevel(lines[i]) {
                    blocks.append(.heading(level: level, text: paragraph.joined(separator: " ").trimmed))
                    paragraph = []; i += 1
                    break
                }
                if !paragraph.isEmpty, startsBlock(lines, at: i) { break }
                paragraph.append(lines[i].trimmed); i += 1
            }
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
        }
        return blocks
    }

    // MARK: Lists

    private struct Marker { var ordered: Bool; var number: Int; var bullet: Character; var indent: Int; var content: Int }

    private static func list(_ lines: [String], from start: Int, first: Marker, depth: Int) -> (MarkdownBlock, Int) {
        var items: [MarkdownListItem] = []
        var i = start
        while i < lines.count, let marker = listMarker(lines[i]), marker.ordered == first.ordered,
              marker.indent < first.content, first.ordered || marker.bullet == first.bullet {
            var body = [String(lines[i].dropFirst(min(marker.content, lines[i].count)))]
            i += 1
            while i < lines.count {
                let line = lines[i]
                if isBlank(line) {
                    // A blank line continues the item only if indented content follows.
                    var next = i + 1
                    while next < lines.count, isBlank(lines[next]) { next += 1 }
                    guard next < lines.count, indentation(lines[next]) >= marker.content else { break }
                    body.append(""); i += 1; continue
                }
                if indentation(line) >= marker.content { body.append(strip(line, upTo: marker.content)); i += 1; continue }
                if listMarker(line) != nil || startsBlock(lines, at: i) || body.last?.isEmpty == true { break }
                body.append(line.trimmed); i += 1 // lazy paragraph continuation
            }
            var checked: Bool?
            if let first = body.first {
                let lower = first.lowercased()
                if lower.hasPrefix("[ ] ") || lower == "[ ]" { checked = false; body[0] = String(first.dropFirst(3)).trimmed }
                else if lower.hasPrefix("[x] ") || lower == "[x]" { checked = true; body[0] = String(first.dropFirst(3)).trimmed }
            }
            items.append(MarkdownListItem(blocks: parse(lines: body, depth: depth + 1), checked: checked))
            var next = i
            while next < lines.count, isBlank(lines[next]) { next += 1 }
            if next < lines.count, let following = listMarker(lines[next]), following.ordered == first.ordered,
               following.indent < first.content { i = next }
        }
        return (.list(ordered: first.ordered, start: first.number, items: items), max(i, start + 1))
    }

    private static func listMarker(_ line: String) -> Marker? {
        let indent = indentation(line)
        guard indent <= 12 else { return nil }
        let rest = line.dropFirst(indent)
        guard let firstChar = rest.first else { return nil }
        if "-+*".contains(firstChar) {
            let after = rest.dropFirst()
            guard after.isEmpty || after.first == " " else { return nil }
            if isRule(line) { return nil }
            return Marker(ordered: false, number: 1, bullet: firstChar, indent: indent,
                          content: indent + 1 + min(spaces(after), 4).clamped(1))
        }
        let digits = rest.prefix { $0.isASCII && $0.isNumber }
        guard (1...9).contains(digits.count), let number = Int(digits) else { return nil }
        let afterDigits = rest.dropFirst(digits.count)
        guard let delimiter = afterDigits.first, delimiter == "." || delimiter == ")" else { return nil }
        let after = afterDigits.dropFirst()
        guard after.isEmpty || after.first == " " else { return nil }
        return Marker(ordered: true, number: number, bullet: delimiter, indent: indent,
                      content: indent + digits.count + 1 + min(spaces(after), 4).clamped(1))
    }

    // MARK: Leaf blocks

    private static func fence(_ line: String) -> (marker: Character, length: Int, info: String, indent: Int)? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let length = rest.prefix { $0 == marker }.count
        guard length >= 3 else { return nil }
        let info = String(rest.dropFirst(length)).trimmed
        if marker == "`", info.contains("`") { return nil }
        return (marker, length, info, indent)
    }

    private static func heading(_ line: String) -> MarkdownBlock? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix { $0 == "#" }.count
        guard (1...6).contains(level) else { return nil }
        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " else { return nil }
        var text = String(after).trimmed
        if let range = text.range(of: #"\s+#+$"#, options: .regularExpression) { text.removeSubrange(range) }
        else if text.allSatisfy({ $0 == "#" }) { text = "" }
        return .heading(level: level, text: text)
    }

    private static func isRule(_ line: String) -> Bool {
        guard indentation(line) <= 3 else { return false }
        let chars = line.filter { $0 != " " }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func setextLevel(_ line: String) -> Int? {
        guard indentation(line) <= 3 else { return nil }
        let text = line.trimmed
        guard !text.isEmpty else { return nil }
        if text.allSatisfy({ $0 == "=" }) { return 1 }
        if text.allSatisfy({ $0 == "-" }) { return 2 }
        return nil
    }

    private static func quoteContent(_ line: String) -> String? {
        let indent = indentation(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        guard rest.first == ">" else { return nil }
        let after = rest.dropFirst()
        return String(after.first == " " ? after.dropFirst() : after)
    }

    private static func startsBlock(_ lines: [String], at i: Int) -> Bool {
        let line = lines[i]
        return fence(line) != nil || heading(line) != nil || quoteContent(line) != nil || isRule(line)
            || listMarker(line) != nil || (i + 1 < lines.count && tableStart(line, lines[i + 1]) != nil)
    }

    // MARK: Tables

    private static func tableStart(_ header: String, _ delimiter: String) -> (header: [String], alignments: [MarkdownTable.Alignment])? {
        guard header.contains("|"), delimiter.contains("-") else { return nil }
        let specs = cells(delimiter)
        let names = cells(header)
        guard !specs.isEmpty, specs.count == names.count else { return nil }
        var alignments: [MarkdownTable.Alignment] = []
        for spec in specs {
            let s = spec.trimmed
            let core = s.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !core.isEmpty, core.allSatisfy({ $0 == "-" }) else { return nil }
            let left = s.hasPrefix(":"), right = s.hasSuffix(":")
            alignments.append(left && right ? .center : right ? .trailing : .leading)
        }
        return (names, alignments)
    }

    /// Splits a row on unescaped pipes outside code spans.
    static func cells(_ line: String) -> [String] {
        var text = line.trimmed
        if text.hasPrefix("|") { text.removeFirst() }
        if text.hasSuffix("|"), !text.hasSuffix("\\|") { text.removeLast() }
        var result: [String] = []
        var current = ""
        var inCode = false
        var escaped = false
        for char in text {
            if escaped { current.append(char == "|" ? "|" : "\\\(char)"); escaped = false; continue }
            if char == "\\" { escaped = true; continue }
            if char == "`" { inCode.toggle() }
            if char == "|", !inCode { result.append(current.trimmed); current = ""; continue }
            current.append(char)
        }
        if escaped { current.append("\\") }
        result.append(current.trimmed)
        return result
    }

    private static func normalizedRow(_ row: [String], count: Int) -> [String] {
        row.count >= count ? Array(row.prefix(count)) : row + Array(repeating: "", count: count - row.count)
    }

    // MARK: Helpers

    private static func isBlank(_ line: String) -> Bool { line.allSatisfy { $0 == " " } }
    private static func indentation(_ line: String) -> Int { line.prefix { $0 == " " }.count }
    private static func spaces(_ text: Substring) -> Int { text.prefix { $0 == " " }.count }
    private static func strip(_ line: String, upTo count: Int) -> String {
        String(line.dropFirst(min(count, indentation(line))))
    }
}

/// An image referenced by Markdown image syntax. Nothing is fetched while
/// rendering: a remote image loads only after the user taps it, and only as
/// `RemoteImagePolicy` allows.
nonisolated struct MarkdownImageReference: Hashable, Sendable {
    var alt: String
    var url: URL?
    var raw: String

    var isLoadable: Bool { RemoteImagePolicy.allows(url) }
}

/// Inline spans via Foundation's Markdown parser, with a link policy: only
/// http(s) and mailto links stay tappable, and inline image syntax is shown as
/// its alt text; `images(in:)` lists them for explicit, tap-to-load display.
nonisolated enum MarkdownInline {
    static let allowedSchemes: Set<String> = ["http", "https", "mailto"]

    static func images(in text: String) -> [MarkdownImageReference] {
        guard let regex = try? NSRegularExpression(pattern: #"!\[([^\]\n]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)"#) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard let alt = Range(match.range(at: 1), in: text), let raw = Range(match.range(at: 2), in: text) else { return nil }
            let source = String(text[raw])
            return MarkdownImageReference(alt: String(text[alt]), url: URL(string: source), raw: source)
        }
    }

    static func attributed(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(
            allowsExtendedAttributes: false, interpretedSyntax: .inlineOnlyPreservingWhitespace,
            failurePolicy: .returnPartiallyParsedIfPossible)
        var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        for run in result.runs {
            if let url = run.link, !isAllowed(url) { result[run.range].link = nil }
            if run.imageURL != nil { result[run.range].imageURL = nil }
        }
        return result
    }

    static func isAllowed(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) else { return false }
        return scheme == "mailto" || url.host?.isEmpty == false
    }
}

private extension String {
    nonisolated var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

private extension Int {
    nonisolated func clamped(_ minimum: Int) -> Int { Swift.max(self, minimum) }
}
