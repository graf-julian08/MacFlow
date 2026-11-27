import AppKit
import Foundation

/// Document conversions built on Apple's NSAttributedString readers/writers
/// (RTF, RTFD, DOCX, DOC, ODT, HTML, WebArchive) plus MacFlow's Markdown
/// parser and a paginating PDF renderer.
enum DocumentEngine {

    // MARK: - Conversion entry point

    static func convert(source: URL, sourceFormat: FileFormat, target: FileFormat, destination: URL) async throws {
        try Task.checkCancellation()
        // Paths that never need an attributed string.
        switch (sourceFormat.id, target.id) {
        case ("md", "html"):
            let md = try readText(source)
            try write(Markdown.html(from: md, title: OutputPublisher.baseName(of: source)), to: destination)
            return
        case ("md", "txt"):
            try write(Markdown.plainText(from: try readText(source)), to: destination)
            return
        case ("txt", "md"):
            let text = try readText(source)
            let escaped = text.components(separatedBy: "\n\n").map { paragraph in
                paragraph.split(separator: "\n", omittingEmptySubsequences: false)
                    .map { MarkdownEscaper.escape(String($0)) }.joined(separator: "  \n")
            }.joined(separator: "\n\n")
            try write(escaped, to: destination)
            return
        case ("txt", "html"):
            let text = try readText(source)
            let body = text.components(separatedBy: "\n\n").map { "<p>" + Markdown.escapeHTML($0).replacingOccurrences(of: "\n", with: "<br>\n") + "</p>" }.joined(separator: "\n")
            try write("<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"utf-8\">\n<title>\(Markdown.escapeHTML(OutputPublisher.baseName(of: source)))</title>\n</head>\n<body>\n\(body)\n</body>\n</html>\n", to: destination)
            return
        default:
            break
        }
        let attributed = try await read(source, format: sourceFormat)
        try await write(attributed, as: target, to: destination, title: OutputPublisher.baseName(of: source))
    }

    // MARK: - Reading

    static func readText(_ url: URL) throws -> String {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try decodeText(data, name: url.lastPathComponent)
    }

    /// Decodes text, detecting BOMs and common legacy encodings.
    static func decodeText(_ data: Data, name: String) throws -> String {
        if data.isEmpty { return "" }
        if data.starts(with: [0xEF, 0xBB, 0xBF]), let s = String(data: data.dropFirst(3), encoding: .utf8) { return s }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let s = String(data: data, encoding: .utf16) { return s }
        if let s = String(data: data, encoding: .utf8) { return s }
        var converted: NSString?
        var lossy: ObjCBool = false
        let encoding = NSString.stringEncoding(for: data, encodingOptions: [.allowLossyKey: false], convertedString: &converted, usedLossyConversion: &lossy)
        if encoding != 0, let converted, !lossy.boolValue { return converted as String }
        for enc in [String.Encoding.windowsCP1252, .isoLatin1, .macOSRoman] {
            if let s = String(data: data, encoding: enc) { return s }
        }
        throw MacFlowError.decode(name, "The text encoding could not be determined.")
    }

