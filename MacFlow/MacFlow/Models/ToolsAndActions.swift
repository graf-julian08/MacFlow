import AppKit
import Foundation

/// File tools offered in the Command wheel.
enum FileTool: String, CaseIterable, Sendable, Identifiable {
    // Images
    case compress, metadata, adjust, crop, rotate, redact, background
    case resize, removeBackground, readQR, annotate, makePDF
    // Video
    case videoCompress, trim, videoRotate, mute, extractAudio, snapshot, speed
    // Audio
    case audioTrim, volume, fade, channels
    // PDF
    case pdfCompress, pages, pdfMetadata, protect, watermark, pageNumbers, ocr, splitPDF, mergePDF, extractText
    // Archives
    case extract, archiveContents, testArchive
    // Data & subtitles
    case prettyPrint, minify, shiftTiming

    var id: String { rawValue }

    /// Short label shown in the wheel.
    var label: String {
        switch self {
        case .compress, .videoCompress, .pdfCompress: return "COMPRESS"
        case .metadata, .pdfMetadata: return "METADATA"
        case .adjust: return "EDIT"
        case .crop: return "CROP"
        case .rotate, .videoRotate: return "ROTATE"
        case .redact: return "REDACT"
        case .background: return "ADD BG"
        case .resize: return "RESIZE"
        case .removeBackground: return "REMOVE BG"
        case .readQR: return "READ QR"
        case .annotate: return "ANNOTATE"
        case .makePDF: return "MAKE PDF"
        case .trim, .audioTrim: return "TRIM"
        case .mute: return "MUTE"
        case .extractAudio: return "AUDIO"
        case .snapshot: return "SNAPSHOT"
        case .speed: return "SPEED"
        case .volume: return "VOLUME"
        case .fade: return "FADE"
        case .channels: return "CHANNELS"
        case .pages: return "PAGES"
        case .protect: return "PROTECT"
        case .watermark: return "WATERMARK"
        case .pageNumbers: return "NUMBERS"
        case .ocr: return "OCR"
        case .splitPDF: return "SPLIT"
        case .mergePDF: return "MERGE"
        case .extractText: return "TEXT"
        case .extract: return "EXTRACT"
        case .archiveContents: return "CONTENTS"
        case .testArchive: return "TEST"
        case .prettyPrint: return "FORMAT"
        case .minify: return "MINIFY"
        case .shiftTiming: return "SHIFT"
        }
    }

    /// Title used in tool panels and messages.
    var title: String {
        switch self {
        case .compress, .videoCompress, .pdfCompress: return "Compress"
        case .metadata, .pdfMetadata: return "Metadata"
        case .adjust: return "Edit"
        case .crop: return "Crop"
        case .rotate, .videoRotate: return "Rotate"
        case .redact: return "Redact"
        case .background: return "Add Background"
        case .resize: return "Resize"
        case .removeBackground: return "Remove Background"
        case .readQR: return "Read QR Code"
        case .annotate: return "Annotate"
        case .makePDF: return "Make PDF"
        case .trim, .audioTrim: return "Trim"
        case .mute: return "Mute"
        case .extractAudio: return "Extract Audio"
        case .snapshot: return "Snapshot"
        case .speed: return "Change Speed"
        case .volume: return "Volume"
        case .fade: return "Fade"
        case .channels: return "Channels"
        case .pages: return "Organize Pages"
        case .protect: return "Protect"
        case .watermark: return "Watermark"
        case .pageNumbers: return "Page Numbers"
        case .ocr: return "Recognise Text (OCR)"
        case .splitPDF: return "Split PDF"
        case .mergePDF: return "Merge PDFs"
        case .extractText: return "Extract Text"
        case .extract: return "Extract"
        case .archiveContents: return "Archive Contents"
        case .testArchive: return "Test Archive"
        case .prettyPrint: return "Format JSON"
        case .minify: return "Minify JSON"
        case .shiftTiming: return "Shift Timing"
        }
    }

