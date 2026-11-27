import CoreGraphics
import Foundation
import ImageIO

/// WebP output. ImageIO can read WebP but not write it, so encoding uses an
/// optional helper (cwebp, or FFmpeg built with libwebp). The image is first
/// rendered by ImageEngine (orientation, colour) into a lossless PNG.
enum WebPEncoder {

    static func encode(source: URL, sourceFormat: FileFormat, destination: URL, quality: Double) async throws {
        guard let encoder = EngineCapabilities.shared.webpEncoder else {
            throw MacFlowError.unsupported("Writing WebP")
        }
        let loaded = try ImageEngine.load(source, index: 0)
        try await encode(image: loaded.image, destination: destination, quality: quality, encoder: encoder)
    }

    static func encode(image: CGImage, destination: URL, quality: Double) async throws {
        guard let encoder = EngineCapabilities.shared.webpEncoder else {
            throw MacFlowError.unsupported("Writing WebP")
        }
        try await encode(image: image, destination: destination, quality: quality, encoder: encoder)
    }

    private static func encode(image: CGImage, destination: URL, quality: Double, encoder: EngineCapabilities.WebPEncoder) async throws {
        let work = destination.deletingLastPathComponent().appendingPathComponent("webp-input-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: work) }
        try ImageEngine.write([ImageEngine.Frame(image: try ImageEngine.eightBit(image), properties: [:])],
                              to: work, format: FormatRegistry.shared["png"], quality: 1)
        let q = String(Int((quality * 100).rounded()))
        switch encoder {
        case .cwebp(let path):
            try await ProcessRunner.runChecked(path, ["-quiet", "-mt", "-q", q, "-metadata", "icc", work.path, "-o", destination.path], tool: "cwebp", timeout: 600)
        case .ffmpeg(let path):
            try await ProcessRunner.runChecked(path, ["-nostdin", "-hide_banner", "-loglevel", "error", "-i", work.path,
                                                     "-c:v", "libwebp", "-quality", q, "-y", destination.path], tool: "FFmpeg", timeout: 600)
        }
    }
}