    static func read(_ url: URL, format: FileFormat) async throws -> NSAttributedString {
        switch format.id {
        case "txt":
            let text = try readText(url)
            return NSAttributedString(string: text, attributes: baseAttributes)
        case "md":
            let html = Markdown.html(from: try readText(url))
            return try await importHTML(Data(html.utf8), name: url.lastPathComponent)
        case "html", "webarchive":
            let data = try Data(contentsOf: url)
            if format.id == "webarchive" {
                return try await MainActor.run {
                    try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.webArchive], documentAttributes: nil)
                }
            }
            return try await importHTML(data, name: url.lastPathComponent)
        case "rtf", "rtfd", "docx", "doc", "odt":
            let type: NSAttributedString.DocumentType = {
                switch format.id {
                case "rtf": return .rtf
                case "rtfd": return .rtfd
                case "docx": return .officeOpenXML
                case "doc": return .docFormat
                default: return .openDocument
                }
            }()
            do {
                return try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil)
            } catch {
                throw MacFlowError.decode(url.lastPathComponent, error.localizedDescription)
            }
        default:
            throw MacFlowError.unsupported("Reading \(format.label)")
        }
    }

    /// HTML import uses WebKit and must run on the main thread.
    private static func importHTML(_ data: Data, name: String) async throws -> NSAttributedString {
        try await MainActor.run {
            do {
                return try NSAttributedString(
                    data: data,
                    options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                    documentAttributes: nil
                )
            } catch {
                throw MacFlowError.decode(name, error.localizedDescription)
            }
        }
    }

    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont(name: "Helvetica", size: 12) ?? NSFont.systemFont(ofSize: 12)]
    }

    // MARK: - Writing

    static func write(_ string: String, to url: URL) throws {
        try Data(string.utf8).write(to: url, options: .withoutOverwriting)
    }

    static func write(_ text: NSAttributedString, as format: FileFormat, to url: URL, title: String) async throws {
        let range = NSRange(location: 0, length: text.length)
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.title: title]
        switch format.id {
        case "txt":
            try write(text.string.replacingOccurrences(of: "\u{2028}", with: "\n").replacingOccurrences(of: "\u{FFFC}", with: ""), to: url)
        case "md":
            try write(MarkdownWriter.markdown(from: text), to: url)
        case "pdf":
            try PDFTextRenderer.render(text, to: url, title: title)
        case "rtfd":
            attrs[.documentType] = NSAttributedString.DocumentType.rtfd
            let wrapper = try text.fileWrapper(from: range, documentAttributes: attrs)
            try wrapper.write(to: url, options: [], originalContentsURL: nil)
        default:
            let type: NSAttributedString.DocumentType
            switch format.id {
            case "rtf": type = .rtf
            case "docx": type = .officeOpenXML
            case "doc": type = .docFormat
            case "odt": type = .openDocument
            case "html": type = .html
            case "webarchive": type = .webArchive
            default: throw MacFlowError.unsupported("Writing \(format.label)")
            }
            attrs[.documentType] = type
            if type == .html {
                attrs[.characterEncoding] = String.Encoding.utf8.rawValue
            }
            let data = try text.data(from: range, documentAttributes: attrs)
            try data.write(to: url, options: .withoutOverwriting)
        }
    }
}

// MARK: - Attributed string → Markdown

enum MarkdownWriter {

    static func markdown(from text: NSAttributedString) -> String {
        let string = text.string as NSString
        guard string.length > 0 else { return "" }
        let baseSize = dominantFontSize(text)
        var blocks: [String] = []
        var listCounters: [Int: Int] = [:]
        var previousWasList = false

        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length), options: .byParagraphs) { _, range, _, _ in
            let paragraphText = string.substring(with: range).trimmingCharacters(in: .whitespaces)
            guard !paragraphText.isEmpty, paragraphText != "\u{FFFC}" else {
                if range.length == 0 { listCounters.removeAll() }
                return
            }
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
            let font = text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont
            let inline = inlineMarkdown(text, range: range)

            if let lists = style?.textLists, let list = lists.last {
                let depth = lists.count - 1
                var content = inline
                // Strip the marker text AppKit inserts ("•\t", "1.\t").
                if let tab = content.firstIndex(of: "\t"), content.distance(from: content.startIndex, to: tab) <= 6 {
                    content = String(content[content.index(after: tab)...])
                }
                let ordered = list.markerFormat.rawValue.contains("decimal") || list.markerFormat.rawValue.contains("alpha") || list.markerFormat.rawValue.contains("roman")
                let key = depth
                let number = (listCounters[key] ?? 0) + 1
                listCounters[key] = number
                for deeper in listCounters.keys where deeper > depth { listCounters[deeper] = nil }
                let indent = String(repeating: "    ", count: depth)
                let marker = ordered ? "\(number)." : "-"
                if previousWasList, !blocks.isEmpty {
                    blocks[blocks.count - 1] += "\n\(indent)\(marker) \(content)"
                } else {
                    blocks.append("\(indent)\(marker) \(content)")
                }
                previousWasList = true
                return
            }
            previousWasList = false
            listCounters.removeAll()

            if let font, baseSize > 0 {
                let ratio = font.pointSize / baseSize
                let bold = font.fontDescriptor.symbolicTraits.contains(.bold)
                let level: Int? = ratio >= 1.8 ? 1 : ratio >= 1.45 ? 2 : ratio >= 1.2 ? 3 : (bold && ratio >= 1.05 && paragraphText.count < 120 ? 4 : nil)
                if let level {
                    let plain = paragraphText.replacingOccurrences(of: "\u{FFFC}", with: "")
                    blocks.append(String(repeating: "#", count: level) + " " + MarkdownEscaper.escape(plain))
                    return
                }
            }
            if let font, font.fontDescriptor.symbolicTraits.contains(.monoSpace) {
                blocks.append("```\n" + paragraphText + "\n```")
                return
            }
            blocks.append(inline)
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func dominantFontSize(_ text: NSAttributedString) -> CGFloat {
        var counts: [CGFloat: Int] = [:]
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            if let font = value as? NSFont { counts[font.pointSize.rounded(), default: 0] += range.length }
        }
        return counts.max { $0.value < $1.value }?.key ?? 12
    }

    private static func inlineMarkdown(_ text: NSAttributedString, range: NSRange) -> String {
        var out = ""
        text.enumerateAttributes(in: range) { attrs, sub, _ in
            var piece = (text.string as NSString).substring(with: sub).replacingOccurrences(of: "\u{FFFC}", with: "")
            guard !piece.isEmpty else { return }
            let leading = piece.prefix { $0 == " " }
            let trailing = String(piece.reversed().prefix { $0 == " " })
            piece = piece.trimmingCharacters(in: .whitespaces)
            guard !piece.isEmpty else { out += leading; return }
            var md = MarkdownEscaper.escapeInline(piece)
            if let font = attrs[.font] as? NSFont {
                let traits = font.fontDescriptor.symbolicTraits
                if traits.contains(.monoSpace) { md = "`" + piece.replacingOccurrences(of: "`", with: "'") + "`" }
                else {
                    if traits.contains(.italic) { md = "*\(md)*" }
                    if traits.contains(.bold) { md = "**\(md)**" }
                }
            }
            if let strike = attrs[.strikethroughStyle] as? Int, strike != 0 { md = "~~\(md)~~" }
            if let link = attrs[.link] {
                let url = (link as? URL)?.absoluteString ?? (link as? String) ?? ""
                if !url.isEmpty { md = "[\(md)](\(url))" }
            }
            out += leading + md + trailing
        }
        return out
    }
}

