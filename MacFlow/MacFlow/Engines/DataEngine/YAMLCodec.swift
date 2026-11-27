import Foundation

/// YAML 1.2 subset: block mappings and sequences, flow collections, plain /
/// single- / double-quoted scalars, literal (|) and folded (>) block
/// scalars, comments and a single document. Anchors, aliases, tags, complex
/// keys and multiple documents are rejected with a clear error instead of
/// being misread.
enum YAMLCodec {

    struct ParseError: LocalizedError {
        let message: String
        let line: Int
        var errorDescription: String? { "YAML line \(line): \(message)" }
    }

    // MARK: - Serialisation

    static func serialize(_ value: DataValue) -> String {
        var out = ""
        switch value {
        case .object(let m) where !m.isEmpty: writeMapping(m, indent: 0, into: &out)
        case .array(let a) where !a.isEmpty: writeSequence(a, indent: 0, into: &out)
        default: out = scalar(value) + "\n"
        }
        return out
    }

    private static func writeMapping(_ members: [(String, DataValue)], indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        for (key, value) in members {
            let k = quoteKey(key)
            switch value {
            case .object(let m) where !m.isEmpty:
                out += "\(pad)\(k):\n"; writeMapping(m, indent: indent + 1, into: &out)
            case .array(let a) where !a.isEmpty:
                out += "\(pad)\(k):\n"; writeSequence(a, indent: indent + 1, into: &out)
            case .string(let s) where s.contains("\n"):
                out += "\(pad)\(k): " + literal(s, indent: indent + 1)
            default:
                out += "\(pad)\(k): \(scalar(value))\n"
            }
        }
    }

    private static func writeSequence(_ items: [DataValue], indent: Int, into out: inout String) {
        let pad = String(repeating: "  ", count: indent)
        for item in items {
            switch item {
            case .object(let m) where !m.isEmpty:
                var nested = ""
                writeMapping(m, indent: indent + 1, into: &nested)
                // First key on the dash line.
                let inner = String(repeating: "  ", count: indent + 1)
                out += pad + "- " + String(nested.dropFirst(inner.count))
            case .array(let a) where !a.isEmpty:
                out += "\(pad)-\n"; writeSequence(a, indent: indent + 1, into: &out)
            case .string(let s) where s.contains("\n"):
                out += "\(pad)- " + literal(s, indent: indent + 1)
            default:
                out += "\(pad)- \(scalar(item))\n"
            }
        }
    }

    private static func literal(_ s: String, indent: Int) -> String {
        let pad = String(repeating: "  ", count: indent)
        let chomp = s.hasSuffix("\n") ? (s.hasSuffix("\n\n") ? "+" : "") : "-"
        var body = s
        if body.hasSuffix("\n") { body.removeLast() }
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
        let indicator = (lines.first?.hasPrefix(" ") ?? false) ? "2" : ""
        return "|\(indicator)\(chomp)\n" + lines.map { $0.isEmpty ? "" : pad + $0 }.joined(separator: "\n") + "\n"
    }

    static func scalar(_ value: DataValue) -> String {
        switch value {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return quoteIfNeeded(s)
        case .date(let d): return ISO8601DateFormatter().string(from: d)
        case .data(let d): return "!!binary " + d.base64EncodedString()
        case .array(let a): return a.isEmpty ? "[]" : "[" + a.map(scalar).joined(separator: ", ") + "]"
        case .object(let m): return m.isEmpty ? "{}" : "{" + m.map { quoteKey($0.0) + ": " + scalar($0.1) }.joined(separator: ", ") + "}"
        }
    }

    private static func quoteKey(_ key: String) -> String { quoteIfNeeded(key) }

    static func quoteIfNeeded(_ s: String) -> String {
        if s.isEmpty { return "\"\"" }
        let reserved: Set<String> = ["null", "Null", "NULL", "~", "true", "True", "TRUE", "false", "False", "FALSE",
                                     "yes", "Yes", "YES", "no", "No", "NO", "on", "On", "ON", "off", "Off", "OFF", ".nan", ".inf", "-.inf"]
        let needs = reserved.contains(s)
            || Double(s) != nil || Int(s) != nil
            || s.hasPrefix(" ") || s.hasSuffix(" ")
            || s.first.map { "-?:,[]{}#&*!|>'\"%@`".contains($0) } == true
            || s.contains(": ") || s.contains(" #") || s.hasSuffix(":")
            || s.contains("\n") || s.contains("\t") || s.unicodeScalars.contains { $0.value < 0x20 }
        return needs ? JSONCodec.quote(s) : s
    }

