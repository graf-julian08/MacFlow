import AppKit
import SwiftUI

/// Loads a downsampled, orientation-correct preview off the main thread.
@MainActor
final class PreviewLoader: ObservableObject {
    @Published var image: CGImage?
    @Published var failed = false
    /// Full pixel size of the (oriented) original.
    @Published var originalSize: CGSize = .zero

    func load(_ url: URL, maxPixel: Int = 1400) {
        guard image == nil else { return }
        Task.detached(priority: .userInitiated) {
            let thumb = ImageEngine.thumbnail(url, maxPixel: maxPixel)
            let size = Self.orientedSize(url)
            await MainActor.run {
                self.image = thumb
                self.failed = thumb == nil
                self.originalSize = size ?? CGSize(width: thumb?.width ?? 0, height: thumb?.height ?? 0)
            }
        }
    }

    nonisolated static func orientedSize(_ url: URL) -> CGSize? {
        if FileClassifier.shared.format(of: url)?.id == "svg", let img = try? ImageEngine.renderSVG(url, scale: 2) {
            return CGSize(width: img.width, height: img.height)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, ImageEngine.primaryIndex(source), nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return orientation >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }
}

/// Aspect-fit placement of an image in a container.
func fitRect(image: CGSize, in container: CGSize, padding: CGFloat = 0) -> CGRect {
    guard image.width > 0, image.height > 0 else { return .zero }
    let available = CGSize(width: container.width - padding * 2, height: container.height - padding * 2)
    let scale = min(available.width / image.width, available.height / image.height)
    let size = CGSize(width: image.width * scale, height: image.height * scale)
    return CGRect(x: (container.width - size.width) / 2, y: (container.height - size.height) / 2, width: size.width, height: size.height)
}

/// Preview surface with a checkerboard behind transparent images.
struct PreviewSurface<Overlay: View>: View {
    let image: CGImage?
    var height: CGFloat = 300
    var checkerboard = true
    @ViewBuilder var overlay: (CGRect) -> Overlay

    var body: some View {
        GeometryReader { geo in
            let rect = image.map { fitRect(image: CGSize(width: $0.width, height: $0.height), in: geo.size, padding: 12) } ?? .zero
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.black.opacity(0.18))
                if let image {
                    if checkerboard {
                        Checkerboard().frame(width: rect.width, height: rect.height).offset(x: rect.minX, y: rect.minY)
                    }
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                    overlay(rect)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(minHeight: height, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

extension PreviewSurface where Overlay == EmptyView {
    init(image: CGImage?, height: CGFloat = 300, checkerboard: Bool = true) {
        self.init(image: image, height: height, checkerboard: checkerboard) { _ in EmptyView() }
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let cell: CGFloat = 8
            for row in 0..<Int(size.height / cell) + 1 {
                for col in 0..<Int(size.width / cell) + 1 where (row + col) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: CGFloat(col) * cell, y: CGFloat(row) * cell, width: cell, height: cell)), with: .color(Color.gray.opacity(0.18)))
                }
            }
        }
        .background(Color.white.opacity(0.85))
    }
}

/// Title, value and slider in one compact row.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var neutral: Double? = nil

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12))
                .frame(width: 92, alignment: .leading)
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            Text(format(value))
                .font(.system(size: 11.5).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .trailing)
                .onTapGesture(count: 2) { if let neutral { value = neutral } }
                .help(neutral == nil ? "" : "Double-click to reset")
        }
    }
}

struct FieldRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content
    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).frame(width: 110, alignment: .leading)
            content()
        }
    }
}

/// Grouped card used inside panels.
struct PanelCard<Content: View>: View {
    @ViewBuilder let content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content() }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

extension Int64 {
    var fileSize: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}

func fileSize(of url: URL) -> Int64 {
    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
}

func timeString(_ seconds: Double) -> String {
    guard seconds.isFinite else { return "0:00" }
    let total = max(0, seconds)
    let m = Int(total) / 60, s = Int(total) % 60
    let tenths = Int((total - floor(total)) * 10)
    return String(format: "%d:%02d.%d", m, s, tenths)
}
