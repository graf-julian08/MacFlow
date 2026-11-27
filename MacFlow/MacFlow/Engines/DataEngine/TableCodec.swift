import Foundation

/// RFC 4180 delimited text (CSV/TSV) reading and writing.
enum DelimitedText {

    static func parse(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var atFieldStart = true
        var iterator = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? {
            if let p = pending { pending = nil; return p }
            return iterator.next()
        }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let n = next() {
                        if n == "\"" { field.append("\"") } else { inQuotes = false; pending = n }
                    } else { inQuotes = false }
                } else {
                    field.append(c)
                }
                continue
            }
            if c == "\"" && atFieldStart { inQuotes = true; atFieldStart = false; continue }
            if c == delimiter { row.append(field); field = ""; atFieldStart = true; continue }
            if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field); field = ""; atFieldStart = true
                rows.append(row); row = []
                continue
            }
            field.append(c)
            atFieldStart = false
        }
        if !field.isEmpty || !row.isEmpty || !atFieldStart {
            row.append(field)
            rows.append(row)
        }
        // Drop a single trailing empty row produced by a final newline.
        if let last = rows.last, last.count == 1, last[0].isEmpty { rows.removeLast() }
        return rows
    }

    static func serialize(_ rows: [[String]], delimiter: Character) -> String {
        var out = ""
        for row in rows {
            out += row.map { quote($0, delimiter: delimiter) }.joined(separator: String(delimiter))
            out += "\r\n"
        }
        return out
    }

    static func quote(_ field: String, delimiter: Character) -> String {
        let needs = field.contains(delimiter) || field.contains("\"") || field.contains("\n") || field.contains("\r")
            || field.hasPrefix(" ") || field.hasSuffix(" ")
        return needs ? "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : field
    }

    /// Unique, non-empty header names.
    static func headerKeys(_ header: [String]) -> [String] {
        var seen: [String: Int] = [:]
        return header.enumerated().map { index, raw in
            var key = raw.trimmingCharacters(in: .whitespaces)
            if key.isEmpty { key = "column \(index + 1)" }
            if let n = seen[key] { seen[key] = n + 1; key += " (\(n + 1))" } else { seen[key] = 1 }
            return key
        }
    }

    /// A string is emitted as a JSON number only if it is already canonical
    /// (no leading zeros, no thousands separators): the value round-trips exactly.
    static func jsonValue(_ s: String) -> DataValue {
        if s.range(of: #"^-?(0|[1-9][0-9]{0,14})(\.[0-9]{1,15})?$"#, options: .regularExpression) != nil,
           !(s.contains(".") && s.hasSuffix("0")) {
            return .number(s)
        }
        return .string(s)
    }

    static func htmlTable(_ rows: [[String]], caption: String? = nil) -> String {
        var out = "<table>\n"
        if let caption { out += "<caption>\(Markdown.escapeHTML(caption))</caption>\n" }
        for (n, row) in rows.enumerated() {
            let tag = n == 0 ? "th" : "td"
            out += "<tr>" + row.map { "<\(tag)>\(Markdown.escapeHTML($0))</\(tag)>" }.joined() + "</tr>\n"
        }
        return out + "</table>\n"
    }

    static func htmlDocument(title: String, body: String) -> String {
        """
        <!DOCTYPE html>
        <html>
        <head>
        <meta charset="utf-8">
        <title>\(Markdown.escapeHTML(title))</title>
        <style>
        body { font: 14px -apple-system, Helvetica, Arial, sans-serif; margin: 2em; }
        table { border-collapse: collapse; margin-bottom: 2em; }
        th, td { border: 1px solid #ccc; padding: 4px 8px; text-align: left; vertical-align: top; }
        th { background: #f2f2f2; }
        caption { text-align: left; font-weight: 600; font-size: 1.2em; margin-bottom: 0.4em; }
        </style>
        </head>
        <body>
        \(body)</body>
        </html>

        """
    }
}

/// Reads cell values from Office Open XML workbooks (.xlsx / .xlsm).
/// Formulas are represented by their last computed value.
enum XLSXReader {

    struct Sheet {
        let name: String
        let rows: [[String]]
    }

