import Foundation

/// A compact CommonMark/GFM block parser producing HTML or plain text.
/// Supports headings (ATX & setext), paragraphs, emphasis, strong, strike,
/// inline code, fenced & indented code, block quotes, nested ordered and
/// unordered lists, task items, links, images, autolinks, hard breaks,
/// thematic breaks and pipe tables.
enum Markdown {

    // MARK: - Block model

    indirect enum Block {
        case heading(Int, String)
        case paragraph([String])
        case code(String, String?)
        case quote([Block])
        case list(ordered: Bool, start: Int, items: [[Block]])
        case rule
        case table(header: [String], align: [String?], rows: [[String]])
        case html(String)
    }

    // MARK: - Public API

    static func html(from markdown: String, title: String? = nil) -> String {
        let body = render(parse(markdown))
        let titleTag = title.map { "<title>\(escapeHTML($0))</title>\n" } ?? ""
        return """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        \(titleTag)<style>
        body { font: 16px/1.55 -apple-system, "Helvetica Neue", Helvetica, Arial, sans-serif; max-width: 46em; margin: 2em auto; padding: 0 1em; color: #1d1d1f; }
        pre, code { font-family: "SF Mono", Menlo, monospace; font-size: 0.9em; }
        pre { background: #f5f5f7; padding: 0.8em 1em; border-radius: 6px; overflow-x: auto; }
        blockquote { margin-left: 0; padding-left: 1em; border-left: 3px solid #d2d2d7; color: #515154; }
        table { border-collapse: collapse; }
        th, td { border: 1px solid #d2d2d7; padding: 0.3em 0.6em; }
        img { max-width: 100%; }
        </style>
        </head>
        <body>
        \(body)</body>
        </html>

        """
    }

    /// HTML fragment without document wrapper.
    static func htmlFragment(from markdown: String) -> String {
        render(parse(markdown))
    }

    static func plainText(from markdown: String) -> String {
        plain(parse(markdown)).trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - Parser

    static func parse(_ text: String) -> [Block] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\t", with: "    ")
        return parseBlocks(normalized.components(separatedBy: "\n"))
    }

