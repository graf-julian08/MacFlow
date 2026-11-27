import AppKit
import SwiftUI

/// Shared state between a tool panel and the job it starts.
@MainActor
final class ToolContext: ObservableObject {
    let tool: FileTool
    let files: [URL]
    let classified: [ClassifiedFile]
    @Published var busy = false
    @Published var progress: Double?
    @Published var error: String?

    var submitHandler: ((ToolRequest) -> Void)?
    var cancelHandler: (() -> Void)?
    var backgroundHandler: (() -> Void)?

    init(tool: FileTool, files: [ClassifiedFile]) {
        self.tool = tool
        self.classified = files
        self.files = files.map(\.url)
    }

    var primary: URL { files[0] }
    var primaryFormat: FileFormat? { classified.first?.format }
    var subtitle: String {
        files.count == 1 ? primary.lastPathComponent : "\(files.count) files"
    }

    func submit(_ request: ToolRequest) {
        error = nil
        submitHandler?(request)
    }

    func cancel() { cancelHandler?() }
}

/// Presents tool panels: focused, glass-styled windows that appear where
/// the file was dropped and return focus to the previous app on close.
@MainActor
final class ToolPanelController: NSObject, NSWindowDelegate {

    private var panel: ToolPanel?
    private var context: ToolContext?
    private var previousApp: NSRunningApplication?
    private var runningTask: Task<Void, Never>?

    var isPresenting: Bool { panel != nil }

    func present(tool: FileTool, files: [ClassifiedFile], at location: NSPoint,
                 run: @escaping (ToolRequest, ToolContext) async -> Bool) {
        close(restoreFocus: false)
        let context = ToolContext(tool: tool, files: files)
        context.submitHandler = { [weak self, weak context] request in
            guard let self, let context, !context.busy else { return }
            context.busy = true
            context.progress = nil
            self.runningTask = Task { @MainActor in
                let ok = await run(request, context)
                context.busy = false
                if ok { self.close(restoreFocus: true) }
            }
        }
        context.cancelHandler = { [weak self, weak context] in
            guard let self else { return }
            if context?.busy == true { self.runningTask?.cancel() } else { self.close(restoreFocus: true) }
        }
        self.context = context
        show(view: AnyView(ToolPanelRoot(context: context)), at: location)
    }

    /// A small confirmation card in the same style (used for best-effort conversions).
    func confirm(title: String, message: String, confirmTitle: String, at location: NSPoint, completion: @escaping (Bool) -> Void) {
        close(restoreFocus: false)
        let view = ConfirmView(title: title, message: message, confirmTitle: confirmTitle) { [weak self] ok in
            self?.close(restoreFocus: !ok)
            completion(ok)
        }
        show(view: AnyView(view), at: location)
    }

    private func show(view: AnyView, at location: NSPoint) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }

        // The hosting controller drives the window size, so the panel grows
        // and shrinks with its content (errors, options, previews).
        let controller = NSHostingController(rootView: view.environment(\.toolPanelAppearance, true))
        controller.sizingOptions = [.preferredContentSize]
        let size = controller.view.fittingSize
        let panel = ToolPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.delegate = self
        panel.contentViewController = controller
        panel.appearance = {
            switch AppSettings.shared.appearance {
            case "light": return NSAppearance(named: .aqua)
            case "dark": return NSAppearance(named: .darkAqua)
            default: return nil
            }
        }()
        panel.setFrame(Self.frame(size: size, around: location), display: false)
        panel.onEscape = { [weak self] in
            guard let self else { return }
            if let context = self.context, context.busy { return }
            self.close(restoreFocus: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = AppSettings.shared.animationsEnabled ? 0.18 : 0
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
        self.panel = panel
    }

    static func frame(size: CGSize, around point: NSPoint) -> NSRect {
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2)
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 12), visible.maxX - size.width - 12)
            origin.y = min(max(origin.y, visible.minY + 12), visible.maxY - size.height - 12)
        }
        return NSRect(origin: origin, size: size)
    }

    func close(restoreFocus: Bool) {
        runningTask = nil
        guard let panel else { return }
        self.panel = nil
        context = nil
        panel.delegate = nil
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = AppSettings.shared.animationsEnabled ? 0.14 : 0
            panel.animator().alphaValue = 0
        }, completionHandler: {
            panel.orderOut(nil)
        })
        if restoreFocus, let previousApp, !previousApp.isTerminated {
            previousApp.activate()
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let context, context.busy { runningTask?.cancel() }
        panel = nil
        context = nil
    }
}

final class ToolPanel: NSPanel {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

private struct ToolPanelAppearanceKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var toolPanelAppearance: Bool {
        get { self[ToolPanelAppearanceKey.self] }
        set { self[ToolPanelAppearanceKey.self] = newValue }
    }
}

