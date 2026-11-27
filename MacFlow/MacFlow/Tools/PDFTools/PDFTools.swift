import AppKit
import CoreText
import Foundation
import PDFKit
import Vision

enum PDFCompressLevel: String, CaseIterable, Sendable, Identifiable {
    case balanced, smallest
    var id: String { rawValue }
    var title: String { self == .balanced ? "Balanced" : "Smallest" }
    var detail: String { self == .balanced ? "Images re-saved as JPEG" : "Images as JPEG, reduced for screens" }
}

struct PageItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let sourceIndex: Int
    var rotation: Int = 0 // additional degrees, multiples of 90
}

struct PDFMetadataEdit: Sendable, Equatable {
    var title = ""
    var author = ""
    var subject = ""
    var keywords = ""
    var creator = ""
}

struct ProtectSettings: Sendable, Equatable {
    var password = ""
    var ownerPassword = ""
    var removeWithPassword = ""
    var allowPrinting = true
    var allowCopying = true
}

enum OverlayPosition: String, CaseIterable, Sendable, Identifiable {
    case bottomCenter, bottomRight, bottomLeft, topCenter, topRight, topLeft
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomCenter: return "Bottom Center"
        case .bottomRight: return "Bottom Right"
        case .bottomLeft: return "Bottom Left"
        case .topCenter: return "Top Center"
        case .topRight: return "Top Right"
        case .topLeft: return "Top Left"
        }
    }
}

struct WatermarkSettings: Sendable, Equatable {
    var text = "CONFIDENTIAL"
    var fontSize = 56.0
    var opacity = 0.18
    var diagonal = true
    var color = RGBAColor(r: 0.85, g: 0.1, b: 0.1)
    var tiled = false
}

enum PageNumberStyle: String, CaseIterable, Sendable, Identifiable {
    case plain, pageN, nOfTotal
    var id: String { rawValue }
    var title: String {
        switch self {
        case .plain: return "1"
        case .pageN: return "Page 1"
        case .nOfTotal: return "1 / 12"
        }
    }
}

struct PageNumberSettings: Sendable, Equatable {
    var position: OverlayPosition = .bottomCenter
    var style: PageNumberStyle = .plain
    var startAt = 1
    var fontSize = 11.0
    var skipFirstPage = false
}

enum OCROutput: String, CaseIterable, Sendable, Identifiable {
    case searchablePDF, text
    var id: String { rawValue }
    var title: String { self == .searchablePDF ? "Searchable PDF" : "Text File" }
}

enum SplitMode: Sendable, Equatable {
    case everyPage
    case everyN(Int)
    case ranges(String)
}

/// PDF tools. Results are always new documents; sources are opened read-only.
enum PDFTools {

