import Foundation
import ImageIO
import PDFKit

/// Which implementation performs a conversion.
enum ConversionEngineKind: String, Sendable, Hashable {
    case image          // ImageIO / Core Graphics (+ cwebp for WebP)
    case pdfRender      // PDFKit → raster images
    case pdfText        // PDFKit → text / markdown / rich text
    case document       // NSAttributedString document readers & writers
    case structuredData // JSON / YAML / plist / XML / CSV
    case spreadsheet    // CSV / TSV / XLSX
    case subtitle       // SRT / VTT / SBV / ASS / LRC
    case media          // AVFoundation, FFmpeg fallback for other containers
    case archive        // bsdtar (libarchive), part of macOS
}

/// One target offered in the Convert wheel.
struct ConversionOption: Hashable, Sendable, Identifiable {
    let target: FileFormat
    let engine: ConversionEngineKind
    let status: VerificationStatus
    /// Short, specific consequence shown on hover ("Transparency becomes white").
    let note: String?

    var id: String { target.id }
    var requiresConfirmation: Bool { status == .bestEffort }
}

/// Facts about a concrete file that change what a conversion means.
struct FileInspection: Sendable {
    var hasAlpha = false
    var frameCount = 1
    var pageCount = 1
    var isLossySource = false
    var pdfHasText = true
    /// Structured data facts (only inspected for files up to 8 MB).
    var dataContainsNull = false
    var dataIsListOfObjects = false

    static func inspect(_ file: ClassifiedFile) -> FileInspection {
        var info = FileInspection()
        guard let format = file.format else { return info }
        switch format.category {
        case .image where format.id != "svg":
            if let source = CGImageSourceCreateWithURL(file.url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) {
                info.frameCount = max(1, CGImageSourceGetCount(source))
                if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    info.hasAlpha = (props[kCGImagePropertyHasAlpha] as? Bool) ?? false
                }
            }
        case .image:
            info.hasAlpha = true
        case .pdf:
            if let doc = PDFDocument(url: file.url) {
                info.pageCount = max(1, doc.pageCount)
                // Sample the first pages: scans have no text layer.
                let sample = (0..<min(doc.pageCount, 3)).compactMap { doc.page(at: $0)?.string }.joined()
                info.pdfHasText = !sample.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        case .structuredData:
            let size = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            if size <= 8_000_000, let value = try? DataEngine.read(file.url, format: format) {
                info.dataContainsNull = value.containsNull
                if case .array(let items) = value, !items.isEmpty {
                    info.dataIsListOfObjects = items.allSatisfy { if case .object = $0 { return true } else { return false } }
                }
            }
        case .audio:
            info.isLossySource = !format.isLossless && format.id != "caf"
        default:
            break
        }
        return info
    }
}

/// Computes conversion targets from *live* engine capabilities and the
/// concrete file. There is no static "everything converts to everything"
/// table: a target only appears if a working encoder exists on this Mac.
final class ConversionCatalog: Sendable {

    static let shared = ConversionCatalog()

    private let registry = FormatRegistry.shared
    private var caps: EngineCapabilities { .shared }

    // MARK: - Public

    func options(for files: [ClassifiedFile]) -> [ConversionOption] {
        let usable = files.filter { $0.format != nil }
        guard usable.count == files.count, let first = usable.first else { return [] }
        if usable.count == 1 {
            return options(for: first, inspection: FileInspection.inspect(first))
        }
        // Several files: offer targets every file supports (each file is
        // converted on its own), plus archives that bundle all of them.
        var common: [ConversionOption]? = nil
        for file in usable.prefix(200) {
            let opts = options(for: file, inspection: FileInspection())
            if let current = common {
                let ids = Set(opts.map(\.id))
                common = current.filter { ids.contains($0.id) }
            } else {
                common = opts.filter { $0.target.category != .archive }
            }
        }
        var result = common ?? []
        if caps.bsdtarPath != nil {
            for id in ["zip", "7z", "tgz"] where !result.contains(where: { $0.id == id }) {
                result.append(ConversionOption(target: registry[id], engine: .archive, status: .verified, note: "One archive with all \(usable.count) items"))
            }
        }
        return result
    }