// MARK: - Root

/// Routes a tool to its panel view.
private struct ToolPanelRoot: View {
    @ObservedObject var context: ToolContext

    var body: some View {
        Group {
            switch context.tool {
            case .compress: CompressToolView(context: context)
            case .metadata: MetadataToolView(context: context)
            case .adjust: AdjustToolView(context: context)
            case .crop: CropToolView(context: context)
            case .rotate: RotateToolView(context: context)
            case .redact: RedactToolView(context: context)
            case .background: BackgroundToolView(context: context)
            case .resize: ResizeToolView(context: context)
            case .removeBackground: RemoveBackgroundToolView(context: context)
            case .readQR: ReadQRToolView(context: context)
            case .annotate: AnnotateToolView(context: context)
            case .makePDF: MakePDFToolView(context: context)
            case .videoCompress: VideoCompressToolView(context: context)
            case .trim: VideoTrimToolView(context: context)
            case .videoRotate: VideoRotateToolView(context: context)
            case .snapshot: SnapshotToolView(context: context)
            case .speed: SpeedToolView(context: context)
            case .audioTrim: AudioTrimToolView(context: context)
            case .volume: VolumeToolView(context: context)
            case .fade: FadeToolView(context: context)
            case .channels: ChannelsToolView(context: context)
            case .pdfCompress: PDFCompressToolView(context: context)
            case .pages: PagesToolView(context: context)
            case .pdfMetadata: PDFMetadataToolView(context: context)
            case .protect: ProtectToolView(context: context)
            case .watermark: WatermarkToolView(context: context)
            case .pageNumbers: PageNumbersToolView(context: context)
            case .ocr: OCRToolView(context: context)
            case .splitPDF: SplitToolView(context: context)
            case .mergePDF: MergeToolView(context: context)
            case .archiveContents: ArchiveContentsToolView(context: context)
            case .shiftTiming: ShiftTimingToolView(context: context)
            case .mute, .extractAudio, .extractText, .extract, .testArchive, .prettyPrint, .minify:
                EmptyView()
            }
        }
    }
}

// MARK: - Chrome

/// Common frame of every tool panel: header, content, error, footer.
struct ToolChrome<Content: View>: View {
    @ObservedObject var context: ToolContext
    var primaryTitle = "Save"
    var canSubmit = true
    var footnote: String?
    var width: CGFloat = 560
    var showsPrimary = true
    let onSubmit: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content()
                .disabled(context.busy)
            if let error = context.error {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color(nsColor: .systemRed))
                    Text(error).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .systemRed).opacity(0.1)))
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            footer
        }
        .padding(.horizontal, 22)
        .padding(.top, 18)
        .padding(.bottom, 18)
        .frame(width: width)
        .background { ToolPanelBackground() }
        .animation(.easeOut(duration: 0.18), value: context.error)
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(AppSettings.shared.accentColor)
                Image(systemName: context.tool.sfSymbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(context.tool.title).font(.system(size: 15, weight: .semibold))
                Text(context.subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.leading, 52) // clear the window's close button
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if context.busy {
                if let p = context.progress {
                    ProgressView(value: p).frame(width: 120).tint(AppSettings.shared.accentColor)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Working…").font(.system(size: 12)).foregroundStyle(.secondary)
            } else if let footnote {
                Text(footnote)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            Button(context.busy ? "Stop" : "Cancel") { context.cancel() }
                .keyboardShortcut(.cancelAction)
                .controlSize(.large)
            if showsPrimary {
                Button(primaryTitle) { onSubmit() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(AppSettings.shared.accentColor)
                    .controlSize(.large)
                    .disabled(!canSubmit || context.busy)
            }
        }
    }
}

struct ToolPanelBackground: View {
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 24, style: .continuous)
        if #available(macOS 26.0, *) {
            shape.fill(Color.clear).glassEffect(.regular, in: shape)
        } else {
            VisualEffectBackground().clipShape(shape)
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

// MARK: - Confirm

private struct ConfirmView: View {
    let title: String
    let message: String
    let confirmTitle: String
    let completion: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Color(nsColor: .systemOrange))
                    Image(systemName: "exclamationmark").font(.system(size: 14, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 34, height: 34)
                Text(title).font(.system(size: 15, weight: .semibold))
            }
            .padding(.leading, 52)
            Text(message).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { completion(false) }.keyboardShortcut(.cancelAction).controlSize(.large)
                Button(confirmTitle) { completion(true) }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
                    .tint(AppSettings.shared.accentColor)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background { ToolPanelBackground() }
    }
}