    static func write(_ doc: PDFDocument, to url: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws {
        guard doc.write(to: url, withOptions: options) else {
            throw MacFlowError.encode("PDF")
        }
    }

    // MARK: - Compress

    static func compress(_ url: URL, level: PDFCompressLevel, destination: URL) throws {
        let doc = try PDFEngine.open(url)
        var options: [PDFDocumentWriteOption: Any] = [.saveImagesAsJPEGOption: true]
        if level == .smallest { options[.optimizeImagesForScreenOption] = true }
        try write(doc, to: destination, options: options)
        let before = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let after = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        if after >= before {
            throw MacFlowError("This PDF cannot be made smaller.", detail: "It contains little image data or is already optimised.")
        }
    }

    // MARK: - Pages

    static func organize(_ url: URL, pages: [PageItem], destination: URL) throws {
        guard !pages.isEmpty else { throw MacFlowError("A PDF needs at least one page.") }
        let source = try PDFEngine.open(url)
        let result = PDFDocument()
        result.documentAttributes = source.documentAttributes
        for (n, item) in pages.enumerated() {
            guard let page = source.page(at: item.sourceIndex)?.copy() as? PDFPage else { continue }
            page.rotation = ((page.rotation + item.rotation) % 360 + 360) % 360
            result.insert(page, at: n)
        }
        guard result.pageCount == pages.count else { throw MacFlowError("Some pages could not be copied.") }
        try write(result, to: destination)
    }

    static func pageCount(_ url: URL) -> Int { PDFDocument(url: url)?.pageCount ?? 0 }

    // MARK: - Metadata

    static func readMetadata(_ url: URL) -> PDFMetadataEdit {
        guard let attrs = PDFDocument(url: url)?.documentAttributes else { return PDFMetadataEdit() }
        func s(_ key: PDFDocumentAttribute) -> String {
            if let v = attrs[key] as? String { return v }
            if let v = attrs[key] as? [String] { return v.joined(separator: ", ") }
            return ""
        }
        return PDFMetadataEdit(title: s(.titleAttribute), author: s(.authorAttribute), subject: s(.subjectAttribute),
                               keywords: s(.keywordsAttribute), creator: s(.creatorAttribute))
    }

    static func writeMetadata(_ url: URL, edit: PDFMetadataEdit, destination: URL) throws {
        let doc = try PDFEngine.open(url)
        var attrs = doc.documentAttributes ?? [:]
        func set(_ key: PDFDocumentAttribute, _ value: String) {
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { attrs.removeValue(forKey: key) } else { attrs[key] = v }
        }
        set(.titleAttribute, edit.title)
        set(.authorAttribute, edit.author)
        set(.subjectAttribute, edit.subject)
        set(.creatorAttribute, edit.creator)
        let words = edit.keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if words.isEmpty { attrs.removeValue(forKey: PDFDocumentAttribute.keywordsAttribute) } else { attrs[PDFDocumentAttribute.keywordsAttribute] = words }
        attrs[PDFDocumentAttribute.modificationDateAttribute] = Date()
        doc.documentAttributes = attrs
        try write(doc, to: destination)
    }

    // MARK: - Protect

    static func protect(_ url: URL, settings: ProtectSettings, destination: URL) throws {
        guard let doc = PDFDocument(url: url) else { throw MacFlowError.decode(url.lastPathComponent) }
        if doc.isEncrypted {
            // Remove protection with a password the user knows.
            guard !settings.removeWithPassword.isEmpty else {
                throw MacFlowError("This PDF is already protected.", detail: "Enter its current password to remove the protection.")
            }
            guard doc.unlock(withPassword: settings.removeWithPassword) else {
                throw MacFlowError("The password is not correct.")
            }
            guard doc.allowsCopying || doc.permissionsStatus == .owner else {
                throw MacFlowError("Removing protection needs the owner password.")
            }
            // Writing an unlocked document keeps its encryption; copying the
            // pages into a new document writes a genuinely unprotected PDF.
            let plain = PDFDocument()
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                plain.insert(page, at: plain.pageCount)
            }
            guard plain.pageCount == doc.pageCount else { throw MacFlowError("Some pages could not be copied.") }
            plain.documentAttributes = doc.documentAttributes
            try write(plain, to: destination)
            if PDFDocument(url: destination)?.isEncrypted == true {
                throw MacFlowError.validation("The copy is still encrypted.")
            }
            return
        }
        guard settings.password.count >= 4 else { throw MacFlowError("Choose a password with at least 4 characters.") }
        // PDFAccessPermissions is a bit field exposed as an enum.
        var access: UInt = PDFAccessPermissions.allowsContentAccessibility.rawValue
            | PDFAccessPermissions.allowsFormFieldEntry.rawValue | PDFAccessPermissions.allowsCommenting.rawValue
        if settings.allowPrinting { access |= PDFAccessPermissions.allowsLowQualityPrinting.rawValue | PDFAccessPermissions.allowsHighQualityPrinting.rawValue }
        if settings.allowCopying { access |= PDFAccessPermissions.allowsContentCopying.rawValue }
        let owner = settings.ownerPassword.isEmpty ? settings.password + "-owner-" + UUID().uuidString.prefix(8) : settings.ownerPassword
        try write(doc, to: destination, options: [
            .userPasswordOption: settings.password,
            .ownerPasswordOption: owner,
            .accessPermissionsOption: NSNumber(value: access),
        ])
    }

    // MARK: - Overlays (watermark, page numbers)

    final class OverlayDelegate: NSObject, PDFDocumentDelegate {
        let draw: (PDFPage, Int, CGContext, CGRect) -> Void
        init(draw: @escaping (PDFPage, Int, CGContext, CGRect) -> Void) { self.draw = draw }
        func classForPage() -> AnyClass { OverlayPage.self }
    }

    final class OverlayPage: PDFPage {
        override func draw(with box: PDFDisplayBox, to context: CGContext) {
            super.draw(with: box, to: context)
            guard let doc = document, let delegate = doc.delegate as? OverlayDelegate else { return }
            let index = doc.index(for: self)
            context.saveGState()
            // Overlay in the displayed (rotated) coordinate space.
            let bounds = bounds(for: box)
            let display = PDFEngine.displaySize(self)
            switch rotation {
            case 90: context.translateBy(x: 0, y: bounds.height); context.rotate(by: -.pi / 2)
            case 180: context.translateBy(x: bounds.width, y: bounds.height); context.rotate(by: .pi)
            case 270: context.translateBy(x: bounds.width, y: 0); context.rotate(by: .pi / 2)
            default: break
            }
            context.translateBy(x: bounds.minX, y: bounds.minY)
            delegate.draw(self, index, context, CGRect(origin: .zero, size: display))
            context.restoreGState()
        }
    }

