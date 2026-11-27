import Foundation

/// Order-preserving, lossless data model shared by the JSON, YAML, plist,
/// XML and CSV converters. Numbers keep their exact textual form so a
/// conversion never rounds or reformats values.
indirect enum DataValue: Equatable {
    case null
    case bool(Bool)
    case number(String)
    case string(String)
    case array([DataValue])
    case object([(String, DataValue)])
    case date(Date)
    case data(Data)

    static func == (lhs: DataValue, rhs: DataValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(a), .number(b)): return a == b || Double(a) == Double(b)
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            return a.count == b.count && zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        case let (.date(a), .date(b)): return a == b
        case let (.data(a), .data(b)): return a == b
        default: return false
        }
    }
}

extension DataValue {
    var containsNull: Bool {
        switch self {
        case .null: return true
        case .array(let items): return items.contains { $0.containsNull }
        case .object(let members): return members.contains { $0.1.containsNull }
        default: return false
        }
    }
}

// MARK: - JSON

enum JSONCodec {

    struct ParseError: LocalizedError {
        let message: String
        let line: Int
        var errorDescription: String? { "Invalid JSON (line \(line)): \(message)" }
    }

    static func parse(_ text: String) throws -> DataValue {
        var parser = Parser(Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.atEnd else { throw parser.error("Unexpected content after the JSON value") }
        return value
    }

    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        init(_ bytes: [UInt8]) {
            // Skip a UTF-8 BOM.
            if bytes.starts(with: [0xEF, 0xBB, 0xBF]) { self.bytes = Array(bytes.dropFirst(3)) } else { self.bytes = bytes }
        }
        var atEnd: Bool { i >= bytes.count }

        func error(_ message: String) -> ParseError {
            let line = bytes.prefix(min(i, bytes.count)).filter { $0 == 10 }.count + 1
            return ParseError(message: message, line: line)
        }

        mutating func skipWhitespace() {
            while i < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[i]) { i += 1 }
        }