    static func read(_ url: URL) async throws -> [Sheet] {
        guard let bsdtar = EngineCapabilities.shared.bsdtarPath else { throw MacFlowError.unsupported("Reading XLSX") }
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("macflow-xlsx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // Only the parts we need; bsdtar refuses absolute and ../ paths by default.
        let result = try await ProcessRunner.run(bsdtar, ["-x", "-f", url.path, "-C", work.path, "xl/*", "[[]Content_Types[]].xml"], timeout: 300)
        guard result.status == 0 || FileManager.default.fileExists(atPath: work.appendingPathComponent("xl/workbook.xml").path) else {
            throw MacFlowError.decode(url.lastPathComponent, "This is not a valid Excel workbook.")
        }
        let xl = work.appendingPathComponent("xl")
        guard let workbook = try? Data(contentsOf: xl.appendingPathComponent("workbook.xml")) else {
            throw MacFlowError.decode(url.lastPathComponent, "The workbook part is missing.")
        }
        let wb = WorkbookParser(); wb.parse(workbook)
        let rels = RelationshipParser()
        if let relData = try? Data(contentsOf: xl.appendingPathComponent("_rels/workbook.xml.rels")) { rels.parse(relData) }
        var shared: [String] = []
        if let sst = try? Data(contentsOf: xl.appendingPathComponent("sharedStrings.xml")) {
            let p = SharedStringsParser(); p.parse(sst); shared = p.strings
        }
        var dateStyles: Set<Int> = []
        if let styles = try? Data(contentsOf: xl.appendingPathComponent("styles.xml")) {
            let p = StylesParser(); p.parse(styles); dateStyles = p.dateStyleIndices
        }
        var sheets: [Sheet] = []
        for (name, rid) in wb.sheets {
            try Task.checkCancellation()
            guard var target = rels.targets[rid] else { continue }
            if target.hasPrefix("/") { target = String(target.dropFirst()) } else { target = "xl/" + target }
            let sheetURL = work.appendingPathComponent(target)
            guard let parser = XMLParser(contentsOf: sheetURL) else { continue }
            let delegate = SheetParser(shared: shared, dateStyles: dateStyles, date1904: wb.date1904)
            parser.delegate = delegate
            guard parser.parse() else {
                throw MacFlowError.decode(url.lastPathComponent, "Sheet “\(name)” is damaged.")
            }
            sheets.append(Sheet(name: name, rows: delegate.rows))
        }
        guard !sheets.isEmpty else { throw MacFlowError.decode(url.lastPathComponent, "The workbook contains no sheets.") }
        return sheets
    }

    private final class WorkbookParser: NSObject, XMLParserDelegate {
        var sheets: [(String, String)] = []
        var date1904 = false
        func parse(_ data: Data) { let p = XMLParser(data: data); p.delegate = self; p.parse() }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "sheet", let sheetName = attributes["name"], let rid = attributes["r:id"] ?? attributes.first(where: { $0.key.hasSuffix(":id") })?.value {
                sheets.append((sheetName, rid))
            }
            if name == "workbookPr", let v = attributes["date1904"] { date1904 = v == "1" || v == "true" }
        }
    }

