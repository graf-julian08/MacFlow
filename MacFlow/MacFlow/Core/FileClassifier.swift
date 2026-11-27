import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A dropped item together with its content-verified format.
struct ClassifiedFile: Sendable, Hashable {
    let url: URL
    let format: FileFormat?
    let isDirectory: Bool
    /// True when the extension claims a different format than the content.
    let extensionMismatch: Bool
}

/// Identifies files by their *content* (magic bytes, container brands,
/// ImageIO type detection). The file extension is only used to disambiguate
/// container families whose signature is shared (ZIP-based office files,
/// ISO-BMFF audio vs. video, OLE2 documents, plain-text dialects).
final class FileClassifier: Sendable {

    static let shared = FileClassifier()

    private let registry = FormatRegistry.shared

    func classify(_ url: URL) -> ClassifiedFile {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            return ClassifiedFile(url: url, format: nil, isDirectory: false, extensionMismatch: false)
        }
        if isDir.boolValue {
            // Packages (RTFD, Pages bundles) keep their document identity;
            // every other directory is treated as a folder.
            let claimed = registry.format(forFileName: url.lastPathComponent)
            if let claimed, claimed.id == "rtfd" {
                return ClassifiedFile(url: url, format: claimed, isDirectory: true, extensionMismatch: false)
            }
            return ClassifiedFile(url: url, format: registry["folder"], isDirectory: true, extensionMismatch: false)
        }
        let claimed = registry.format(forFileName: url.lastPathComponent)
        let detected = detect(url: url, claimed: claimed)
        let mismatch: Bool = {
            guard let claimed, let detected else { return false }
            return claimed.id != detected.id
        }()
        return ClassifiedFile(url: url, format: detected, isDirectory: false, extensionMismatch: mismatch)
    }

    /// Convenience used by tests and tools.
    func format(of url: URL) -> FileFormat? { classify(url).format }

    // MARK: - Detection

    private func detect(url: URL, claimed: FileFormat?) -> FileFormat? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4096)) ?? Data()
        guard !head.isEmpty else {
            // An empty file has no content to convert, whatever its name.
            return nil
        }
        let b = [UInt8](head)

        if let format = detectBinary(b, url: url, claimed: claimed) {
            return format
        }
        if let format = detectText(head, claimed: claimed) {
            return format
        }
        // Last resort for image formats without a simple signature (e.g.
        // some RAW variants): let ImageIO inspect the content.
        if let format = detectWithImageIO(url: url) {
            return format
        }
        return nil
    }

    private func id(_ id: String) -> FileFormat? { registry.format(for: id) }

    private func detectBinary(_ b: [UInt8], url: URL, claimed: FileFormat?) -> FileFormat? {
        func starts(_ bytes: [UInt8], at offset: Int = 0) -> Bool {
            guard b.count >= offset + bytes.count else { return false }
            for (i, byte) in bytes.enumerated() where b[offset + i] != byte { return false }
            return true
        }
        func ascii(_ s: String, at offset: Int = 0) -> Bool { starts(Array(s.utf8), at: offset) }
        let claimedID = claimed?.id

        if starts([0xFF, 0xD8, 0xFF]) { return id("jpg") }
        if starts([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return id("png") }
        if ascii("GIF87a") || ascii("GIF89a") { return id("gif") }
        if ascii("RIFF"), b.count >= 12 {
            if ascii("WEBP", at: 8) { return id("webp") }
            if ascii("WAVE", at: 8) { return id("wav") }
            if ascii("AVI ", at: 8) { return id("avi") }
        }
        if ascii("II*\0") || ascii("MM\0*") || ascii("IIRO") || ascii("IIU\0") || ascii("FUJIFILMCCD-RAW") {
            // TIFF containers are also used by most camera RAW formats.
            if let claimedID, claimedID == "raw" { return verifiedImage(url: url, expected: "raw") }
            if ascii("II*\0") || ascii("MM\0*") { return id("tiff") }
            return verifiedImage(url: url, expected: "raw")
        }
        if b.count >= 12, ascii("ftyp", at: 4) {
            return detectISOBMFF(b, url: url, claimedID: claimedID)
        }
        if ascii("%PDF") { return id("pdf") }
        if b.count > 1024, let range = Data(b.prefix(1024)).range(of: Data("%PDF-".utf8)), range.lowerBound < 1024 {
            return id("pdf")
        }
        if starts([0x50, 0x4B, 0x03, 0x04]) || starts([0x50, 0x4B, 0x05, 0x06]) {
            let zipBased: Set<String> = ["docx", "xlsx", "pptx", "odt", "ods", "odp", "epub", "pages", "numbers", "key"]
            if let claimed, zipBased.contains(claimed.id) { return claimed }
            return id("zip")
        }
        if starts([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return id("7z") }
        if ascii("Rar!\u{1A}\u{07}") { return id("rar") }
        if starts([0x1F, 0x8B]) { return claimedID == "tgz" ? id("tgz") : id("gz") }
        if ascii("BZh") { return claimedID == "tbz2" ? id("tbz2") : id("bz2") }
        if starts([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return claimedID == "txz" ? id("txz") : id("xz") }
        if starts([0x28, 0xB5, 0x2F, 0xFD]) { return claimedID == "tzst" ? id("tzst") : nil }
        if ascii("ustar", at: 257) { return id("tar") }
        if ascii("070707") || ascii("070701") || ascii("070702") || starts([0xC7, 0x71]) { return id("cpio") }
        if ascii("MSCF") { return id("cab") }
        if ascii("fLaC") { return id("flac") }
        if ascii("OggS") {
            let window = Data(b.prefix(256))
            if window.range(of: Data("OpusHead".utf8)) != nil { return id("opus") }
            if window.range(of: Data("theora".utf8)) != nil { return id("ogv") }
            return id("ogg")
        }
        if ascii("FORM"), b.count >= 12, ascii("AIFF", at: 8) || ascii("AIFC", at: 8) { return id("aiff") }
        if ascii("caff") { return id("caf") }
        if ascii("#!AMR") { return id("amr") }
        if ascii("MAC ") { return id("ape") }
        if starts([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) {
            return claimedID == "wma" ? id("wma") : id("wmv")
        }
        if starts([0x1A, 0x45, 0xDF, 0xA3]) {
            let window = Data(b.prefix(64))
            if window.range(of: Data("webm".utf8)) != nil { return id("webm") }
            return claimedID == "mka" ? id("mka") : id("mkv")
        }
        if ascii("FLV") { return id("flv") }
        if starts([0x00, 0x00, 0x01, 0xBA]) || starts([0x00, 0x00, 0x01, 0xB3]) { return id("mpeg") }
        if b.count > 376, b[0] == 0x47, b[188] == 0x47, b[376] == 0x47 { return id("ts") }
        if ascii("ID3") {
            // ID3 tags precede MP3 frames, but also (rarely) AAC/FLAC data.
            if claimedID == "aac" || claimedID == "flac" { return claimed }
            return id("mp3")
        }
        if b.count >= 2, b[0] == 0xFF {
            if b[1] == 0xF1 || b[1] == 0xF9 { return id("aac") }
            if b[1] & 0xE0 == 0xE0, claimedID == "mp3" || claimedID == nil { return id("mp3") }
        }
        if ascii("8BPS") { return id("psd") }
        if starts([0x00, 0x00, 0x00, 0x0C, 0x6A, 0x50, 0x20, 0x20]) || starts([0xFF, 0x4F, 0xFF, 0x51]) { return id("jp2") }
        if starts([0xFF, 0x0A]) || starts([0x00, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x4C, 0x20]) { return id("jxl") }
        if ascii("icns") { return id("icns") }
        if starts([0x76, 0x2F, 0x31, 0x01]) { return id("exr") }
        if starts([0x00, 0x00, 0x01, 0x00]), claimedID == "ico" { return id("ico") }
        if ascii("BM"), b.count >= 14, claimedID == "bmp" || (b[6] == 0 && b[7] == 0 && b[8] == 0 && b[9] == 0) {
            return id("bmp")
        }
        if starts([0xD0, 0xCF, 0x11, 0xE0, 0xA1, 0xB1, 0x1A, 0xE1]) {
            // OLE2 compound files: the container cannot tell doc/xls/ppt apart cheaply.
            if let claimed, ["doc", "xls", "ppt"].contains(claimed.id) { return claimed }
            return nil
        }
        if ascii("bplist00") { return id("plist") }
        if ascii("{\\rtf") { return id("rtf") }
        if let claimed, claimed.category == .image, claimed.id == "raw" || claimed.id == "tga" {
            return verifiedImage(url: url, expected: claimed.id)
        }
        if claimedID == "iso" {
            return id("iso")
        }
        return nil
    }

    private func detectISOBMFF(_ b: [UInt8], url: URL, claimedID: String?) -> FileFormat? {
        let major = String(bytes: b[8..<12], encoding: .ascii) ?? ""
        // Compatible brands follow the minor version (offset 16) up to the box size.
        let boxSize = min(Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])), b.count)
        var brands: Set<String> = [major]
        var offset = 16
        while offset + 4 <= boxSize {
            if let brand = String(bytes: b[offset..<(offset + 4)], encoding: .ascii) { brands.insert(brand) }
            offset += 4
        }
        if brands.contains("avif") || brands.contains("avis") { return id("avif") }
        if !brands.isDisjoint(with: ["heic", "heix", "hevc", "hevx", "heim", "heis", "mif1", "msf1"]) {
            return id("heic")
        }
        if major == "crx " { return verifiedImage(url: url, expected: "raw") }
        if major == "qt  " { return id("mov") }
        if major.hasPrefix("3g") {
            return claimedID == "3gp" || claimedID == nil ? id("3gp") : id(claimedID!)
        }
        if major == "M4A " || major == "M4B " || major == "M4P " { return id("m4a") }
        if major == "M4V " || major == "M4VH" || major == "M4VP" { return id("m4v") }
        // Generic MPEG-4: audio-only and video files share brands; respect
        // the extension inside the family, otherwise inspect is too costly.
        if let claimedID, ["mp4", "m4a", "m4v", "mov", "3gp"].contains(claimedID) { return id(claimedID) }
        return id("mp4")
    }

    private func verifiedImage(url: URL, expected: String) -> FileFormat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetType(source) != nil else { return nil }
        return id(expected)
    }

    private func detectWithImageIO(url: URL) -> FileFormat? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source) as String?,
              let type = UTType(typeID) else { return nil }
        if type.conforms(to: .rawImage) { return id("raw") }
        if let format = registry.format(forUTType: type), format.category == .image { return format }
        return nil
    }

    private func detectText(_ head: Data, claimed: FileFormat?) -> FileFormat? {
        guard let text = Self.decodeText(head) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        let textual: Set<FileCategory> = [.document, .spreadsheet, .subtitle, .structuredData]

        if lower.hasPrefix("<?xml") || lower.hasPrefix("<!doctype") || lower.hasPrefix("<") {
            if lower.contains("<svg") { return id("svg") }
            if lower.contains("<!doctype plist") || lower.contains("<plist") { return id("plist") }
            if lower.hasPrefix("<!doctype html") || lower.contains("<html") || lower.contains("<head") || lower.contains("<body") {
                return id("html")
            }
            if let claimed, claimed.id == "html" || claimed.id == "md" || claimed.id == "txt" { return claimed }
            if lower.hasPrefix("<?xml") { return id("xml") }
            if let claimed, claimed.category == .structuredData { return claimed }
            return id("xml")
        }
        if trimmed.hasPrefix("WEBVTT") { return id("vtt") }
        if lower.hasPrefix("{\\rtf") { return id("rtf") }
        if trimmed.hasPrefix("[Script Info]") { return id("ass") }
        if Self.looksLikeSRT(trimmed) { return id("srt") }
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") {
            if let claimed, claimed.id == "json" { return claimed }
            if claimed == nil || claimed?.id == "txt" {
                // Only call it JSON when the head plausibly parses as such.
                if trimmed.hasPrefix("{\"") || trimmed.hasPrefix("[{") || trimmed.hasPrefix("[\"") || trimmed.hasPrefix("[]") || trimmed.hasPrefix("{}") {
                    return id("json")
                }
            }
        }
        // No distinctive signature: trust a text-family extension, otherwise
        // treat it as plain text.
        if let claimed, textual.contains(claimed.category) { return claimed }
        if claimed == nil || claimed?.category == .document { return id("txt") }
        return nil
    }

    static func looksLikeSRT(_ text: String) -> Bool {
        let lines = text.split(whereSeparator: \.isNewline).prefix(4).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count >= 2, Int(lines[0]) != nil else { return false }
        return lines[1].contains("-->") && lines[1].contains(",")
    }

    /// Decodes a sample of a text file, rejecting binary data.
    static func decodeText(_ data: Data) -> String? {
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return String(data: data.dropFirst(3), encoding: .utf8) ?? lossyUTF8(data.dropFirst(3)) }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) { return String(data: data, encoding: .utf16) }
        // Any NUL byte in the head means binary.
        if data.contains(0) { return nil }
        if let s = String(data: data, encoding: .utf8) { return s }
        // The sample may end in the middle of a multi-byte character.
        return lossyUTF8(data)
    }

    private static func lossyUTF8<D: DataProtocol>(_ data: D) -> String? {
        let s = String(decoding: data, as: UTF8.self)
        let replacements = s.unicodeScalars.filter { $0 == "\u{FFFD}" }.count
        // Tolerate a truncated trailing sequence, reject genuinely binary data.
        return replacements <= 2 ? s : nil
    }
}
