import AppKit
import Foundation
import PDFKit

/// PDF → images / text conversions using PDFKit and Core Graphics.
enum PDFEngine {

    static func open(_ url: URL, password: String? = nil) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else {
            throw MacFlowError.decode(url.lastPathComponent, "The PDF is damaged or not a PDF.")
        }
        if doc.isLocked {
            guard let password, doc.unlock(withPassword: password) else {
                throw MacFlowError("“\(url.lastPathComponent)” is password-protected.", detail: "Unlock it first (File Tools → Protect lets you remove a password you know).")
            }
        }
        guard doc.pageCount > 0 else { throw MacFlowError.decode(url.lastPathComponent, "The PDF has no pages.") }
        return doc
    }

    // MARK: - Rendering

    /// Displayed size of a page in points, with page rotation applied.
    static func displaySize(_ page: PDFPage) -> CGSize {
        let box = page.bounds(for: .cropBox)
        let rotated = abs(page.rotation) % 180 == 90
        return rotated ? CGSize(width: box.height, height: box.width) : box.size
    }

    /// Renders one page on white at `dpi`, capped to ~80 megapixels.
    static func render(_ page: PDFPage, dpi: CGFloat = 300, maxPixels: CGFloat = 80_000_000) throws -> CGImage {
        let size = displaySize(page)
        guard size.width > 0, size.height > 0 else { throw MacFlowError("A page has no size.") }
        var scale = dpi / 72
        let pixels = size.width * scale * size.height * scale
        if pixels > maxPixels { scale *= sqrt(maxPixels / pixels) }
        let width = max(1, Int((size.width * scale).rounded()))
        let height = max(1, Int((size.height * scale).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw MacFlowError("Could not allocate memory for the page.")
        }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        ctx.scaleBy(x: scale, y: scale)
        // PDFKit applies the page rotation and crop-box origin itself.
        page.draw(with: .cropBox, to: ctx)
        guard let image = ctx.makeImage() else { throw MacFlowError("The page could not be rendered.") }
        return image
    }

    /// PDF → raster. One page → one file; several pages → a folder of files,
    /// except TIFF which holds all pages in one multi-page file.
    /// Returns the produced item (file or folder) inside `workDir`.
    static func renderToImages(
        _ url: URL, target: FileFormat, workDir: URL, baseName: String, quality: Double,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> URL {
        let doc = try open(url)
        let count = doc.pageCount
        if count == 1 || target.id == "tiff" {
            let output = workDir.appendingPathComponent("\(baseName).\(target.primaryExtension)")
            var frames: [ImageEngine.Frame] = []
            for i in 0..<count {
                try Task.checkCancellation()
                guard let page = doc.page(at: i) else { continue }
                frames.append(ImageEngine.Frame(image: try render(page), properties: [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300]))
                progress(Double(i + 1) / Double(count))
            }
            try ImageEngine.write(frames, to: output, format: target, quality: quality)
            return output
        }
        let folder = workDir.appendingPathComponent(baseName, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let digits = String(count).count
        for i in 0..<count {
            try Task.checkCancellation()
            guard let page = doc.page(at: i) else { continue }
            let image = try render(page)
            let number = String(repeating: "0", count: max(0, digits - String(i + 1).count)) + String(i + 1)
            let file = folder.appendingPathComponent("\(baseName) \(number).\(target.primaryExtension)")
            try ImageEngine.write([ImageEngine.Frame(image: image, properties: [kCGImagePropertyDPIWidth: 300, kCGImagePropertyDPIHeight: 300])],
                                  to: file, format: target, quality: quality)
            progress(Double(i + 1) / Double(count))
        }
        return folder
    }

    // MARK: - Text

    static func plainText(_ doc: PDFDocument) -> String {
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            let text = doc.page(at: i)?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            pages.append(text)
        }
        return pages.joined(separator: "\n\n")
    }

    static func requireText(_ doc: PDFDocument, name: String) throws -> String {
        let text = plainText(doc)
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacFlowError("“\(name)” contains no selectable text.", detail: "It is probably a scan. Use File Tools → OCR to recognise the text.")
        }
        return text
    }

    /// Markdown with paragraphs reflowed (line breaks inside a paragraph removed).
    static func markdown(_ doc: PDFDocument) -> String {
        var blocks: [String] = []
        for i in 0..<doc.pageCount {
            guard let text = doc.page(at: i)?.string else { continue }
            let paragraphs = text.components(separatedBy: "\n\n")
            for paragraph in paragraphs {
                let lines = paragraph.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                guard !lines.isEmpty else { continue }
                var joined = ""
                for line in lines {
                    if joined.hasSuffix("-"), let last = joined.dropLast().last, last.isLetter {
                        joined.removeLast() // de-hyphenate
                        joined += line
                    } else {
                        joined += joined.isEmpty ? line : " " + line
                    }
                }
                blocks.append(MarkdownEscaper.escape(joined))
            }
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    /// Rich text rebuilt from the PDF's text layer (best effort).
    static func attributedText(_ doc: PDFDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.attributedString else { continue }
            if result.length > 0 { result.append(NSAttributedString(string: "\n\n")) }
            result.append(text)
        }
        return result
    }
}

enum MarkdownEscaper {
    /// Escapes characters that would otherwise start Markdown syntax.
    static func escape(_ text: String) -> String {
        var out = ""
        for (i, ch) in text.enumerated() {
            if "\\`*_[]<>".contains(ch) { out.append("\\") }
            else if i == 0 && "#>+-|".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        // "1. " at line start would become a list.
        if let range = out.range(of: #"^\d+\. "#, options: .regularExpression) {
            let digits = out[range].dropLast(2)
            out.replaceSubrange(range, with: "\(digits)\\. ")
        }
        return out
    }
}
