import Foundation
import UniformTypeIdentifiers

/// Every file format MacFlow can identify. Availability for conversion is
/// computed separately from live engine probes (`ConversionCatalog`).
final class FormatRegistry: Sendable {

    static let shared = FormatRegistry()

    let all: [FileFormat]
    private let byID: [String: FileFormat]
    private let byExtension: [String: FileFormat]

    private init() {
        let formats = Self.definitions
        all = formats
        byID = Dictionary(uniqueKeysWithValues: formats.map { ($0.id, $0) })
        var extensions: [String: FileFormat] = [:]
        for format in formats {
            for ext in format.extensions where !ext.isEmpty && extensions[ext] == nil {
                extensions[ext] = format
            }
        }
        byExtension = extensions
    }

    func format(for id: String) -> FileFormat? { byID[id] }

    /// Requires an existing ID. Only used with literals defined below.
    subscript(id: String) -> FileFormat {
        guard let format = byID[id] else { preconditionFailure("Unknown format id \(id)") }
        return format
    }

    func format(forExtension ext: String) -> FileFormat? {
        byExtension[ext.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))]
    }

    func format(forFileName name: String) -> FileFormat? {
        let lower = name.lowercased()
        // Compound extensions must win over their last component.
        for (suffix, id) in [(".tar.gz", "tgz"), (".tar.bz2", "tbz2"), (".tar.xz", "txz"), (".tar.zst", "tzst")] where lower.hasSuffix(suffix) {
            return byID[id]
        }
        return format(forExtension: (lower as NSString).pathExtension)
    }

    func format(forUTType type: UTType) -> FileFormat? {
        if let exact = all.first(where: { $0.utTypeIdentifiers.contains(type.identifier) }) {
            return exact
        }
        if let ext = type.preferredFilenameExtension {
            return format(forExtension: ext)
        }
        return nil
    }

    func formats(in category: FileCategory) -> [FileFormat] {
        all.filter { $0.category == category }
    }

    // MARK: - Definitions

    private static func f(
        _ id: String, _ label: String, _ name: String, _ exts: [String], _ utis: [String],
        _ category: FileCategory, alpha: Bool = false, animation: Bool = false,
        multipage: Bool = false, lossless: Bool = false
    ) -> FileFormat {
        FileFormat(
            id: id, label: label, displayName: name, extensions: exts, utTypeIdentifiers: utis,
            category: category, supportsTransparency: alpha, supportsAnimation: animation,
            supportsMultipage: multipage, isLossless: lossless
        )
    }

    /// Camera RAW extensions decoded by ImageIO. Each concrete file is still
    /// test-decoded before a conversion is offered (`FileClassifier`).
    static let rawExtensions = [
        "dng", "cr2", "cr3", "crw", "nef", "nrw", "arw", "srf", "sr2", "raf", "orf",
        "rw2", "raw", "pef", "srw", "3fr", "fff", "iiq", "erf", "mef", "mos", "rwl", "x3f"
    ]

    private static let definitions: [FileFormat] = [
        // Images
        f("jpg", "JPG", "JPEG", ["jpg", "jpeg", "jpe", "jfif"], ["public.jpeg"], .image),
        f("png", "PNG", "PNG", ["png"], ["public.png"], .image, alpha: true, animation: true, lossless: true),
        f("heic", "HEIC", "HEIC", ["heic", "heif", "hif"], ["public.heic", "public.heif"], .image, alpha: true),
        f("webp", "WEBP", "WebP", ["webp"], ["org.webmproject.webp"], .image, alpha: true, animation: true),
        f("tiff", "TIFF", "TIFF", ["tiff", "tif"], ["public.tiff"], .image, alpha: true, multipage: true, lossless: true),
        f("avif", "AVIF", "AVIF", ["avif"], ["public.avif"], .image, alpha: true),
        f("bmp", "BMP", "BMP", ["bmp", "dib"], ["com.microsoft.bmp"], .image, lossless: true),
        f("gif", "GIF", "GIF", ["gif"], ["com.compuserve.gif"], .image, alpha: true, animation: true),
        f("jp2", "JP2", "JPEG 2000", ["jp2", "j2k", "jpf", "jpx", "jpm"], ["public.jpeg-2000"], .image, alpha: true),
        f("jxl", "JXL", "JPEG XL", ["jxl"], ["public.jpeg-xl"], .image, alpha: true),
        f("ico", "ICO", "Windows Icon", ["ico"], ["com.microsoft.ico"], .image, alpha: true),
        f("icns", "ICNS", "Apple Icon", ["icns"], ["com.apple.icns"], .image, alpha: true),
        f("psd", "PSD", "Photoshop", ["psd"], ["com.adobe.photoshop-image"], .image, alpha: true),
        f("tga", "TGA", "Targa", ["tga"], ["com.truevision.tga-image"], .image, alpha: true),
        f("exr", "EXR", "OpenEXR", ["exr"], ["com.ilm.openexr-image"], .image, alpha: true),
        f("svg", "SVG", "SVG", ["svg"], ["public.svg-image"], .image, alpha: true),
        f("raw", "RAW", "Camera RAW", rawExtensions, ["public.camera-raw-image"], .image),

        // PDF
        f("pdf", "PDF", "PDF", ["pdf"], ["com.adobe.pdf"], .pdf, multipage: true),

        // Video
        f("mp4", "MP4", "MPEG-4 Video", ["mp4"], ["public.mpeg-4"], .video),
        f("mov", "MOV", "QuickTime Movie", ["mov", "qt"], ["com.apple.quicktime-movie"], .video),
        f("m4v", "M4V", "M4V Video", ["m4v"], ["com.apple.m4v-video"], .video),
        f("mkv", "MKV", "Matroska Video", ["mkv"], ["org.matroska.mkv"], .video),
        f("webm", "WEBM", "WebM Video", ["webm"], ["org.webmproject.webm"], .video),
        f("avi", "AVI", "AVI Video", ["avi"], ["public.avi"], .video),
        f("wmv", "WMV", "Windows Media Video", ["wmv"], ["com.microsoft.windows-media-wmv"], .video),
        f("mpeg", "MPEG", "MPEG Video", ["mpg", "mpeg", "m2v", "vob"], ["public.mpeg"], .video),
        f("3gp", "3GP", "3GPP Video", ["3gp", "3g2"], ["public.3gpp"], .video),
        f("ts", "TS", "MPEG Transport Stream", ["ts", "mts", "m2ts"], ["public.mpeg-2-transport-stream"], .video),
        f("flv", "FLV", "Flash Video", ["flv"], ["com.adobe.flash.video"], .video),
        f("ogv", "OGV", "Ogg Video", ["ogv"], ["org.xiph.ogv"], .video),

        // Audio
        f("mp3", "MP3", "MP3", ["mp3"], ["public.mp3"], .audio),
        f("m4a", "M4A", "AAC (M4A)", ["m4a", "m4b", "m4r"], ["com.apple.m4a-audio"], .audio),
        f("aac", "AAC", "AAC (ADTS)", ["aac", "adts"], ["public.aac-audio"], .audio),
        f("wav", "WAV", "WAVE", ["wav", "wave"], ["com.microsoft.waveform-audio"], .audio, lossless: true),
        f("flac", "FLAC", "FLAC", ["flac"], ["org.xiph.flac"], .audio, lossless: true),
        f("aiff", "AIFF", "AIFF", ["aiff", "aif", "aifc"], ["public.aiff-audio", "public.aifc-audio"], .audio, lossless: true),
        f("caf", "CAF", "Core Audio", ["caf"], ["com.apple.coreaudio-format"], .audio),
        f("ogg", "OGG", "Ogg Vorbis", ["ogg", "oga"], ["org.xiph.ogg-audio"], .audio),
        f("opus", "OPUS", "Opus", ["opus"], ["org.xiph.opus"], .audio),
        f("wma", "WMA", "Windows Media Audio", ["wma"], ["com.microsoft.windows-media-wma"], .audio),
        f("amr", "AMR", "AMR", ["amr", "awb"], ["org.3gpp.adaptive-multi-rate-audio"], .audio),
        f("ape", "APE", "Monkey's Audio", ["ape"], ["com.monkeysaudio.ape-audio"], .audio, lossless: true),
        f("mka", "MKA", "Matroska Audio", ["mka"], ["org.matroska.mka"], .audio),
        f("ac3", "AC3", "Dolby Digital", ["ac3", "eac3", "ec3"], ["public.ac3-audio"], .audio),

        // Documents
        f("txt", "TXT", "Plain Text", ["txt", "text"], ["public.plain-text"], .document),
        f("md", "MD", "Markdown", ["md", "markdown", "mdown", "mkd"], ["net.daringfireball.markdown"], .document),
        f("html", "HTML", "HTML", ["html", "htm", "xhtml"], ["public.html"], .document),
        f("rtf", "RTF", "Rich Text", ["rtf"], ["public.rtf"], .document),
        f("rtfd", "RTFD", "Rich Text with Attachments", ["rtfd"], ["com.apple.rtfd", "com.apple.flat-rtfd"], .document),
        f("docx", "DOCX", "Word Document", ["docx", "docm"], ["org.openxmlformats.wordprocessingml.document"], .document),
        f("doc", "DOC", "Word 97 Document", ["doc"], ["com.microsoft.word.doc"], .document),
        f("odt", "ODT", "OpenDocument Text", ["odt"], ["org.oasis-open.opendocument.text"], .document),
        f("webarchive", "WEBARCHIVE", "Web Archive", ["webarchive"], ["com.apple.webarchive"], .document),
        f("pages", "PAGES", "Pages", ["pages"], ["com.apple.iwork.pages.sffpages", "com.apple.iwork.pages.pages"], .document),
        f("epub", "EPUB", "EPUB", ["epub"], ["org.idpf.epub-container"], .ebook),

        // Spreadsheets
        f("csv", "CSV", "Comma-Separated Values", ["csv"], ["public.comma-separated-values-text"], .spreadsheet),
        f("tsv", "TSV", "Tab-Separated Values", ["tsv", "tab"], ["public.tab-separated-values-text"], .spreadsheet),
        f("xlsx", "XLSX", "Excel Workbook", ["xlsx", "xlsm"], ["org.openxmlformats.spreadsheetml.sheet"], .spreadsheet),
        f("xls", "XLS", "Excel 97 Workbook", ["xls"], ["com.microsoft.excel.xls"], .spreadsheet),
        f("ods", "ODS", "OpenDocument Spreadsheet", ["ods"], ["org.oasis-open.opendocument.spreadsheet"], .spreadsheet),
        f("numbers", "NUMBERS", "Numbers", ["numbers"], ["com.apple.iwork.numbers.sffnumbers", "com.apple.iwork.numbers.numbers"], .spreadsheet),

        // Presentations
        f("pptx", "PPTX", "PowerPoint", ["pptx"], ["org.openxmlformats.presentationml.presentation"], .presentation),
        f("ppt", "PPT", "PowerPoint 97", ["ppt"], ["com.microsoft.powerpoint.ppt"], .presentation),
        f("key", "KEY", "Keynote", ["key"], ["com.apple.iwork.keynote.sffkey", "com.apple.iwork.keynote.key"], .presentation),
        f("odp", "ODP", "OpenDocument Presentation", ["odp"], ["org.oasis-open.opendocument.presentation"], .presentation),

        // Subtitles
        f("srt", "SRT", "SubRip", ["srt"], ["public.subrip-text"], .subtitle),
        f("vtt", "VTT", "WebVTT", ["vtt"], ["org.w3.webvtt"], .subtitle),
        f("sbv", "SBV", "YouTube SBV", ["sbv"], [], .subtitle),
        f("ass", "ASS", "Advanced SubStation", ["ass", "ssa"], [], .subtitle),
        f("lrc", "LRC", "Lyrics", ["lrc"], [], .subtitle),

        // Archives
        f("zip", "ZIP", "ZIP Archive", ["zip"], ["public.zip-archive"], .archive),
        f("7z", "7Z", "7-Zip Archive", ["7z"], ["org.7-zip.7-zip-archive"], .archive),
        f("rar", "RAR", "RAR Archive", ["rar"], ["com.rarlab.rar-archive"], .archive),
        f("tar", "TAR", "Tar Archive", ["tar"], ["public.tar-archive"], .archive),
        f("tgz", "TAR.GZ", "Gzipped Tar", ["tgz"], ["org.gnu.gnu-zip-tar-archive"], .archive),
        f("tbz2", "TAR.BZ2", "Bzip2 Tar", ["tbz2", "tbz"], [], .archive),
        f("txz", "TAR.XZ", "XZ Tar", ["txz"], [], .archive),
        f("tzst", "TAR.ZST", "Zstandard Tar", ["tzst"], [], .archive),
        f("gz", "GZ", "Gzip", ["gz"], ["org.gnu.gnu-zip-archive"], .archive),
        f("bz2", "BZ2", "Bzip2", ["bz2"], ["public.bzip2-archive"], .archive),
        f("xz", "XZ", "XZ", ["xz"], ["org.tukaani.xz-archive"], .archive),
        f("cpio", "CPIO", "CPIO Archive", ["cpio"], ["public.cpio-archive"], .archive),
        f("cab", "CAB", "Cabinet Archive", ["cab"], ["com.microsoft.cab"], .archive),
        f("iso", "ISO", "Disk Image (ISO)", ["iso"], ["public.iso-image"], .archive),

        // Structured data
        f("json", "JSON", "JSON", ["json"], ["public.json"], .structuredData),
        f("yaml", "YAML", "YAML", ["yaml", "yml"], ["public.yaml"], .structuredData),
        f("xml", "XML", "XML", ["xml"], ["public.xml"], .structuredData),
        f("plist", "PLIST", "Property List", ["plist"], ["com.apple.property-list"], .structuredData),

        // Folders
        f("folder", "FOLDER", "Folder", [""], ["public.folder"], .folder),
    ]
}