    static func overlay(_ url: URL, destination: URL, draw: @escaping (PDFPage, Int, CGContext, CGRect) -> Void) throws {
        let delegate = OverlayDelegate(draw: draw)
        guard let doc = PDFDocument(url: url) else { throw MacFlowError.decode(url.lastPathComponent) }
        if doc.isLocked { throw MacFlowError("This PDF is password-protected.", detail: "Remove the protection first.") }
        doc.delegate = delegate
        guard doc.pageCount > 0, doc.page(at: 0) is OverlayPage else {
            throw MacFlowError("The PDF pages could not be prepared.")
        }
        try withExtendedLifetime(delegate) { try write(doc, to: destination) }
    }

    static func drawText(_ text: String, in ctx: CGContext, at point: CGPoint, size: CGFloat, color: CGColor, alignment: CTTextAlignment, rotation: CGFloat = 0) {
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: rotation)
        let dx: CGFloat = alignment == .center ? -CGFloat(width) / 2 : (alignment == .right ? -CGFloat(width) : 0)
        ctx.textPosition = CGPoint(x: dx, y: rotation == 0 ? 0 : -size * 0.35)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    static func watermark(_ url: URL, settings: WatermarkSettings, destination: URL) throws {
        let text = settings.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MacFlowError("Enter the watermark text.") }
        var color = settings.color
        color.a = settings.opacity
        try overlay(url, destination: destination) { _, _, ctx, rect in
            let angle: CGFloat = settings.diagonal ? atan2(rect.height, rect.width) : 0
            if settings.tiled {
                let step = CGFloat(settings.fontSize) * 4
                var y = -rect.height
                while y < rect.height * 2 {
                    var x = -rect.width
                    while x < rect.width * 2 {
                        drawText(text, in: ctx, at: CGPoint(x: x, y: y), size: CGFloat(settings.fontSize), color: color.cgColor, alignment: .center, rotation: angle)
                        x += step * 2
                    }
                    y += step
                }
            } else {
                drawText(text, in: ctx, at: CGPoint(x: rect.midX, y: rect.midY), size: CGFloat(settings.fontSize), color: color.cgColor, alignment: .center, rotation: angle)
            }
        }
    }

    static func pageNumbers(_ url: URL, settings: PageNumberSettings, destination: URL) throws {
        let total = pageCount(url)
        try overlay(url, destination: destination) { _, index, ctx, rect in
            if settings.skipFirstPage && index == 0 { return }
            let number = settings.startAt + index - (settings.skipFirstPage ? 1 : 0)
            let label: String
            switch settings.style {
            case .plain: label = "\(number)"
            case .pageN: label = "Page \(number)"
            case .nOfTotal: label = "\(number) / \(total - (settings.skipFirstPage ? 1 : 0) + settings.startAt - 1)"
            }
            let size = CGFloat(settings.fontSize)
            let margin = max(18, size * 2.2)
            let x: CGFloat
            let alignment: CTTextAlignment
            switch settings.position {
            case .bottomLeft, .topLeft: x = margin; alignment = .left
            case .bottomRight, .topRight: x = rect.width - margin; alignment = .right
            default: x = rect.midX; alignment = .center
            }
            let top = [.topLeft, .topCenter, .topRight].contains(settings.position)
            let y = top ? rect.height - margin : margin - size * 0.3
            drawText(label, in: ctx, at: CGPoint(x: x, y: y), size: size, color: CGColor(gray: 0.15, alpha: 1), alignment: alignment)
        }
    }

    // MARK: - OCR

    struct RecognizedLine { let text: String; let box: CGRect }

    static func recognize(_ image: CGImage) throws -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { obs in
            guard let best = obs.topCandidates(1).first else { return nil }
            return RecognizedLine(text: best.string, box: obs.boundingBox)
        }
    }

    /// Recognised text of every page (existing text layers are reused).
    static func recognizedText(_ doc: PDFDocument, progress: @escaping ProgressHandler) async throws -> String {
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !existing.isEmpty { pages.append(existing) } else {
                pages.append(try recognize(try PDFEngine.render(page, dpi: 300, maxPixels: 40_000_000)).map(\.text).joined(separator: "\n"))
            }
            progress(Double(i + 1) / Double(doc.pageCount) * 0.9)
        }
        let text = pages.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw MacFlowError("No text was recognised in this PDF.") }
        return text
    }

    static func ocr(_ url: URL, output: OCROutput, destination: URL, progress: @escaping ProgressHandler) async throws {
        let doc = try PDFEngine.open(url)
        var allText: [String] = []
        var pages: [(PDFPage, [RecognizedLine], Bool)] = []
        for i in 0..<doc.pageCount {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if existing.count > 20 {
                pages.append((page, [], true))
                allText.append(existing)
            } else {
                let lines = try recognize(try PDFEngine.render(page, dpi: 300, maxPixels: 40_000_000))
                pages.append((page, lines, false))
                allText.append(lines.map(\.text).joined(separator: "\n"))
            }
            progress(Double(i + 1) / Double(doc.pageCount) * 0.9)
        }
        let joined = allText.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else { throw MacFlowError("No text was recognised in this PDF.") }
        if output == .text {
            try DocumentEngine.write(joined + "\n", to: destination)
            return
        }
        // Searchable PDF: original page + invisible text layer.
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(destination as CFURL, mediaBox: &box, [kCGPDFContextCreator: "MacFlow"] as CFDictionary) else {
            throw MacFlowError.encode("PDF")
        }
        for (page, lines, hadText) in pages {
            let size = PDFEngine.displaySize(page)
            var pageBox = CGRect(origin: .zero, size: size)
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            page.draw(with: .cropBox, to: ctx)
            if !hadText {
                ctx.saveGState()
                ctx.setTextDrawingMode(.invisible)
                for line in lines {
                    let rect = CGRect(x: line.box.minX * size.width, y: line.box.minY * size.height,
                                      width: line.box.width * size.width, height: line.box.height * size.height)
                    let fontSize = max(1, rect.height * 0.85)
                    let font = CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
                    let attributed = NSAttributedString(string: line.text, attributes: [.font: font])
                    let ctLine = CTLineCreateWithAttributedString(attributed)
                    let width = CGFloat(CTLineGetTypographicBounds(ctLine, nil, nil, nil))
                    ctx.saveGState()
                    ctx.translateBy(x: rect.minX, y: rect.minY + rect.height * 0.15)
                    if width > 0 { ctx.scaleBy(x: rect.width / width, y: 1) }
                    ctx.textPosition = .zero
                    CTLineDraw(ctLine, ctx)
                    ctx.restoreGState()
                }
                ctx.restoreGState()
            }
            ctx.endPDFPage()
        }
        ctx.closePDF()
        progress(1)
    }

    // MARK: - Split & merge

    static func parseRanges(_ text: String, pageCount: Int) throws -> [[Int]] {
        var groups: [[Int]] = []
        for part in text.split(separator: ",") {
            let p = part.trimmingCharacters(in: .whitespaces)
            guard !p.isEmpty else { continue }
            let bounds = p.split(separator: "-").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let a = Int(bounds[0]) else { throw MacFlowError("“\(p)” is not a valid page range.") }
            let b = bounds.count > 1 ? (bounds[1].isEmpty ? pageCount : Int(bounds[1])) : a
            guard let end = b, a >= 1, end >= a, end <= pageCount else {
                throw MacFlowError("“\(p)” is outside pages 1–\(pageCount).")
            }
            groups.append(Array((a - 1)..<end))
        }
        guard !groups.isEmpty else { throw MacFlowError("Enter at least one page range, e.g. 1-3, 5.") }
        return groups
    }

    static func split(_ url: URL, mode: SplitMode, into folder: URL, baseName: String) throws -> Int {
        let doc = try PDFEngine.open(url)
        let count = doc.pageCount
        let groups: [[Int]]
        switch mode {
        case .everyPage: groups = (0..<count).map { [$0] }
        case .everyN(let n):
            guard n >= 1 else { throw MacFlowError("Choose at least one page per file.") }
            groups = stride(from: 0, to: count, by: n).map { Array($0..<min(count, $0 + n)) }
        case .ranges(let text): groups = try parseRanges(text, pageCount: count)
        }
        guard groups.count > 1 || groups.first?.count != count else {
            throw MacFlowError("This would produce the same document again.")
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (n, group) in groups.enumerated() {
            let part = PDFDocument()
            for (i, index) in group.enumerated() {
                guard let page = doc.page(at: index)?.copy() as? PDFPage else { continue }
                part.insert(page, at: i)
            }
            let label = group.count == 1 ? "\(group[0] + 1)" : "\(group.first! + 1)-\(group.last! + 1)"
            _ = n
            try write(part, to: folder.appendingPathComponent("\(baseName) \(label).pdf"))
        }
        return groups.count
    }

    static func merge(_ urls: [URL], destination: URL) throws -> Int {
        guard urls.count >= 2 else { throw MacFlowError("Merging needs at least two PDFs.") }
        let result = PDFDocument()
        var index = 0
        for url in urls {
            let doc = try PDFEngine.open(url)
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i)?.copy() as? PDFPage else { continue }
                result.insert(page, at: index)
                index += 1
            }
        }
        try write(result, to: destination)
        return index
    }
}
