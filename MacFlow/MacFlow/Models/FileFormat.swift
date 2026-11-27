import Foundation
import UniformTypeIdentifiers

/// A file format MacFlow can recognise. Whether it can actually be read or
/// written on *this* Mac is decided at runtime by `EngineCapabilities`; a
/// format definition alone never makes a conversion available.
struct FileFormat: Identifiable, Hashable, Sendable {
    let id: String
    /// Name used in the wheel and in messages ("PNG", "WEBP", "MP4").
    let label: String
    let displayName: String
    let extensions: [String]
    let utTypeIdentifiers: [String]
    let category: FileCategory
    var supportsTransparency = false
    var supportsAnimation = false
    var supportsMultipage = false
    var isLossless = false

    var primaryExtension: String { extensions[0] }

    /// Extension used for newly written files ("tar.gz" rather than "tgz").
    var outputExtension: String {
        switch id {
        case "tgz": return "tar.gz"
        case "tbz2": return "tar.bz2"
        case "txz": return "tar.xz"
        case "tzst": return "tar.zst"
        default: return primaryExtension
        }
    }

    var utType: UTType? {
        utTypeIdentifiers.lazy.compactMap { UTType($0) }.first
            ?? UTType(filenameExtension: primaryExtension)
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: FileFormat, rhs: FileFormat) -> Bool { lhs.id == rhs.id }
}

/// Broad families of files. They drive which wheel content is offered.
enum FileCategory: String, CaseIterable, Sendable, Hashable {
    case image
    case video
    case audio
    case pdf
    case document
    case spreadsheet
    case presentation
    case subtitle
    case archive
    case structuredData
    case ebook
    case folder

    var displayName: String {
        switch self {
        case .image: return "Images"
        case .video: return "Video"
        case .audio: return "Audio"
        case .pdf: return "PDF"
        case .document: return "Documents"
        case .spreadsheet: return "Spreadsheets"
        case .presentation: return "Presentations"
        case .subtitle: return "Subtitles"
        case .archive: return "Archives"
        case .structuredData: return "Structured Data"
        case .ebook: return "E-Books"
        case .folder: return "Folders"
        }
    }

    var sfSymbol: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext"
        case .document: return "doc.text"
        case .spreadsheet: return "tablecells"
        case .presentation: return "rectangle.on.rectangle.angled"
        case .subtitle: return "captions.bubble"
        case .archive: return "archivebox"
        case .structuredData: return "curlybraces"
        case .ebook: return "book"
        case .folder: return "folder"
        }
    }
}

/// Verification level of a conversion path (see master spec §6).
enum VerificationStatus: String, Sendable, Hashable, Comparable {
    case verified = "VERIFIED"
    case limited = "LIMITED"
    case bestEffort = "BEST EFFORT"
    case unavailable = "UNAVAILABLE"

    private var rank: Int {
        switch self {
        case .unavailable: return 0
        case .bestEffort: return 1
        case .limited: return 2
        case .verified: return 3
        }
    }

    static func < (lhs: VerificationStatus, rhs: VerificationStatus) -> Bool { lhs.rank < rhs.rank }
}