    private final class RelationshipParser: NSObject, XMLParserDelegate {
        var targets: [String: String] = [:]
        func parse(_ data: Data) { let p = XMLParser(data: data); p.delegate = self; p.parse() }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "Relationship", let id = attributes["Id"], let target = attributes["Target"] { targets[id] = target }
        }
    }

    private final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var current = ""
        private var inT = false
        private var inSI = false
        private var inPhonetic = false
        func parse(_ data: Data) { let p = XMLParser(data: data); p.delegate = self; p.parse() }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "si": inSI = true; current = ""
            case "t": inT = true
            case "rPh": inPhonetic = true
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { if inSI && inT && !inPhonetic { current += string } }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "si": strings.append(current); inSI = false
            case "t": inT = false
            case "rPh": inPhonetic = false
            default: break
            }
        }
    }

    private final class StylesParser: NSObject, XMLParserDelegate {
        var dateStyleIndices: Set<Int> = []
        private var customDateFormats: Set<Int> = []
        private var inCellXfs = false
        private var xfIndex = 0
        func parse(_ data: Data) { let p = XMLParser(data: data); p.delegate = self; p.parse() }
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if name == "numFmt", let id = attributes["numFmtId"].flatMap(Int.init), let code = attributes["formatCode"]?.lowercased() {
                let stripped = code.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
                    .replacingOccurrences(of: "\\[[^\\]]*\\]", with: "", options: .regularExpression)
                if stripped.contains("y") || stripped.contains("d") || (stripped.contains("m") && stripped.contains("h") == false && stripped.contains("s") == false && stripped.contains("0") == false) {
                    customDateFormats.insert(id)
                }
            }
            if name == "cellXfs" { inCellXfs = true; xfIndex = 0 }
            if name == "xf" && inCellXfs {
                if let id = attributes["numFmtId"].flatMap(Int.init), (14...22).contains(id) || (45...47).contains(id) || customDateFormats.contains(id) {
                    dateStyleIndices.insert(xfIndex)
                }
                xfIndex += 1
            }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            if name == "cellXfs" { inCellXfs = false }
        }
    }

    private final class SheetParser: NSObject, XMLParserDelegate {
        let shared: [String]
        let dateStyles: Set<Int>
        let date1904: Bool
        var rows: [[String]] = []
        private var row: [Int: String] = [:]
        private var rowIndex = 0
        private var cellColumn = 0
        private var cellType = ""
        private var cellStyle = -1
        private var value = ""
        private var inValue = false
        private var inInlineText = false
        private var nextColumn = 0

        init(shared: [String], dateStyles: Set<Int>, date1904: Bool) {
            self.shared = shared; self.dateStyles = dateStyles; self.date1904 = date1904
        }

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            switch name {
            case "row":
                row = [:]; nextColumn = 0
                if let r = attributes["r"].flatMap(Int.init) {
                    while rows.count < r - 1 { rows.append([]) } // keep empty rows
                    rowIndex = r
                }
            case "c":
                cellType = attributes["t"] ?? "n"
                cellStyle = attributes["s"].flatMap(Int.init) ?? -1
                cellColumn = attributes["r"].map(Self.column(of:)) ?? nextColumn
                value = ""
            case "v": inValue = true
            case "t" where cellType == "inlineStr": inInlineText = true
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inValue || inInlineText { value += string }
        }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "v": inValue = false
            case "t": inInlineText = false
            case "c":
                row[cellColumn] = render()
                nextColumn = cellColumn + 1
            case "row":
                let width = (row.keys.max() ?? -1) + 1
                rows.append((0..<width).map { row[$0] ?? "" })
            default: break
            }
        }

        private func render() -> String {
            switch cellType {
            case "s": return Int(value).flatMap { $0 < shared.count ? shared[$0] : nil } ?? ""
            case "b": return value == "1" ? "TRUE" : "FALSE"
            case "str", "inlineStr", "e": return value
            default:
                if dateStyles.contains(cellStyle), let serial = Double(value) { return Self.excelDate(serial, date1904: date1904) }
                return value
            }
        }

        static func excelDate(_ serial: Double, date1904: Bool) -> String {
            // Excel's 1900 system counts the nonexistent 29 Feb 1900.
            var days = serial
            if !date1904 && days >= 60 { days -= 1 }
            let base = date1904 ? DateComponents(year: 1904, month: 1, day: 1) : DateComponents(year: 1899, month: 12, day: 31)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC")!
            guard let origin = calendar.date(from: base) else { return String(serial) }
            let whole = floor(days)
            let seconds = ((days - whole) * 86400).rounded()
            let date = origin.addingTimeInterval(whole * 86400 + seconds)
            let formatter = DateFormatter()
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = seconds == 0 ? "yyyy-MM-dd" : (whole == 0 ? "HH:mm:ss" : "yyyy-MM-dd HH:mm:ss")
            return formatter.string(from: date)
        }

        static func column(of reference: String) -> Int {
            var result = 0
            for scalar in reference.unicodeScalars {
                guard scalar.value >= 65 && scalar.value <= 90 else { break }
                result = result * 26 + Int(scalar.value - 64)
            }
            return max(0, result - 1)
        }
    }
}
