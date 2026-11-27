import Foundation

/// Structured data and spreadsheet conversions.
enum DataEngine {

    // MARK: - Structured data

    static func read(_ url: URL, format: FileFormat) throws -> DataValue {
        switch format.id {
        case "json":
            do { return try JSONCodec.parse(try DocumentEngine.readText(url)) } catch let e as JSONCodec.ParseError {
                throw MacFlowError("“\(url.lastPathComponent)” is not valid JSON.", detail: e.errorDescription)
            }
        case "yaml":
            do { return try YAMLCodec.parse(try DocumentEngine.readText(url)) } catch let e as YAMLCodec.ParseError {
                throw MacFlowError("“\(url.lastPathComponent)” could not be read as YAML.", detail: e.errorDescription)
            }
        case "plist":
            do { return try PlistCodec.parse(try Data(contentsOf: url)) } catch {
                throw MacFlowError.decode(url.lastPathComponent, "Not a valid property list.")
            }
        case "xml":
            return try XMLCodec.parse(try Data(contentsOf: url))
        default:
            throw MacFlowError.unsupported("Reading \(format.label)")
        }
    }

    static func convertStructured(source: URL, sourceFormat: FileFormat, target: FileFormat, destination: URL) throws {
        // A property list re-written as XML keeps the plist schema.
        if sourceFormat.id == "plist" && target.id == "xml" {
            let data = try Data(contentsOf: source)
            let object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            let xml = try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
            try xml.write(to: destination, options: .withoutOverwriting)
            return
        }
        let value = try read(source, format: sourceFormat)
        let output: Data
        switch target.id {
        case "json": output = Data(JSONCodec.serialize(value).utf8)
        case "yaml": output = Data(YAMLCodec.serialize(value).utf8)
        case "plist": output = try PlistCodec.serialize(value)
        case "xml": output = Data(XMLCodec.serialize(value).utf8)
        case "csv": output = Data(DelimitedText.serialize(try rows(fromJSON: value), delimiter: ",").utf8)
        default: throw MacFlowError.unsupported("Writing \(target.label)")
        }
        try output.write(to: destination, options: .withoutOverwriting)
    }

    /// JSON array of objects → table with the union of keys as header.
    static func rows(fromJSON value: DataValue) throws -> [[String]] {
        guard case .array(let items) = value, !items.isEmpty else {
            throw MacFlowError("CSV needs a JSON list of objects.", detail: "The top level of this file is not a list.")
        }
        var keys: [String] = []
        var seen = Set<String>()
        for item in items {
            guard case .object(let members) = item else {
                throw MacFlowError("CSV needs a JSON list of objects.", detail: "The list contains values that are not objects.")
            }
            for (k, _) in members where !seen.contains(k) { seen.insert(k); keys.append(k) }
        }
        var result = [keys]
        for item in items {
            guard case .object(let members) = item else { continue }
            let dict = Dictionary(members, uniquingKeysWith: { a, _ in a })
            result.append(keys.map { key in
                guard let v = dict[key] else { return "" }
                switch v {
                case .null: return ""
                case .array, .object: return JSONCodec.serialize(v, pretty: false)
                default: return XMLCodec.scalarText(v)
                }
            })
        }
        return result
    }

    // MARK: - Spreadsheets

    static func convertSpreadsheet(source: URL, sourceFormat: FileFormat, target: FileFormat, workDir: URL, baseName: String) async throws -> URL {
        let title = baseName
        switch sourceFormat.id {
        case "csv", "tsv":
            let text = try DocumentEngine.readText(source)
            let rows = DelimitedText.parse(text, delimiter: sourceFormat.id == "csv" ? "," : "\t")
            let output = workDir.appendingPathComponent("\(baseName).\(target.primaryExtension)")
            try writeTable(rows, as: target, to: output, title: title)
            return output
        case "xlsx":
            let sheets = try await XLSXReader.read(source)
            switch target.id {
            case "csv", "tsv":
                if sheets.count == 1 {
                    let output = workDir.appendingPathComponent("\(baseName).\(target.primaryExtension)")
                    try writeTable(sheets[0].rows, as: target, to: output, title: title)
                    return output
                }
                let folder = workDir.appendingPathComponent(baseName, isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                var used = Set<String>()
                for sheet in sheets {
                    var name = OutputPublisher.sanitize(sheet.name)
                    var n = 2
                    while used.contains(name.lowercased()) { name = "\(OutputPublisher.sanitize(sheet.name)) \(n)"; n += 1 }
                    used.insert(name.lowercased())
                    try writeTable(sheet.rows, as: target, to: folder.appendingPathComponent("\(name).\(target.primaryExtension)"), title: sheet.name)
                }
                return folder
            case "json":
                let value = DataValue.object(sheets.map { sheet in
                    (sheet.name, .array(sheet.rows.map { .array($0.map(DelimitedText.jsonValue)) }))
                })
                let output = workDir.appendingPathComponent("\(baseName).json")
                try Data(JSONCodec.serialize(value).utf8).write(to: output)
                return output
            case "html":
                let body = sheets.map { DelimitedText.htmlTable($0.rows, caption: $0.name) }.joined(separator: "\n")
                let output = workDir.appendingPathComponent("\(baseName).html")
                try Data(DelimitedText.htmlDocument(title: title, body: body).utf8).write(to: output)
                return output
            default:
                throw MacFlowError.unsupported("Writing \(target.label)")
            }
        default:
            throw MacFlowError.unsupported("Reading \(sourceFormat.label)")
        }
    }

    static func writeTable(_ rows: [[String]], as target: FileFormat, to url: URL, title: String) throws {
        let text: String
        switch target.id {
        case "csv": text = DelimitedText.serialize(rows, delimiter: ",")
        case "tsv": text = DelimitedText.serialize(rows, delimiter: "\t")
        case "json":
            guard let header = rows.first else { text = "[]\n"; break }
            let keys = DelimitedText.headerKeys(header)
            let objects = rows.dropFirst().map { row -> DataValue in
                .object(keys.enumerated().map { i, k in (k, DelimitedText.jsonValue(i < row.count ? row[i] : "")) })
            }
            text = JSONCodec.serialize(.array(Array(objects)))
        case "html":
            text = DelimitedText.htmlDocument(title: title, body: DelimitedText.htmlTable(rows))
        default:
            throw MacFlowError.unsupported("Writing \(target.label)")
        }
        try Data(text.utf8).write(to: url, options: .withoutOverwriting)
    }
}