    var sfSymbol: String {
        switch self {
        case .compress, .videoCompress, .pdfCompress: return "arrow.down.right.and.arrow.up.left"
        case .metadata, .pdfMetadata: return "tag"
        case .adjust: return "slider.horizontal.3"
        case .crop: return "crop"
        case .rotate, .videoRotate: return "rotate.right"
        case .redact: return "eye.slash"
        case .background: return "photo.badge.plus"
        case .resize: return "arrow.up.left.and.down.right.magnifyingglass"
        case .removeBackground: return "person.crop.rectangle"
        case .readQR: return "qrcode.viewfinder"
        case .annotate: return "pencil.tip.crop.circle"
        case .makePDF: return "doc.richtext"
        case .trim, .audioTrim: return "timeline.selection"
        case .mute: return "speaker.slash"
        case .extractAudio: return "waveform"
        case .snapshot: return "camera"
        case .speed: return "gauge.with.dots.needle.67percent"
        case .volume: return "speaker.wave.3"
        case .fade: return "waveform.path"
        case .channels: return "hifispeaker.2"
        case .pages: return "rectangle.grid.2x2"
        case .protect: return "lock"
        case .watermark: return "drop"
        case .pageNumbers: return "number"
        case .ocr: return "text.viewfinder"
        case .splitPDF: return "square.split.2x1"
        case .mergePDF: return "square.stack"
        case .extractText: return "doc.plaintext"
        case .extract: return "arrow.up.bin"
        case .archiveContents: return "list.bullet.rectangle"
        case .testArchive: return "checkmark.seal"
        case .prettyPrint: return "text.alignleft"
        case .minify: return "text.badge.minus"
        case .shiftTiming: return "clock.arrow.2.circlepath"
        }
    }

    /// Tools that run immediately because they have no settings.
    var runsImmediately: Bool {
        switch self {
        case .mute, .extractAudio, .extractText, .extract, .testArchive, .prettyPrint, .minify: return true
        default: return false
        }
    }

    /// Whether the tool combines all dropped files into one result.
    var combinesFiles: Bool { self == .makePDF || self == .mergePDF }
}

/// File actions offered in the Control wheel.
enum FileAction: String, CaseIterable, Sendable, Identifiable {
    case airdrop
    case float
    case copy
    case move
    case copyPath
    case terminal

    var id: String { rawValue }

    var label: String {
        switch self {
        case .airdrop: return "AIRDROP"
        case .float: return "FLOAT"
        case .copy: return "COPY"
        case .move: return "MOVE"
        case .copyPath: return "COPY PATH"
        case .terminal: return "TERMINAL"
        }
    }

    var title: String {
        switch self {
        case .airdrop: return "AirDrop"
        case .float: return "Float"
        case .copy: return "Copy"
        case .move: return "Move"
        case .copyPath: return "Copy Path"
        case .terminal: return "Terminal"
        }
    }

    var sfSymbol: String {
        switch self {
        case .airdrop: return "antenna.radiowaves.left.and.right"
        case .float: return "pin"
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.clipboard"
        case .copyPath: return "doc.text"
        case .terminal: return "apple.terminal"
        }
    }

    var subtitle: String {
        switch self {
        case .airdrop: return "Share with AirDrop"
        case .float: return "Keep in a floating shelf"
        case .copy: return "Copy to the clipboard"
        case .move: return "Move to a folder"
        case .copyPath: return "Copy the full path"
        case .terminal: return "Open in Terminal"
        }
    }
}

/// The three wheel modes, each bound to a modifier.
enum RadialMenuMode: String, CaseIterable, Sendable {
    case convert
    case tools
    case actions

    var displayName: String {
        switch self {
        case .convert: return "Convert"
        case .tools: return "File Tools"
        case .actions: return "File Actions"
        }
    }
}