    func options(for file: ClassifiedFile, inspection info: FileInspection) -> [ConversionOption] {
        guard let source = file.format else { return [] }
        switch source.category {
        case .image: return imageOptions(source, info)
        case .pdf: return pdfOptions(info)
        case .document: return documentOptions(source)
        case .spreadsheet: return spreadsheetOptions(source)
        case .structuredData: return dataOptions(source, info)
        case .subtitle: return subtitleOptions(source)
        case .video: return videoOptions(source)
        case .audio: return audioOptions(source, info)
        case .archive: return archiveOptions(source)
        case .folder: return archiveTargets(excluding: nil, note: nil)
        case .presentation, .ebook: return []
        }
    }

    /// Finds the option for a specific target (used to re-validate a drop).
    func option(for file: ClassifiedFile, target: String) -> ConversionOption? {
        options(for: file, inspection: FileInspection.inspect(file)).first { $0.id == target }
    }

    // MARK: - Images

    static let imageTargetOrder = ["png", "jpg", "heic", "webp", "tiff", "avif", "pdf", "bmp", "gif", "jp2", "ico", "icns"]

    private func imageOptions(_ source: FileFormat, _ info: FileInspection) -> [ConversionOption] {
        guard caps.canDecodeImage(source) else { return [] }
        return Self.imageTargetOrder.compactMap { id -> ConversionOption? in
            guard id != source.id, let target = registry.format(for: id), caps.canEncodeImage(target) else { return nil }
            var notes: [String] = []
            var status = VerificationStatus.verified
            if info.frameCount > 1 {
                if source.id == "tiff" && id == "pdf" {
                    notes.append("All \(info.frameCount) pages")
                } else if source.id == "tiff" && id != "tiff" {
                    notes.append("First of \(info.frameCount) pages")
                    status = .limited
                } else if source.supportsAnimation && !(id == "gif" || id == "png") {
                    notes.append("First of \(info.frameCount) frames")
                    status = .limited
                } else if source.supportsAnimation {
                    notes.append("Keeps all \(info.frameCount) frames")
                }
            }
            if info.hasAlpha && !target.supportsTransparency && id != "pdf" {
                notes.append("Transparency becomes white")
            }
            switch id {
            case "ico": notes.append("Icon up to 256 px")
            case "icns": notes.append("Icon sizes 16–1024 px")
            case "gif" where info.frameCount <= 1: notes.append("256 colours")
            default: break
            }
            if source.id == "raw" { notes.append("Developed with camera defaults") }
            if source.id == "svg" && id != "pdf" { notes.append("Rendered at 2×") }
            return ConversionOption(target: target, engine: .image, status: status, note: notes.isEmpty ? nil : notes.joined(separator: " · "))
        }
    }

    // MARK: - PDF

    private func pdfOptions(_ info: FileInspection) -> [ConversionOption] {
        var result: [ConversionOption] = []
        let pages = info.pageCount
        for id in ["png", "jpg", "tiff", "heic"] {
            guard let target = registry.format(for: id), caps.canEncodeImage(target) else { continue }
            let note: String
            if pages == 1 { note = "300 dpi" }
            else if id == "tiff" { note = "\(pages)-page TIFF, 300 dpi" }
            else { note = "\(pages) pages → folder of images" }
            result.append(ConversionOption(target: target, engine: .pdfRender, status: .verified, note: note))
        }
        if info.pdfHasText {
            result.append(ConversionOption(target: registry["txt"], engine: .pdfText, status: .verified, note: "Text only"))
            result.append(ConversionOption(target: registry["md"], engine: .pdfText, status: .limited, note: "Text with paragraphs"))
            result.append(ConversionOption(target: registry["docx"], engine: .pdfText, status: .bestEffort, note: "Rebuilt from text — layout differs"))
            result.append(ConversionOption(target: registry["rtf"], engine: .pdfText, status: .bestEffort, note: "Rebuilt from text — layout differs"))
            result.append(ConversionOption(target: registry["html"], engine: .pdfText, status: .bestEffort, note: "Rebuilt from text — layout differs"))
        } else {
            // Scanned PDF: text targets go through on-device OCR.
            result.append(ConversionOption(target: registry["txt"], engine: .pdfText, status: .limited, note: "Recognised with OCR — check the result"))
            result.append(ConversionOption(target: registry["docx"], engine: .pdfText, status: .bestEffort, note: "Recognised with OCR — layout differs"))
        }
        return result
    }

    // MARK: - Documents