extension MarkdownEscaper {
    static func escapeInline(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "\\`*_[]<>".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

// MARK: - Attributed string → paginated PDF

enum PDFTextRenderer {

    /// Page size by region: US Letter for the Americas' Letter countries, A4 elsewhere.
    static var pageSize: CGSize {
        let letterRegions: Set<String> = ["US", "CA", "MX", "PH", "CL", "CO", "VE", "PR", "GT", "CR", "PA", "DO", "SV", "NI", "HN", "BO"]
        let region = Locale.current.region?.identifier ?? "US"
        return letterRegions.contains(region) ? CGSize(width: 612, height: 792) : CGSize(width: 595.28, height: 841.89)
    }

    static func render(_ text: NSAttributedString, to url: URL, title: String) throws {
        let page = pageSize
        let margin: CGFloat = 56
        let content = CGSize(width: page.width - margin * 2, height: page.height - margin * 2)

        let storage = NSTextStorage(attributedString: text.length > 0 ? text : NSAttributedString(string: " ", attributes: DocumentEngine.baseAttributes))
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)

        var containers: [NSTextContainer] = []
        while true {
            let container = NSTextContainer(size: content)
            container.lineFragmentPadding = 0
            layout.addTextContainer(container)
            containers.append(container)
            let range = layout.glyphRange(for: container)
            let lastGlyph = NSMaxRange(range)
            if lastGlyph >= layout.numberOfGlyphs || range.length == 0 || containers.count > 20_000 { break }
        }

        var box = CGRect(origin: .zero, size: page)
        let info: [CFString: Any] = [kCGPDFContextTitle: title, kCGPDFContextCreator: "MacFlow"]
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info as CFDictionary) else { throw MacFlowError.encode("PDF") }
        for container in containers {
            let glyphs = layout.glyphRange(for: container)
            if glyphs.length == 0 && containers.count > 1 { continue }
            ctx.beginPDFPage(nil)
            ctx.saveGState()
            // NSLayoutManager draws in a flipped coordinate system.
            ctx.translateBy(x: 0, y: page.height)
            ctx.scaleBy(x: 1, y: -1)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            let origin = CGPoint(x: margin, y: margin)
            layout.drawBackground(forGlyphRange: glyphs, at: origin)
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
            NSGraphicsContext.restoreGraphicsState()
            ctx.restoreGState()
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}