        mutating func parseValue(depth: Int = 0) throws -> DataValue {
            guard depth < 512 else { throw error("Nesting too deep") }
            guard i < bytes.count else { throw error("Unexpected end of input") }
            switch bytes[i] {
            case UInt8(ascii: "{"):
                i += 1
                var members: [(String, DataValue)] = []
                skipWhitespace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                while true {
                    skipWhitespace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw error("Expected a key") }
                    let key = try parseString()
                    skipWhitespace()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw error("Expected ':'") }
                    i += 1
                    skipWhitespace()
                    members.append((key, try parseValue(depth: depth + 1)))
                    skipWhitespace()
                    guard i < bytes.count else { throw error("Unterminated object") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                    throw error("Expected ',' or '}'")
                }
            case UInt8(ascii: "["):
                i += 1
                var items: [DataValue] = []
                skipWhitespace()
                if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                while true {
                    skipWhitespace()
                    items.append(try parseValue(depth: depth + 1))
                    skipWhitespace()
                    guard i < bytes.count else { throw error("Unterminated array") }
                    if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                    if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                    throw error("Expected ',' or ']'")
                }
            case UInt8(ascii: "\""):
                return .string(try parseString())
            case UInt8(ascii: "t"):
                try expect("true"); return .bool(true)
            case UInt8(ascii: "f"):
                try expect("false"); return .bool(false)
            case UInt8(ascii: "n"):
                try expect("null"); return .null
            default:
                return .number(try parseNumber())
            }
        }

        mutating func expect(_ word: String) throws {
            let w = Array(word.utf8)
            guard i + w.count <= bytes.count, Array(bytes[i..<(i + w.count)]) == w else { throw error("Unexpected token") }
            i += w.count
        }

        mutating func parseNumber() throws -> String {
            let start = i
            if i < bytes.count, bytes[i] == UInt8(ascii: "-") { i += 1 }
            guard i < bytes.count, (48...57).contains(bytes[i]) else { throw error("Unexpected character") }
            if bytes[i] == UInt8(ascii: "0") { i += 1 } else { while i < bytes.count, (48...57).contains(bytes[i]) { i += 1 } }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard i < bytes.count, (48...57).contains(bytes[i]) else { throw error("Invalid number") }
                while i < bytes.count, (48...57).contains(bytes[i]) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard i < bytes.count, (48...57).contains(bytes[i]) else { throw error("Invalid number") }
                while i < bytes.count, (48...57).contains(bytes[i]) { i += 1 }
            }
            return String(decoding: bytes[start..<i], as: UTF8.self)
        }

        mutating func parseString() throws -> String {
            i += 1 // opening quote
            var scalars = [UInt8]()
            while i < bytes.count {
                let b = bytes[i]
                if b == UInt8(ascii: "\"") { i += 1; return String(decoding: scalars, as: UTF8.self) }
                if b < 0x20 { throw error("Control character in string") }
                if b == UInt8(ascii: "\\") {
                    i += 1
                    guard i < bytes.count else { break }
                    let e = bytes[i]
                    switch e {
                    case UInt8(ascii: "\""): scalars.append(0x22)
                    case UInt8(ascii: "\\"): scalars.append(0x5C)
                    case UInt8(ascii: "/"): scalars.append(0x2F)
                    case UInt8(ascii: "b"): scalars.append(0x08)
                    case UInt8(ascii: "f"): scalars.append(0x0C)
                    case UInt8(ascii: "n"): scalars.append(0x0A)
                    case UInt8(ascii: "r"): scalars.append(0x0D)
                    case UInt8(ascii: "t"): scalars.append(0x09)
                    case UInt8(ascii: "u"):
                        var code = try hex4()
                        if (0xD800...0xDBFF).contains(code), i + 2 < bytes.count, bytes[i + 1] == UInt8(ascii: "\\"), bytes[i + 2] == UInt8(ascii: "u") {
                            i += 2
                            let low = try hex4()
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00)
                        }
                        let scalar = Unicode.Scalar(code) ?? "\u{FFFD}"
                        scalars.append(contentsOf: Array(String(scalar).utf8))
                    default: throw error("Invalid escape")
                    }
                    i += 1
                    continue
                }
                scalars.append(b)
                i += 1
            }
            throw error("Unterminated string")
        }

        mutating func hex4() throws -> UInt32 {
            guard i + 4 < bytes.count else { throw error("Invalid unicode escape") }
            let s = String(decoding: bytes[(i + 1)...(i + 4)], as: UTF8.self)
            guard let v = UInt32(s, radix: 16) else { throw error("Invalid unicode escape") }
            i += 4
            return v
        }
    }

    static func serialize(_ value: DataValue, pretty: Bool = true) -> String {
        var out = ""
        write(value, into: &out, indent: 0, pretty: pretty)
        return out + (pretty ? "\n" : "")
    }

    private static func write(_ value: DataValue, into out: inout String, indent: Int, pretty: Bool) {
        let pad = pretty ? String(repeating: "  ", count: indent + 1) : ""
        let close = pretty ? String(repeating: "  ", count: indent) : ""
        let nl = pretty ? "\n" : ""
        switch value {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .number(let n): out += n
        case .string(let s): out += quote(s)
        case .date(let d): out += quote(ISO8601DateFormatter().string(from: d))
        case .data(let d): out += quote(d.base64EncodedString())
        case .array(let items):
            if items.isEmpty { out += "[]"; return }
            out += "[" + nl
            for (n, item) in items.enumerated() {
                out += pad
                write(item, into: &out, indent: indent + 1, pretty: pretty)
                out += n < items.count - 1 ? "," + nl : nl
            }
            out += close + "]"
        case .object(let members):
            if members.isEmpty { out += "{}"; return }
            out += "{" + nl
            for (n, (key, item)) in members.enumerated() {
                out += pad + quote(key) + (pretty ? ": " : ":")
                write(item, into: &out, indent: indent + 1, pretty: pretty)
                out += n < members.count - 1 ? "," + nl : nl
            }
            out += close + "}"
        }
    }

    static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 { out += String(format: "\\u%04x", scalar.value) } else { out.unicodeScalars.append(scalar) }
            }
        }
        return out + "\""
    }
}

// MARK: - Property lists

enum PlistCodec {
    static func parse(_ data: Data) throws -> DataValue {
        let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        return from(object)
    }

    static func from(_ object: Any) -> DataValue {
        switch object {
        case let d as [String: Any]:
            return .object(d.keys.sorted().map { ($0, from(d[$0]!)) })
        case let a as [Any]:
            return .array(a.map(from))
        case let n as NSNumber:
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return .bool(n.boolValue) }
            return .number(n.stringValue)
        case let s as String: return .string(s)
        case let d as Date: return .date(d)
        case let d as Data: return .data(d)
        default: return .string(String(describing: object))
        }
    }

    static func toObject(_ value: DataValue, path: String = "root") throws -> Any {
        switch value {
        case .null:
            throw MacFlowError("Property lists cannot contain null values.", detail: "Found at \(path).")
        case .bool(let b): return b
        case .number(let n):
            if let i = Int64(n) { return NSNumber(value: i) }
            if let d = Double(n) { return NSNumber(value: d) }
            throw MacFlowError("The number \(n) cannot be stored in a property list.")
        case .string(let s): return s
        case .date(let d): return d
        case .data(let d): return d
        case .array(let items): return try items.enumerated().map { try toObject($0.element, path: "\(path)[\($0.offset)]") }
        case .object(let members):
            var dict: [String: Any] = [:]
            for (k, v) in members { dict[k] = try toObject(v, path: "\(path).\(k)") }
            return dict
        }
    }

    static func serialize(_ value: DataValue) throws -> Data {
        let object = try toObject(value)
        guard PropertyListSerialization.propertyList(object, isValidFor: .xml) else {
            throw MacFlowError("The data cannot be represented as a property list.")
        }
        return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }
}

