import AppKit
import AVFoundation
import Foundation
import ImageIO
import PDFKit

/// What a result must satisfy beyond "decodes as its format".
struct ValidationExpectation: Sendable {
    var frames: Int?
    var pages: Int?
    var cues: Int?
    var minimumDuration: Double?
    var requireText = false
    var entries: Int?
    var pixelSize: CGSize?

    static let none = ValidationExpectation()
}

/// Re-opens every produced file with an independent decoder before it is
/// published. A result that fails here is deleted, never shown as success.
enum IntegrityValidator {

    static func validate(_ url: URL, as format: FileFormat, expecting expectation: ValidationExpectation = .none) async throws {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            throw MacFlowError.validation("No output was produced.")
        }
        if isDir.boolValue && format.id != "rtfd" {
            let items = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            guard !items.isEmpty else { throw MacFlowError.validation("The output folder is empty.") }
            if format.category == .folder || format.category == .archive { return }
            for item in items {
                var childExpectation = ValidationExpectation.none
                childExpectation.requireText = expectation.requireText
                let childFormat = FormatRegistry.shared.format(forFileName: item.lastPathComponent) ?? format
                try await validate(item, as: childFormat, expecting: childExpectation)
            }
            if let pages = expectation.pages, items.count != pages {
                throw MacFlowError.validation("Expected \(pages) files, found \(items.count).")
            }
            return
        }
        if !isDir.boolValue {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { throw MacFlowError.validation("The output file is empty.") }
        }

