import Foundation
import ImageIO

/// An optional helper executable found at an absolute path.
struct ExternalTool: Sendable, Hashable {
    let name: String
    let path: String
    let version: String
    let bundled: Bool
}

/// Live inventory of what this Mac can actually decode and encode.
/// Nothing in MacFlow is offered unless it is backed by an entry here.
final class EngineCapabilities: @unchecked Sendable {

    static let shared = EngineCapabilities()

    let imageDecodeTypes: Set<String>
    let imageEncodeTypes: Set<String>
    let bsdtarPath: String?
    let dittoPath: String?

    private let lock = NSLock()
    private var _ffmpeg: ExternalTool?
    private var _ffmpegEncoders: Set<String> = []
    private var _cwebp: ExternalTool?
    private var _oggenc: ExternalTool?
    private var _probed = false

    private init() {
        imageDecodeTypes = Set((CGImageSourceCopyTypeIdentifiers() as? [String]) ?? [])
        imageEncodeTypes = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        bsdtarPath = FileManager.default.isExecutableFile(atPath: "/usr/bin/bsdtar") ? "/usr/bin/bsdtar" : nil
        dittoPath = FileManager.default.isExecutableFile(atPath: "/usr/bin/ditto") ? "/usr/bin/ditto" : nil
    }

    /// Probes optional helpers. Called once in the background at launch;
    /// until it finishes, helper-backed formats are simply not offered.
    func probeExternalTools() {
        let settings = AppSettings.shared
        var ffmpeg: ExternalTool?
        var encoders: Set<String> = []
        if settings.useExternalEngines, let path = Self.discover("ffmpeg") {
            if let result = ProcessRunner.runSync(path.path, ["-hide_banner", "-version"]), result.status == 0 {
                let first = result.stdoutString.split(whereSeparator: \.isNewline).first.map(String.init) ?? "ffmpeg"
                ffmpeg = ExternalTool(name: "FFmpeg", path: path.path, version: first, bundled: path.bundled)
                if let list = ProcessRunner.runSync(path.path, ["-hide_banner", "-encoders"]), list.status == 0 {
                    encoders = Self.parseEncoders(list.stdoutString)
                }
            }
        }
        var cwebp: ExternalTool?
        if settings.useExternalEngines, let path = Self.discover("cwebp"),
           let result = ProcessRunner.runSync(path.path, ["-version"]), result.status == 0 {
            cwebp = ExternalTool(
                name: "cwebp",
                path: path.path,
                version: result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines),
                bundled: path.bundled
            )
        }
        var oggenc: ExternalTool?
        if settings.useExternalEngines, let path = Self.discover("oggenc"),
           let result = ProcessRunner.runSync(path.path, ["--version"]), result.status == 0 {
            oggenc = ExternalTool(name: "oggenc", path: path.path,
                                  version: result.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines), bundled: path.bundled)
        }
        lock.lock()
        _oggenc = oggenc
        _ffmpeg = ffmpeg
        _ffmpegEncoders = encoders
        _cwebp = cwebp
        _probed = true
        lock.unlock()
    }

    var ffmpeg: ExternalTool? { lock.lock(); defer { lock.unlock() }; return _ffmpeg }
    var cwebp: ExternalTool? { lock.lock(); defer { lock.unlock() }; return _cwebp }
    var oggenc: ExternalTool? { lock.lock(); defer { lock.unlock() }; return _oggenc }

    /// Ogg Vorbis output: oggenc, or an FFmpeg with libvorbis.
    var canEncodeOggVorbis: Bool { oggenc != nil || ffmpegHasEncoder("libvorbis") }
    var hasProbedExternalTools: Bool { lock.lock(); defer { lock.unlock() }; return _probed }

    func ffmpegHasEncoder(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _ffmpeg != nil && _ffmpegEncoders.contains(name)
    }

    // MARK: - Image

    func canDecodeImage(_ format: FileFormat) -> Bool {
        if format.id == "svg" { return true } // NSImage renders SVG natively (macOS 14+)
        if format.id == "raw" { return imageDecodeTypes.contains("public.camera-raw-image") || imageDecodeTypes.contains("com.adobe.raw-image") }
        return format.utTypeIdentifiers.contains(where: imageDecodeTypes.contains)
    }

    func canEncodeImage(_ format: FileFormat) -> Bool {
        switch format.id {
        case "pdf": return true
        case "webp": return webpEncoder != nil
        default: return format.utTypeIdentifiers.contains(where: imageEncodeTypes.contains)
        }
    }

    enum WebPEncoder { case cwebp(String), ffmpeg(String) }

    var webpEncoder: WebPEncoder? {
        if let cwebp { return .cwebp(cwebp.path) }
        if let ffmpeg, ffmpegHasEncoder("libwebp") { return .ffmpeg(ffmpeg.path) }
        return nil
    }

    // MARK: - Discovery

    /// Bundled helpers first (signed copies inside the app), then well-known
    /// package-manager locations. PATH is deliberately not consulted.
    private static func discover(_ name: String) -> (path: String, bundled: Bool)? {
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: name)?.path,
           FileManager.default.isExecutableFile(atPath: bundled) {
            return (bundled, true)
        }
        if let helpers = Bundle.main.url(forResource: name, withExtension: nil, subdirectory: "Helpers")?.path,
           FileManager.default.isExecutableFile(atPath: helpers) {
            return (helpers, true)
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin"] {
            let path = "\(dir)/\(name)"
            if FileManager.default.isExecutableFile(atPath: path) { return (path, false) }
        }
        return nil
    }

    static func parseEncoders(_ text: String) -> Set<String> {
        var names: Set<String> = []
        var started = false
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("------") { started = true; continue }
            guard started else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 2 else { continue }
            let flags = parts[0]
            // Skip experimental encoders ("X" flag): their output is not
            // reliable enough to be offered.
            if flags.contains("X") { continue }
            names.insert(String(parts[1]))
        }
        return names
    }
}