// MARK: - XML (generic mapping)

enum XMLCodec {

    /// Element → object; attributes become "@name", text "#text", repeated
    /// child elements become arrays. The root element name is the top key.
    static func parse(_ data: Data) throws -> DataValue {
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data, options: [.nodePreserveWhitespace]) } catch {
            throw MacFlowError("The XML is not well-formed.", detail: error.localizedDescription)
        }
        guard let root = doc.rootElement() else { throw MacFlowError("The XML document is empty.") }
        return .object([(root.name ?? "root", element(root))])
    }

    private static func element(_ e: XMLElement) -> DataValue {
        var members: [(String, DataValue)] = []
        for attr in e.attributes ?? [] {
            members.append(("@" + (attr.name ?? ""), .string(attr.stringValue ?? "")))
        }
        var childOrder: [String] = []
        var children: [String: [DataValue]] = [:]
        var text = ""
        for node in e.children ?? [] {
            switch node.kind {
            case .element:
                let child = node as! XMLElement
                let name = child.name ?? "element"
                if children[name] == nil { childOrder.append(name) }
                children[name, default: []].append(element(child))
            case .text:
                text += node.stringValue ?? ""
            default: break
            }
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if members.isEmpty && childOrder.isEmpty { return .string(trimmed) }
        for name in childOrder {
            let values = children[name]!
            members.append((name, values.count == 1 ? values[0] : .array(values)))
        }
        if !trimmed.isEmpty { members.append(("#text", .string(trimmed))) }
        return .object(members)
    }

    static func serialize(_ value: DataValue) -> String {
        var out = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
        if case .object(let members) = value, members.count == 1, isValidName(members[0].0), !members[0].0.hasPrefix("@"),
           !isArray(members[0].1) {
            write(name: members[0].0, value: members[0].1, indent: 0, into: &out)
        } else if case .array(let items) = value {
            // XML needs exactly one root element.
            out += "<root>\n"
            for item in items { write(name: "item", value: item, indent: 1, into: &out) }
            out += "</root>\n"
        } else {
            write(name: "root", value: value, indent: 0, into: &out)
        }
        return out
    }

    private static func isArray(_ v: DataValue) -> Bool {
        if case .array = v { return true }
        return false
    }

    private static func isValidName(_ s: String) -> Bool {
        guard let first = s.unicodeScalars.first, CharacterSet.letters.contains(first) || first == "_" else { return false }
        return s.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) }
    }

    private static func write(name rawName: String, value: DataValue, indent: Int, into out: inout String) {
        let name = isValidName(rawName) ? rawName : "item"
        let nameAttr = isValidName(rawName) ? "" : " name=\"\(escape(rawName))\""
        let pad = String(repeating: "  ", count: indent)
        switch value {
        case .array(let items):
            for item in items { write(name: rawName, value: item, indent: indent, into: &out) }
        case .object(let members):
            let attrs = members.filter { $0.0.hasPrefix("@") }
            let text = members.first { $0.0 == "#text" }?.1
            let children = members.filter { !$0.0.hasPrefix("@") && $0.0 != "#text" }
            var open = "<\(name)\(nameAttr)"
            for (k, v) in attrs { open += " \(String(k.dropFirst()))=\"\(escape(scalarText(v)))\"" }
            if children.isEmpty {
                if let text { out += "\(pad)\(open)>\(escape(scalarText(text)))</\(name)>\n" } else { out += "\(pad)\(open)/>\n" }
            } else {
                out += "\(pad)\(open)>\n"
                if let text { out += "\(pad)  \(escape(scalarText(text)))\n" }
                for (k, v) in children { write(name: k, value: v, indent: indent + 1, into: &out) }
                out += "\(pad)</\(name)>\n"
            }
        case .null:
            out += "\(pad)<\(name)\(nameAttr)/>\n"
        default:
            out += "\(pad)<\(name)\(nameAttr)>\(escape(scalarText(value)))</\(name)>\n"
        }
    }

    static func scalarText(_ v: DataValue) -> String {
        switch v {
        case .null: return ""
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return n
        case .string(let s): return s
        case .date(let d): return ISO8601DateFormatter().string(from: d)
        case .data(let d): return d.base64EncodedString()
        case .array, .object: return JSONCodec.serialize(v, pretty: false)
        }
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