    static let documentReadable: Set<String> = ["txt", "md", "html", "rtf", "rtfd", "docx", "doc", "odt", "webarchive"]

    private func documentOptions(_ source: FileFormat) -> [ConversionOption] {
        guard Self.documentReadable.contains(source.id) else { return [] }
        let rich = !["txt", "md"].contains(source.id)
        return ["pdf", "docx", "rtf", "html", "md", "txt", "odt", "doc"].compactMap { id in
            guard id != source.id else { return nil }
            if source.id == "rtfd" && id == "rtf" { return nil }
            var note: String?
            var status = VerificationStatus.verified
            if id == "txt" && source.id != "md" { note = "Formatting removed"; status = .limited }
            if id == "txt" && source.id == "md" { note = "Markdown syntax removed" }
            if id == "md" && rich { note = "Headings, lists, emphasis, links"; status = .limited }
            if id == "doc" { note = "Legacy Word format" }
            if id == "pdf" { note = "Paginated, A4/Letter by region" }
            return ConversionOption(target: registry[id], engine: .document, status: status, note: note)
        }
    }

    // MARK: - Spreadsheets & data

    private func spreadsheetOptions(_ source: FileFormat) -> [ConversionOption] {
        switch source.id {
        case "csv":
            return [
                ConversionOption(target: registry["tsv"], engine: .spreadsheet, status: .verified, note: nil),
                ConversionOption(target: registry["json"], engine: .spreadsheet, status: .verified, note: "First row as keys"),
                ConversionOption(target: registry["html"], engine: .spreadsheet, status: .verified, note: "HTML table"),
            ]
        case "tsv":
            return [
                ConversionOption(target: registry["csv"], engine: .spreadsheet, status: .verified, note: nil),
                ConversionOption(target: registry["json"], engine: .spreadsheet, status: .verified, note: "First row as keys"),
                ConversionOption(target: registry["html"], engine: .spreadsheet, status: .verified, note: "HTML table"),
            ]
        case "xlsx":
            guard caps.bsdtarPath != nil else { return [] }
            return [
                ConversionOption(target: registry["csv"], engine: .spreadsheet, status: .limited, note: "Values only · one file per sheet"),
                ConversionOption(target: registry["tsv"], engine: .spreadsheet, status: .limited, note: "Values only · one file per sheet"),
                ConversionOption(target: registry["json"], engine: .spreadsheet, status: .limited, note: "Values only · all sheets"),
                ConversionOption(target: registry["html"], engine: .spreadsheet, status: .limited, note: "Values only · all sheets"),
            ]
        default:
            return []
        }
    }

    private func dataOptions(_ source: FileFormat, _ info: FileInspection) -> [ConversionOption] {
        var map: [String: [(String, String?)]] = [
            "json": [("yaml", nil), ("plist", "No null values"), ("xml", "Generic element mapping"), ("csv", "Needs a list of objects")],
            "yaml": [("json", nil), ("plist", "No null values")],
            "plist": [("json", "Dates and data as text"), ("yaml", "Dates and data as text"), ("xml", "XML property list")],
            "xml": [("json", "Attributes as @keys")],
        ]
        // Only offer targets that can represent this file's actual content.
        if info.dataContainsNull { for key in map.keys { map[key]?.removeAll { $0.0 == "plist" } } }
        if !info.dataIsListOfObjects { map["json"]?.removeAll { $0.0 == "csv" } }
        return (map[source.id] ?? []).map { id, note in
            let status: VerificationStatus = note == nil ? .verified : .limited
            let target = id == "xml" && source.id == "plist" ? registry["xml"] : registry[id]
            return ConversionOption(target: target, engine: .structuredData, status: status, note: note)
        }
    }

    private func subtitleOptions(_ source: FileFormat) -> [ConversionOption] {
        let targets: [String]
        switch source.id {
        case "srt": targets = ["vtt", "sbv", "txt"]
        case "vtt": targets = ["srt", "sbv", "txt"]
        case "sbv": targets = ["srt", "vtt", "txt"]
        case "ass": targets = ["srt", "vtt", "txt"]
        case "lrc": targets = ["srt", "vtt", "txt"]
        default: targets = []
        }
        return targets.map { id in
            var note: String?
            if id == "txt" { note = "Text only, no timing" }
            else if source.id == "ass" { note = "Styling removed" }
            else if source.id == "vtt" { note = "Cue settings removed" }
            return ConversionOption(target: registry[id], engine: .subtitle, status: note == nil ? .verified : .limited, note: note)
        }
    }