    private static func indentation(_ line: String) -> Int {
        line.prefix { $0 == " " }.count
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func headingLevel(_ line: String) -> (Int, String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard indentation(line) < 4, trimmed.hasPrefix("#") else { return nil }
        let hashes = trimmed.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes) else { return nil }
        let rest = trimmed.dropFirst(hashes)
        guard rest.isEmpty || rest.first == " " else { return nil }
        var content = rest.trimmingCharacters(in: .whitespaces)
        // Optional closing hashes.
        if let range = content.range(of: #"\s+#+\s*$"#, options: .regularExpression) { content.removeSubrange(range) }
        else if content.allSatisfy({ $0 == "#" }) { content = "" }
        return (hashes, content)
    }

    private static func isRule(_ line: String) -> Bool {
        guard indentation(line) < 4 else { return false }
        let chars = line.filter { !$0.isWhitespace }
        guard chars.count >= 3, let first = chars.first, "-*_".contains(first) else { return false }
        return chars.allSatisfy { $0 == first }
    }

    private static func fence(_ line: String) -> (String, String?)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard indentation(line) < 4 else { return nil }
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            let fenceChars = trimmed.prefix { $0 == marker.first! }
            let info = trimmed.dropFirst(fenceChars.count).trimmingCharacters(in: .whitespaces)
            return (String(fenceChars), info.isEmpty ? nil : info.split(separator: " ").first.map(String.init))
        }
        return nil
    }

    /// Returns (ordered, number, content offset) for a list marker line.
    private static func listMarker(_ line: String) -> (Bool, Int, Int)? {
        let indent = indentation(line)
        guard indent < 4 || true else { return nil }
        let rest = line.dropFirst(indent)
        if let first = rest.first, "-*+".contains(first) {
            let after = rest.dropFirst()
            if after.isEmpty { return (false, 1, indent + 1) }
            guard after.first == " " else { return nil }
            if isRule(line) { return nil }
            let spaces = min(4, after.prefix { $0 == " " }.count)
            return (false, 1, indent + 1 + spaces)
        }
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 9 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard let delim = after.first, delim == "." || delim == ")" else { return nil }
        let tail = after.dropFirst()
        if tail.isEmpty { return (true, Int(digits) ?? 1, indent + digits.count + 1) }
        guard tail.first == " " else { return nil }
        let spaces = min(4, tail.prefix { $0 == " " }.count)
        return (true, Int(digits) ?? 1, indent + digits.count + 1 + spaces)
    }

    private static func tableCells(_ line: String) -> [String] {
        var trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("|") { trimmed.removeFirst() }
        if trimmed.hasSuffix("|") && !trimmed.hasSuffix("\\|") { trimmed.removeLast() }
        var cells: [String] = []
        var current = ""
        var escaped = false
        var inCode = false
        for ch in trimmed {
            if escaped { current.append(ch); escaped = false; continue }
            if ch == "\\" { escaped = true; current.append(ch); continue }
            if ch == "`" { inCode.toggle() }
            if ch == "|" && !inCode { cells.append(current.trimmingCharacters(in: .whitespaces)); current = ""; continue }
            current.append(ch)
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells.map { $0.replacingOccurrences(of: "\\|", with: "|") }
    }

    private static func tableAlignment(_ line: String) -> [String?]? {
        let cells = tableCells(line)
        guard !cells.isEmpty, line.contains("-") else { return nil }
        var result: [String?] = []
        for cell in cells {
            let c = cell.trimmingCharacters(in: .whitespaces)
            guard !c.isEmpty, c.allSatisfy({ $0 == "-" || $0 == ":" }), c.contains("-") else { return nil }
            switch (c.hasPrefix(":"), c.hasSuffix(":")) {
            case (true, true): result.append("center")
            case (false, true): result.append("right")
            case (true, false): result.append("left")
            default: result.append(nil)
            }
        }
        return result
    }

    private static func parseBlocks(_ lines: [String]) -> [Block] {
        var blocks: [Block] = []
        var i = 0
        var paragraph: [String] = []

        func flushParagraph() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph)); paragraph = [] }
        }

        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { flushParagraph(); i += 1; continue }

            // Setext headings underline the paragraph line(s) above.
            if !paragraph.isEmpty, indentation(line) < 4 {
                let t = line.trimmingCharacters(in: .whitespaces)
                if !t.isEmpty, t.allSatisfy({ $0 == "=" }) {
                    blocks.append(.heading(1, paragraph.joined(separator: " "))); paragraph = []; i += 1; continue
                }
                if !t.isEmpty, t.allSatisfy({ $0 == "-" }), paragraph.count >= 1 {
                    blocks.append(.heading(2, paragraph.joined(separator: " "))); paragraph = []; i += 1; continue
                }
            }
            if let (level, text) = headingLevel(line) {
                flushParagraph(); blocks.append(.heading(level, text)); i += 1; continue
            }
            if isRule(line) { flushParagraph(); blocks.append(.rule); i += 1; continue }
            if let (marker, info) = fence(line) {
                flushParagraph()
                let indent = indentation(line)
                var code: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    let t = l.trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(marker), t.allSatisfy({ $0 == marker.first! }) { i += 1; break }
                    code.append(String(l.dropFirst(min(indent, indentation(l)))))
                    i += 1
                }
                blocks.append(.code(code.joined(separator: "\n"), info))
                continue
            }
            if paragraph.isEmpty, indentation(line) >= 4 {
                var code: [String] = []
                while i < lines.count, indentation(lines[i]) >= 4 || isBlank(lines[i]) {
                    code.append(String(lines[i].dropFirst(min(4, indentation(lines[i])))))
                    i += 1
                }
                while let last = code.last, last.trimmingCharacters(in: .whitespaces).isEmpty { code.removeLast() }
                blocks.append(.code(code.joined(separator: "\n"), nil))
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                flushParagraph()
                var inner: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.hasPrefix(">") {
                        var rest = t.dropFirst()
                        if rest.first == " " { rest = rest.dropFirst() }
                        inner.append(String(rest))
                    } else if !isBlank(lines[i]), !inner.isEmpty, !isBlank(inner.last!) {
                        inner.append(lines[i]) // lazy continuation
                    } else { break }
                    i += 1
                }
                blocks.append(.quote(parseBlocks(inner)))
                continue
            }
            if let (ordered, start, contentOffset) = listMarker(line), indentation(line) < 4 || paragraph.isEmpty {
                flushParagraph()
                var items: [[Block]] = []
                var current: [String] = []
                var offset = contentOffset
                let baseIndent = indentation(line)
                current.append(String(line.dropFirst(min(contentOffset, line.count))))
                i += 1
                var sawBlank = false
                while i < lines.count {
                    let l = lines[i]
                    if isBlank(l) { sawBlank = true; current.append(""); i += 1; continue }
                    if let (o2, _, off2) = listMarker(l), indentation(l) == baseIndent, o2 == ordered {
                        items.append(parseBlocks(current)); current = [String(l.dropFirst(min(off2, l.count)))]
                        offset = off2; sawBlank = false; i += 1; continue
                    }
                    if indentation(l) >= offset {
                        current.append(String(l.dropFirst(offset))); sawBlank = false; i += 1; continue
                    }
                    if !sawBlank, listMarker(l) == nil, headingLevel(l) == nil, !isRule(l), fence(l) == nil,
                       !l.trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                        current.append(l.trimmingCharacters(in: .whitespaces)); i += 1; continue // lazy line
                    }
                    break
                }
                while let last = current.last, last.isEmpty { current.removeLast() }
                items.append(parseBlocks(current))
                blocks.append(.list(ordered: ordered, start: start, items: items))
                continue
            }
            // GFM table: header row followed by an alignment row.
            if paragraph.isEmpty, line.contains("|"), i + 1 < lines.count, let align = tableAlignment(lines[i + 1]) {
                let header = tableCells(line)
                if header.count == align.count {
                    var rows: [[String]] = []
                    i += 2
                    while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
                        var cells = tableCells(lines[i])
                        if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                        rows.append(Array(cells.prefix(header.count)))
                        i += 1
                    }
                    blocks.append(.table(header: header, align: align, rows: rows))
                    continue
                }
            }
            if paragraph.isEmpty, line.trimmingCharacters(in: .whitespaces).hasPrefix("<"),
               let tag = line.trimmingCharacters(in: .whitespaces).dropFirst().split(whereSeparator: { !$0.isLetter && $0 != "/" }).first,
               ["div", "table", "p", "pre", "details", "section", "figure", "img", "/div", "br", "hr", "iframe"].contains(tag.lowercased()) {
                var html: [String] = []
                while i < lines.count, !isBlank(lines[i]) { html.append(lines[i]); i += 1 }
                blocks.append(.html(html.joined(separator: "\n")))
                continue
            }
            paragraph.append(line.trimmingCharacters(in: .whitespaces))
            i += 1
        }
        flushParagraph()
        return blocks
    }

    // MARK: - HTML rendering

    private static func render(_ blocks: [Block], tight: Bool = false) -> String {
        var out = ""
        for block in blocks {
            switch block {
            case .heading(let level, let text):
                out += "<h\(level)>\(inline(text))</h\(level)>\n"
            case .paragraph(let lines):
                let content = paragraphHTML(lines)
                out += tight ? "\(content)\n" : "<p>\(content)</p>\n"
            case .code(let code, let lang):
                let cls = lang.map { " class=\"language-\(escapeHTML($0))\"" } ?? ""
                out += "<pre><code\(cls)>\(escapeHTML(code))\n</code></pre>\n"
            case .quote(let inner):
                out += "<blockquote>\n\(render(inner))</blockquote>\n"
            case .list(let ordered, let start, let items):
                let tag = ordered ? "ol" : "ul"
                let startAttr = ordered && start != 1 ? " start=\"\(start)\"" : ""
                out += "<\(tag)\(startAttr)>\n"
                let isTight = items.allSatisfy { $0.count <= 2 }
                for item in items {
                    var blocks = item
                    var prefix = ""
                    if case .paragraph(var lines)? = blocks.first, let first = lines.first {
                        if first.hasPrefix("[ ] ") || first.hasPrefix("[x] ") || first.hasPrefix("[X] ") {
                            let checked = !first.hasPrefix("[ ]")
                            prefix = "<input type=\"checkbox\" disabled\(checked ? " checked" : "")> "
                            lines[0] = String(first.dropFirst(4))
                            blocks[0] = .paragraph(lines)
                        }
                    }
                    out += "<li>\(prefix)\(render(blocks, tight: isTight).trimmingCharacters(in: .newlines))</li>\n"
                }
                out += "</\(tag)>\n"
            case .rule:
                out += "<hr>\n"
            case .table(let header, let align, let rows):
                out += "<table>\n<thead>\n<tr>"
                for (i, cell) in header.enumerated() {
                    out += "<th\(alignAttr(align, i))>\(inline(cell))</th>"
                }
                out += "</tr>\n</thead>\n<tbody>\n"
                for row in rows {
                    out += "<tr>"
                    for (i, cell) in row.enumerated() { out += "<td\(alignAttr(align, i))>\(inline(cell))</td>" }
                    out += "</tr>\n"
                }
                out += "</tbody>\n</table>\n"
            case .html(let raw):
                out += raw + "\n"
            }
        }
        return out
    }

    private static func alignAttr(_ align: [String?], _ i: Int) -> String {
        guard i < align.count, let a = align[i] else { return "" }
        return " style=\"text-align: \(a)\""
    }

    private static func paragraphHTML(_ lines: [String]) -> String {
        var parts: [String] = []
        for (index, raw) in lines.enumerated() {
            var line = raw
            var hardBreak = false
            if index < lines.count - 1 {
                if line.hasSuffix("\\") { line.removeLast(); hardBreak = true }
                else if raw.hasSuffix("  ") { hardBreak = true }
            }
            parts.append(inline(line.trimmingCharacters(in: .whitespaces)) + (hardBreak ? "<br>" : ""))
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Inline

    static func inline(_ text: String) -> String {
        var out = ""
        let chars = Array(text)
        var i = 0
        func peek(_ s: String, at index: Int) -> Bool {
            let sc = Array(s)
            guard index + sc.count <= chars.count else { return false }
            return Array(chars[index..<(index + sc.count)]) == sc
        }
        func findClosing(_ delim: String, from start: Int) -> Int? {
            var j = start
            while j < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "`" { // skip code spans
                    if let end = (j + 1..<chars.count).first(where: { chars[$0] == "`" }) { j = end + 1; continue }
                }
                if peek(delim, at: j), j > start, !chars[j - 1].isWhitespace { return j }
                j += 1
            }
            return nil
        }
        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count, "\\`*_{}[]()#+-.!|<>~\"".contains(chars[i + 1]) {
                out += escapeHTML(String(chars[i + 1])); i += 2; continue
            }
            if c == "`" {
                let ticks = chars[i...].prefix { $0 == "`" }.count
                let delim = String(repeating: "`", count: ticks)
                var j = i + ticks
                var found: Int?
                while j < chars.count {
                    if peek(delim, at: j), (j + ticks >= chars.count || chars[j + ticks] != "`") { found = j; break }
                    j += 1
                }
                if let end = found {
                    var code = String(chars[(i + ticks)..<end])
                    if code.hasPrefix(" ") && code.hasSuffix(" ") && code.count > 2 { code = String(code.dropFirst().dropLast()) }
                    out += "<code>\(escapeHTML(code))</code>"
                    i = end + ticks; continue
                }
                out += delim; i += ticks; continue
            }
            if c == "!" || c == "[" {
                let isImage = c == "!"
                let open = isImage ? i + 1 : i
                if open < chars.count, chars[open] == "[", let (label, url, title, end) = parseLink(chars, open) {
                    let titleAttr = title.map { " title=\"\(escapeHTML($0))\"" } ?? ""
                    if isImage {
                        out += "<img src=\"\(escapeHTML(url))\" alt=\"\(escapeHTML(label))\"\(titleAttr)>"
                    } else {
                        out += "<a href=\"\(escapeHTML(url))\"\(titleAttr)>\(inline(label))</a>"
                    }
                    i = end; continue
                }
            }
            if c == "<", let close = (i + 1..<chars.count).first(where: { chars[$0] == ">" }) {
                let inner = String(chars[(i + 1)..<close])
                if inner.hasPrefix("http://") || inner.hasPrefix("https://") || inner.hasPrefix("mailto:") {
                    out += "<a href=\"\(escapeHTML(inner))\">\(escapeHTML(inner))</a>"; i = close + 1; continue
                }
                if inner.contains("@"), !inner.contains(" ") {
                    out += "<a href=\"mailto:\(escapeHTML(inner))\">\(escapeHTML(inner))</a>"; i = close + 1; continue
                }
            }
            var handledStrong = false
            for delim in ["**", "__", "~~"] where peek(delim, at: i) {
                if i + 2 < chars.count, !chars[i + 2].isWhitespace, let end = findClosing(delim, from: i + 2) {
                    let tag = delim == "~~" ? "del" : "strong"
                    out += "<\(tag)>\(inline(String(chars[(i + 2)..<end])))</\(tag)>"
                    i = end + 2
                    handledStrong = true
                    break
                }
            }
            if handledStrong { continue }
            if (c == "*" || c == "_"), i + 1 < chars.count, !chars[i + 1].isWhitespace,
               !(c == "_" && i > 0 && chars[i - 1].isLetter),
               let end = findClosing(String(c), from: i + 1),
               !(c == "_" && end + 1 < chars.count && chars[end + 1].isLetter) {
                out += "<em>\(inline(String(chars[(i + 1)..<end])))</em>"
                i = end + 1; continue
            }
            out += escapeHTML(String(c))
            i += 1
        }
        return out
    }

    /// Parses `[label](url "title")` starting at `chars[start] == "["`.
    private static func parseLink(_ chars: [Character], _ start: Int) -> (String, String, String?, Int)? {
        var depth = 0
        var j = start
        var labelEnd: Int?
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            if chars[j] == "[" { depth += 1 }
            if chars[j] == "]" { depth -= 1; if depth == 0 { labelEnd = j; break } }
            j += 1
        }
        guard let le = labelEnd, le + 1 < chars.count, chars[le + 1] == "(" else { return nil }
        var k = le + 2
        var parens = 1
        while k < chars.count {
            if chars[k] == "(" { parens += 1 }
            if chars[k] == ")" { parens -= 1; if parens == 0 { break } }
            k += 1
        }
        guard k < chars.count else { return nil }
        let inside = String(chars[(le + 2)..<k]).trimmingCharacters(in: .whitespaces)
        var url = inside
        var title: String?
        if let q = inside.firstIndex(of: "\""), inside.hasSuffix("\"") {
            url = String(inside[..<q]).trimmingCharacters(in: .whitespaces)
            title = String(inside[inside.index(after: q)..<inside.index(before: inside.endIndex)])
        }
        if url.hasPrefix("<") && url.hasSuffix(">") { url = String(url.dropFirst().dropLast()) }
        return (String(chars[(start + 1)..<le]), url, title, k + 1)
    }

    // MARK: - Plain text

    private static func plain(_ blocks: [Block], indent: String = "") -> String {
        var out = ""
        for block in blocks {
            switch block {
            case .heading(_, let text): out += indent + stripInline(text) + "\n\n"
            case .paragraph(let lines): out += indent + lines.map(stripInline).joined(separator: "\n" + indent) + "\n\n"
            case .code(let code, _): out += code.split(separator: "\n", omittingEmptySubsequences: false).map { indent + $0 }.joined(separator: "\n") + "\n\n"
            case .quote(let inner): out += plain(inner, indent: indent + "    ")
            case .list(let ordered, let start, let items):
                for (n, item) in items.enumerated() {
                    let bullet = ordered ? "\(start + n). " : "• "
                    let body = plain(item, indent: "").trimmingCharacters(in: .whitespacesAndNewlines)
                    let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
                    out += indent + bullet + (lines.first.map(String.init) ?? "") + "\n"
                    for line in lines.dropFirst() { out += indent + String(repeating: " ", count: bullet.count) + line + "\n" }
                }
                out += "\n"
            case .rule: out += indent + "────────\n\n"
            case .table(let header, _, let rows):
                out += indent + header.map(stripInline).joined(separator: "\t") + "\n"
                for row in rows { out += indent + row.map(stripInline).joined(separator: "\t") + "\n" }
                out += "\n"
            case .html(let raw): out += indent + raw.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) + "\n\n"
            }
        }
        return out
    }

    static func stripInline(_ text: String) -> String {
        let html = inline(text)
        var s = html.replacingOccurrences(of: "<img [^>]*alt=\"([^\"]*)\"[^>]*>", with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return unescapeHTML(s)
    }

    static func escapeHTML(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(ch)
            }
        }
        return out
    }

    static func unescapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