    // MARK: - Parsing

    static func parse(_ text: String) throws -> DataValue {
        var lines: [(Int, String)] = [] // (line number, raw)
        var docStarts = 0
        for (n, raw) in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n").enumerated() {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed.hasPrefix("--- ") {
                docStarts += 1
                if docStarts > 1 || !lines.filter({ !$0.1.trimmingCharacters(in: .whitespaces).isEmpty }).isEmpty {
                    throw ParseError(message: "Multiple YAML documents are not supported", line: n + 1)
                }
                continue
            }
            if trimmed == "..." { break }
            if trimmed.hasPrefix("%") { continue }
            if raw.contains("\t") && raw.prefix(while: { $0 == " " || $0 == "\t" }).contains("\t") {
                throw ParseError(message: "Tabs cannot be used for indentation", line: n + 1)
            }
            lines.append((n + 1, raw))
        }
        var parser = Parser(lines: lines)
        parser.skipBlank()
        if parser.atEnd { return .null }
        let value = try parser.parseNode(indent: parser.currentIndent)
        parser.skipBlank()
        if !parser.atEnd { throw ParseError(message: "Unexpected content", line: parser.lineNumber) }
        return value
    }

    private struct Parser {
        let lines: [(Int, String)]
        var i = 0
        init(lines: [(Int, String)]) { self.lines = lines }
        var atEnd: Bool { i >= lines.count }
        var lineNumber: Int { i < lines.count ? lines[i].0 : (lines.last?.0 ?? 0) }
        var current: String { lines[i].1 }
        var currentIndent: Int { current.prefix { $0 == " " }.count }

        mutating func skipBlank() {
            while i < lines.count {
                let t = stripComment(lines[i].1).trimmingCharacters(in: .whitespaces)
                if t.isEmpty { i += 1 } else { break }
            }
        }

        func err(_ m: String) -> ParseError { ParseError(message: m, line: lineNumber) }

        mutating func parseNode(indent: Int) throws -> DataValue {
            skipBlank()
            guard !atEnd else { return .null }
            let content = stripComment(current).trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("- ") || content == "-" { return try parseSequence(indent: currentIndent) }
            if splitKey(content) != nil { return try parseMapping(indent: currentIndent) }
            // A lone scalar (possibly a flow collection spanning one line).
            i += 1
            return try parseScalar(content)
        }

        mutating func parseSequence(indent: Int) throws -> DataValue {
            var items: [DataValue] = []
            while true {
                skipBlank()
                guard !atEnd, currentIndent == indent else { break }
                let content = stripComment(current).trimmingCharacters(in: .whitespaces)
                guard content.hasPrefix("- ") || content == "-" else { break }
                let rest = content == "-" ? "" : String(content.dropFirst(2)).trimmingCharacters(in: .whitespaces)
                if rest.isEmpty {
                    i += 1
                    skipBlank()
                    if !atEnd, currentIndent > indent { items.append(try parseNode(indent: currentIndent)) } else { items.append(.null) }
                } else if rest.hasPrefix("- ") || splitKey(rest) != nil {
                    // Inline nested node: re-interpret the remainder at its column.
                    let column = indent + 2 + (content.count - 2 - rest.count)
                    var synthetic = lines
                    synthetic[i] = (lines[i].0, String(repeating: " ", count: column) + rest)
                    var sub = Parser(lines: synthetic)
                    sub.i = i
                    items.append(try sub.parseNode(indent: column))
                    i = sub.i
                } else if rest.hasPrefix("|") || rest.hasPrefix(">") {
                    i += 1
                    items.append(.string(try blockScalar(header: rest, parentIndent: indent)))
                } else {
                    i += 1
                    items.append(try parseScalar(rest))
                }
            }
            return .array(items)
        }

        mutating func parseMapping(indent: Int) throws -> DataValue {
            var members: [(String, DataValue)] = []
            var seen = Set<String>()
            while true {
                skipBlank()
                guard !atEnd, currentIndent == indent else {
                    if !atEnd, currentIndent > indent { throw err("Unexpected indentation") }
                    break
                }
                let content = stripComment(current).trimmingCharacters(in: .whitespaces)
                guard let (rawKey, rest) = splitKey(content) else { break }
                if rawKey.hasPrefix("? ") { throw err("Complex keys are not supported") }
                let key = try unquoteKey(rawKey)
                if seen.contains(key) { throw err("Duplicate key “\(key)”") }
                seen.insert(key)
                if rest.isEmpty {
                    i += 1
                    skipBlank()
                    if !atEnd, currentIndent > indent {
                        members.append((key, try parseNode(indent: currentIndent)))
                    } else if !atEnd, currentIndent == indent,
                              stripComment(current).trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
                        members.append((key, try parseSequence(indent: indent)))
                    } else {
                        members.append((key, .null))
                    }
                } else if rest.hasPrefix("|") || rest.hasPrefix(">") {
                    i += 1
                    members.append((key, .string(try blockScalar(header: rest, parentIndent: indent))))
                } else {
                    i += 1
                    var scalarText = rest
                    // Multi-line flow collections and plain scalars.
                    if (rest.hasPrefix("[") && !balanced(rest)) || (rest.hasPrefix("{") && !balanced(rest)) {
                        while !atEnd, !balanced(scalarText) {
                            scalarText += " " + stripComment(current).trimmingCharacters(in: .whitespaces)
                            i += 1
                        }
                    }
                    members.append((key, try parseScalar(scalarText)))
                }
            }
            return .object(members)
        }

        mutating func blockScalar(header: String, parentIndent: Int) throws -> String {
            let folded = header.hasPrefix(">")
            let chompKeep = header.contains("+")
            let chompStrip = header.contains("-")
            var explicitIndent: Int?
            if let digit = header.first(where: { $0.isNumber }), let d = Int(String(digit)) { explicitIndent = parentIndent + d }
            var collected: [String] = []
            var blockIndent: Int? = explicitIndent
            while i < lines.count {
                let raw = lines[i].1
                if raw.trimmingCharacters(in: .whitespaces).isEmpty { collected.append(""); i += 1; continue }
                let ind = raw.prefix { $0 == " " }.count
                if blockIndent == nil { blockIndent = ind }
                guard ind >= blockIndent!, ind > parentIndent else { break }
                collected.append(String(raw.dropFirst(blockIndent!)))
                i += 1
            }
            var trailing = 0
            while let last = collected.last, last.isEmpty { collected.removeLast(); trailing += 1 }
            var text: String
            if folded {
                text = ""
                var previousBlank = false
                for (n, line) in collected.enumerated() {
                    if line.isEmpty { text += "\n"; previousBlank = true; continue }
                    if n > 0 && !previousBlank && !line.hasPrefix(" ") && !(collected[n - 1].hasPrefix(" ")) { text += " " }
                    else if n > 0 && !previousBlank { text += "\n" }
                    text += line
                    previousBlank = false
                }
            } else {
                text = collected.joined(separator: "\n")
            }
            if chompStrip { return text }
            if chompKeep { return text + String(repeating: "\n", count: trailing + 1) }
            return text.isEmpty ? "" : text + "\n"
        }

        func balanced(_ s: String) -> Bool {
            var depth = 0
            var inSingle = false, inDouble = false
            var prev: Character = " "
            for ch in s {
                if ch == "\"" && !inSingle && prev != "\\" { inDouble.toggle() }
                else if ch == "'" && !inDouble { inSingle.toggle() }
                else if !inSingle && !inDouble {
                    if ch == "[" || ch == "{" { depth += 1 }
                    if ch == "]" || ch == "}" { depth -= 1 }
                }
                prev = ch
            }
            return depth <= 0
        }

        func unquoteKey(_ k: String) throws -> String {
            if case .string(let s) = try parseScalar(k, forceString: true) { return s }
            return k
        }

        func parseScalar(_ text: String, forceString: Bool = false) throws -> DataValue {
            let t = text.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("&") || t.hasPrefix("*") { throw err("Anchors and aliases are not supported") }
            if t.hasPrefix("!") { throw err("Tags are not supported") }
            if t.hasPrefix("\"") {
                guard t.count >= 2, t.hasSuffix("\""), let v = try? JSONCodec.parse(t), case .string = v else {
                    throw err("Invalid double-quoted string")
                }
                return v
            }
            if t.hasPrefix("'") {
                guard t.count >= 2, t.hasSuffix("'") else { throw err("Invalid single-quoted string") }
                return .string(String(t.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'"))
            }
            if forceString { return .string(t) }
            if t.hasPrefix("[") || t.hasPrefix("{") { return try parseFlow(t) }
            switch t {
            case "", "~", "null", "Null", "NULL": return .null
            case "true", "True", "TRUE": return .bool(true)
            case "false", "False", "FALSE": return .bool(false)
            default: break
            }
            if t.range(of: #"^[-+]?(0|[1-9][0-9]*)$"#, options: .regularExpression) != nil {
                return .number(t.hasPrefix("+") ? String(t.dropFirst()) : t)
            }
            if t.range(of: #"^[-+]?(\.[0-9]+|[0-9]+(\.[0-9]*)?)([eE][-+]?[0-9]+)?$"#, options: .regularExpression) != nil {
                var n = t.hasPrefix("+") ? String(t.dropFirst()) : t
                if n.hasPrefix(".") { n = "0" + n } else if n.hasPrefix("-.") { n = "-0" + n.dropFirst() }
                if n.hasSuffix(".") { n += "0" }
                return .number(n)
            }
            if t.range(of: #"^0x[0-9a-fA-F]+$"#, options: .regularExpression) != nil, let v = Int64(t.dropFirst(2), radix: 16) {
                return .number(String(v))
            }
            return .string(t)
        }

        func parseFlow(_ text: String) throws -> DataValue {
            var chars = Array(text)
            var idx = 0
            func skip() { while idx < chars.count, chars[idx] == " " { idx += 1 } }
            func token(until stops: Set<Character>) -> String {
                var s = ""
                var quote: Character?
                while idx < chars.count {
                    let c = chars[idx]
                    if let q = quote { s.append(c); idx += 1; if c == q { quote = nil }; continue }
                    if c == "\"" || c == "'" { quote = c; s.append(c); idx += 1; continue }
                    if stops.contains(c) { break }
                    s.append(c); idx += 1
                }
                return s.trimmingCharacters(in: .whitespaces)
            }
            func value() throws -> DataValue {
                skip()
                guard idx < chars.count else { throw err("Unterminated flow collection") }
                if chars[idx] == "[" {
                    idx += 1
                    var items: [DataValue] = []
                    skip()
                    if idx < chars.count, chars[idx] == "]" { idx += 1; return .array(items) }
                    while true {
                        items.append(try value())
                        skip()
                        guard idx < chars.count else { throw err("Unterminated flow sequence") }
                        if chars[idx] == "," { idx += 1; skip(); if idx < chars.count, chars[idx] == "]" { idx += 1; return .array(items) }; continue }
                        if chars[idx] == "]" { idx += 1; return .array(items) }
                        throw err("Expected ',' or ']'")
                    }
                }
                if chars[idx] == "{" {
                    idx += 1
                    var members: [(String, DataValue)] = []
                    skip()
                    if idx < chars.count, chars[idx] == "}" { idx += 1; return .object(members) }
                    while true {
                        skip()
                        let k = token(until: [":", ",", "}"])
                        guard idx < chars.count, chars[idx] == ":" else { throw err("Expected ':' in flow mapping") }
                        idx += 1
                        members.append((try unquoteKey(k), try value()))
                        skip()
                        guard idx < chars.count else { throw err("Unterminated flow mapping") }
                        if chars[idx] == "," { idx += 1; continue }
                        if chars[idx] == "}" { idx += 1; return .object(members) }
                        throw err("Expected ',' or '}'")
                    }
                }
                return try parseScalar(token(until: [",", "]", "}"]))
            }
            let v = try value()
            skip()
            guard idx == chars.count else { throw err("Unexpected content after flow collection") }
            chars.removeAll()
            return v
        }
    }

    /// Splits "key: value" (or "key:") outside quotes. Returns nil for scalars.
    static func splitKey(_ content: String) -> (String, String)? {
        var quote: Character?
        var depth = 0
        let chars = Array(content)
        for (n, c) in chars.enumerated() {
            if let q = quote { if c == q { quote = nil }; continue }
            if (c == "\"" || c == "'") && n == 0 { quote = c; continue }
            if c == "[" || c == "{" { if n == 0 { return nil }; depth += 1 }
            if c == "]" || c == "}" { depth -= 1 }
            if c == ":" && depth == 0 && (n == chars.count - 1 || chars[n + 1] == " ") {
                let key = String(chars[0..<n]).trimmingCharacters(in: .whitespaces)
                guard !key.isEmpty else { return nil }
                return (key, String(chars[(n + 1)...]).trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    static func stripComment(_ line: String) -> String {
        var quote: Character?
        let chars = Array(line)
        for (n, c) in chars.enumerated() {
            if let q = quote { if c == q { quote = nil }; continue }
            if c == "\"" || c == "'" {
                if n == 0 || chars[n - 1] == " " || chars[n - 1] == ":" || chars[n - 1] == "[" || chars[n - 1] == "{" || chars[n - 1] == "," || chars[n - 1] == "-" { quote = c }
                continue
            }
            if c == "#" && (n == 0 || chars[n - 1] == " ") { return String(chars[0..<n]) }
        }
        return line
    }
}