        switch format.category {
        case .image: try validateImage(url, format: format, expectation)
        case .pdf: try validatePDF(url, expectation)
        case .video: try await validateMedia(url, needsVideo: true, expectation)
        case .audio: try await validateMedia(url, needsVideo: false, expectation)
        case .document, .ebook: try await validateDocument(url, format: format, expectation)
        case .spreadsheet: try validateText(url, expectation)
        case .structuredData: try validateData(url, format: format)
        case .subtitle: try validateSubtitles(url, format: format, expectation)
        case .archive: try await validateArchive(url, expectation)
        case .presentation, .folder: break
        }
    }

    // MARK: - Images

    private static func validateImage(_ url: URL, format: FileFormat, _ e: ValidationExpectation) throws {
        if format.id == "pdf" { try validatePDF(url, e); return }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            throw MacFlowError.validation("The image cannot be opened.")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { throw MacFlowError.validation("The image contains no frames.") }
        if let frames = e.frames, count < frames {
            throw MacFlowError.validation("Expected \(frames) frames, found \(count).")
        }
        for index in Set([0, count - 1]) {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil), image.width > 0, image.height > 0 else {
                throw MacFlowError.validation("Frame \(index + 1) cannot be decoded.")
            }
            if index == 0, let expected = e.pixelSize, format.id != "ico", format.id != "icns" {
                if Int(expected.width) != image.width || Int(expected.height) != image.height {
                    throw MacFlowError.validation("Size is \(image.width)×\(image.height), expected \(Int(expected.width))×\(Int(expected.height)).")
                }
            }
        }
    }

    // MARK: - PDF

    private static func validatePDF(_ url: URL, _ e: ValidationExpectation) throws {
        guard let doc = PDFDocument(url: url) else { throw MacFlowError.validation("The PDF cannot be opened.") }
        guard doc.pageCount > 0 else { throw MacFlowError.validation("The PDF has no pages.") }
        if let pages = e.pages, doc.pageCount != pages {
            throw MacFlowError.validation("Expected \(pages) pages, found \(doc.pageCount).")
        }
        guard let first = doc.page(at: 0), first.bounds(for: .mediaBox).width > 0 else {
            throw MacFlowError.validation("The first page is invalid.")
        }
        if e.requireText, PDFEngine.plainText(doc).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MacFlowError.validation("The PDF contains no text.")
        }
    }

    // MARK: - Media

    private static func validateMedia(_ url: URL, needsVideo: Bool, _ e: ValidationExpectation) async throws {
        let ext = url.pathExtension.lowercased()
        let avReadable = ["mp4", "mov", "m4v", "m4a", "wav", "aiff", "aif", "caf", "flac", "mp3", "3gp", "aac", "ogg", "oga", "opus"].contains(ext)
        if avReadable {
            let asset = AVURLAsset(url: url)
            let readable = (try? await asset.load(.isReadable)) ?? false
            guard readable else { throw MacFlowError.validation("The media file cannot be read.") }
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard duration.isFinite, duration > 0 else { throw MacFlowError.validation("The media has no duration.") }
            if let min = e.minimumDuration, duration + 0.15 < min {
                throw MacFlowError.validation(String(format: "Duration is %.2f s, expected %.2f s.", duration, min))
            }
            let video = (try? await asset.loadTracks(withMediaType: .video)) ?? []
            let audio = (try? await asset.loadTracks(withMediaType: .audio)) ?? []
            if needsVideo && video.isEmpty { throw MacFlowError.validation("The video track is missing.") }
            if !needsVideo && audio.isEmpty { throw MacFlowError.validation("The audio track is missing.") }
            return
        }
        // Containers AVFoundation cannot open: decode a few seconds with FFmpeg.
        guard let ffmpeg = EngineCapabilities.shared.ffmpeg else {
            throw MacFlowError.validation("No decoder is available to verify this file.")
        }
        let result = try await ProcessRunner.run(ffmpeg.path, ["-nostdin", "-v", "error", "-i", url.path, "-t", "3", "-f", "null", "-"], timeout: 300)
        guard result.status == 0, result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MacFlowError.validation("FFmpeg could not decode the result: \(result.errorSummary)")
        }
    }

    // MARK: - Documents & text

    private static func validateText(_ url: URL, _ e: ValidationExpectation) throws {
        let data = try Data(contentsOf: url)
        guard String(data: data, encoding: .utf8) != nil else { throw MacFlowError.validation("The text is not valid UTF-8.") }
        if e.requireText, data.isEmpty { throw MacFlowError.validation("The text is empty.") }
    }

    private static func validateDocument(_ url: URL, format: FileFormat, _ e: ValidationExpectation) async throws {
        switch format.id {
        case "txt", "md":
            try validateText(url, e)
        case "html":
            try validateText(url, e)
        case "rtf", "rtfd", "docx", "doc", "odt", "webarchive":
            let type: NSAttributedString.DocumentType = [
                "rtf": .rtf, "rtfd": .rtfd, "docx": .officeOpenXML, "doc": .docFormat, "odt": .openDocument, "webarchive": .webArchive,
            ][format.id]!
            let text: NSAttributedString
            if format.id == "webarchive" {
                text = try await MainActor.run { try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) }
            } else {
                do { text = try NSAttributedString(url: url, options: [.documentType: type], documentAttributes: nil) } catch {
                    throw MacFlowError.validation("The \(format.label) file cannot be reopened.")
                }
            }
            if e.requireText, text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                throw MacFlowError.validation("The document is empty.")
            }
        default:
            break
        }
    }

    private static func validateData(_ url: URL, format: FileFormat) throws {
        do {
            switch format.id {
            case "json": _ = try JSONCodec.parse(try DocumentEngine.readText(url))
            case "yaml": _ = try YAMLCodec.parse(try DocumentEngine.readText(url))
            case "plist": _ = try PropertyListSerialization.propertyList(from: try Data(contentsOf: url), options: [], format: nil)
            case "xml": _ = try XMLDocument(data: try Data(contentsOf: url), options: [])
            default: try validateText(url, .none)
            }
        } catch {
            throw MacFlowError.validation("The \(format.label) output does not parse: \(error.userMessage)")
        }
    }

    private static func validateSubtitles(_ url: URL, format: FileFormat, _ e: ValidationExpectation) throws {
        let text = try DocumentEngine.readText(url)
        guard format.id != "txt" else { return }
        let cues = try SubtitleEngine.parse(text, format: format.id)
        if let expected = e.cues, cues.count != expected {
            throw MacFlowError.validation("Expected \(expected) subtitles, found \(cues.count).")
        }
    }

    private static func validateArchive(_ url: URL, _ e: ValidationExpectation) async throws {
        let entries = try await ArchiveEngine.list(url)
        guard !entries.isEmpty else { throw MacFlowError.validation("The archive is empty.") }
        if let expected = e.entries {
            let files = entries.filter { !$0.isDirectory }.count
            if files != expected { throw MacFlowError.validation("Expected \(expected) files in the archive, found \(files).") }
        }
    }
}
