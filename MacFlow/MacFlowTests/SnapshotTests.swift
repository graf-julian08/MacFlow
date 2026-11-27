import AppKit
import SwiftUI
import XCTest
@testable import MacFlow

/// Renders the wheel and tool panels offscreen for visual review. Runs only
/// when MACFLOW_SNAPSHOTS points to an output folder.
@MainActor
final class SnapshotTests: XCTestCase {

    var outDir: URL? {
        ProcessInfo.processInfo.environment["MACFLOW_SNAPSHOTS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    func render<V: View>(_ view: V, name: String, dark: Bool = false) throws {
        guard let outDir else { throw XCTSkip("set MACFLOW_SNAPSHOTS to render") }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let root = view
            .padding(30)
            .background(LinearGradient(colors: dark ? [.black, Color(white: 0.2)] : [Color(white: 0.92), Color(red: 0.75, green: 0.82, blue: 0.95)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, dark ? .dark : .light)
        // Let async previews load before rendering.
        let warmup = ImageRenderer(content: root)
        _ = warmup.cgImage
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        let renderer = ImageRenderer(content: root)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        let rep = NSBitmapImageRep(cgImage: image)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appendingPathComponent("\(name).png"))
    }

    /// Hosts the view in a real (off-screen positioned) window so onAppear,
    /// async loading and AppKit controls run, then renders its layer tree.
    func renderLive<V: View>(_ view: V, name: String, dark: Bool = false, wait: TimeInterval = 2.5) throws {
        guard let outDir else { throw XCTSkip("set MACFLOW_SNAPSHOTS to render") }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        let hosting = NSHostingView(rootView: view.padding(24).background(dark ? Color(white: 0.12) : Color(white: 0.9)))
        hosting.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = hosting.fittingSize
        let window = NSWindow(contentRect: NSRect(x: 20, y: 20, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = hosting.appearance
        window.contentView = hosting
        hosting.wantsLayer = true
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        hosting.layoutSubtreeIfNeeded()
        hosting.displayIfNeeded()
        let scale: CGFloat = 2
        let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: scale, y: scale)
        // Layer tree is flipped relative to Core Graphics.
        ctx.translateBy(x: 0, y: size.height); ctx.scaleBy(x: 1, y: -1)
        try XCTUnwrap(hosting.layer).render(in: ctx)
        window.orderOut(nil)
        let rep = NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage()))
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: outDir.appendingPathComponent("\(name).png"))
    }

    func sample(_ id: String) -> ClassifiedFile {
        ClassifiedFile(url: URL(fileURLWithPath: "/tmp/sample.\(FormatRegistry.shared[id].primaryExtension)"), format: FormatRegistry.shared[id], isDirectory: false, extensionMismatch: false)
    }

    func wheel(_ mode: RadialMenuMode, file: ClassifiedFile, hover: Int?) -> RadialMenuView {
        let model = RadialMenuViewModel(mode: mode, config: .default)
        model.configure(mode: mode, files: [file])
        model.isVisible = true
        if let hover, model.segments.indices.contains(hover) {
            let n = Double(model.segments.count)
            let angle = 2 * Double.pi * Double(hover) / n
            let size = RadialMenuView.layoutSize(for: model.config)
            model.updateHover(at: CGPoint(x: size.width / 2 + 90 * sin(angle), y: size.width / 2 - 90 * cos(angle)), in: CGSize(width: size.width, height: size.width))
        }
        return RadialMenuView(viewModel: model)
    }

    func testWheels() throws {
        EngineCapabilities.shared.probeExternalTools()
        try render(HStack(spacing: 30) {
            wheel(.convert, file: sample("jpg"), hover: 0)
            wheel(.tools, file: sample("jpg"), hover: 0)
            wheel(.actions, file: sample("jpg"), hover: 5)
        }, name: "wheels-light")
        try render(HStack(spacing: 30) {
            wheel(.convert, file: sample("mp4"), hover: 2)
            wheel(.tools, file: sample("pdf"), hover: 1)
            wheel(.convert, file: sample("pages"), hover: nil)
        }, name: "wheels-dark", dark: true)
    }

    func testPanels() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("snap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let photo = dir.appendingPathComponent("Holiday Photo.jpg")
        try Fixtures.writeImage(Fixtures.testImage(width: 1200, height: 800, alpha: false), to: photo, type: "public.jpeg", properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Jane", kCGImagePropertyTIFFMake: "Apple", kCGImagePropertyTIFFModel: "iPhone"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.37, kCGImagePropertyGPSLatitudeRef: "N", kCGImagePropertyGPSLongitude: 8.54, kCGImagePropertyGPSLongitudeRef: "E"],
        ])
        let file = FileClassifier.shared.classify(photo)
        for tool: FileTool in [.compress, .metadata, .crop, .rotate, .adjust, .background, .redact, .annotate] {
            let context = ToolContext(tool: tool, files: [file])
            let view: AnyView
            switch tool {
            case .compress: view = AnyView(CompressToolView(context: context))
            case .metadata: view = AnyView(MetadataToolView(context: context))
            case .crop: view = AnyView(CropToolView(context: context))
            case .rotate: view = AnyView(RotateToolView(context: context))
            case .adjust: view = AnyView(AdjustToolView(context: context))
            case .background: view = AnyView(BackgroundToolView(context: context))
            case .redact: view = AnyView(RedactToolView(context: context))
            default: view = AnyView(AnnotateToolView(context: context))
            }
            try renderLive(view, name: "panel-\(tool.rawValue)")
        }
        let errorContext = ToolContext(tool: .compress, files: [file])
        errorContext.error = "The target size cannot be reached. The smallest possible result is 48 KB."
        try renderLive(CompressToolView(context: errorContext), name: "panel-compress-error", dark: true)
    }
}