    // MARK: - Media

    static let avVideoSources: Set<String> = ["mp4", "mov", "m4v", "3gp"]
    static let avAudioSources: Set<String> = ["mp3", "m4a", "aac", "wav", "flac", "aiff", "caf", "opus", "ogg", "amr", "ac3"]

    private func videoOptions(_ source: FileFormat) -> [ConversionOption] {
        let native = Self.avVideoSources.contains(source.id)
        let ffmpeg = caps.ffmpeg != nil
        guard native || ffmpeg else { return [] }
        var result: [ConversionOption] = []
        func add(_ id: String, _ note: String?, _ status: VerificationStatus = .verified) {
            guard id != source.id else { return }
            result.append(ConversionOption(target: registry[id], engine: .media, status: status, note: note))
        }
        let h264 = native || caps.ffmpegHasEncoder("h264_videotoolbox") || caps.ffmpegHasEncoder("libx264")
        if h264 {
            add("mp4", native ? "Keeps codecs when possible" : "H.264 + AAC")
            add("mov", native ? "Keeps codecs when possible" : "H.264 + AAC")
            if native { add("m4v", "Keeps codecs when possible") }
        }
        if ffmpeg && caps.ffmpegHasEncoder("libvpx-vp9") && (caps.ffmpegHasEncoder("libopus") || caps.ffmpegHasEncoder("opus")) {
            add("webm", "VP9 + Opus", .limited)
        }
        if ffmpeg && (caps.ffmpegHasEncoder("libx264") || caps.ffmpegHasEncoder("h264_videotoolbox")) {
            add("mkv", "H.264 + AAC")
        }
        if caps.canEncodeImage(registry["gif"]) {
            add("gif", "No audio · max 480 px · 12 fps", .limited)
        }
        add("m4a", "Audio track only")
        if caps.ffmpegHasEncoder("libmp3lame") { add("mp3", "Audio track only") }
        return result
    }

    private func audioOptions(_ source: FileFormat, _ info: FileInspection) -> [ConversionOption] {
        let native = Self.avAudioSources.contains(source.id)
        let ffmpeg = caps.ffmpeg != nil
        guard native || ffmpeg else { return [] }
        let lossySource = !source.isLossless && source.id != "caf"
        var result: [ConversionOption] = []
        func add(_ id: String, lossless: Bool) {
            guard id != source.id else { return }
            if source.id == "m4a" && id == "aac" { return }
            var note: String?
            var status = VerificationStatus.verified
            if lossless && lossySource { note = "Won’t restore quality lost in \(source.label)" }
            if !lossless && !lossySource { note = "Lossy compression"; status = .limited }
            if !lossless && lossySource { note = "Re-encoded (lossy → lossy)"; status = .limited }
            result.append(ConversionOption(target: registry[id], engine: .media, status: status, note: note))
        }
        if caps.ffmpegHasEncoder("libmp3lame") { add("mp3", lossless: false) }
        add("m4a", lossless: false)
        add("wav", lossless: true)
        add("flac", lossless: true)
        add("aiff", lossless: true)
        if caps.ffmpegHasEncoder("libopus") { add("opus", lossless: false) }
        if caps.canEncodeOggVorbis { add("ogg", lossless: false) }
        add("caf", lossless: true)
        return result
    }

    // MARK: - Archives

    static let archiveReadable: Set<String> = ["zip", "7z", "rar", "tar", "tgz", "tbz2", "txz", "cpio", "cab", "iso"]
    static let archiveWritable = ["zip", "7z", "tgz", "txz", "tbz2", "tar"]

    private func archiveOptions(_ source: FileFormat) -> [ConversionOption] {
        guard Self.archiveReadable.contains(source.id) else { return [] }
        return archiveTargets(excluding: source.id, note: "Repacked, contents unchanged")
    }

    private func archiveTargets(excluding: String?, note: String?) -> [ConversionOption] {
        guard caps.bsdtarPath != nil else { return [] }
        return Self.archiveWritable.compactMap { id in
            guard id != excluding else { return nil }
            return ConversionOption(target: registry[id], engine: .archive, status: .verified, note: note)
        }
    }
}
