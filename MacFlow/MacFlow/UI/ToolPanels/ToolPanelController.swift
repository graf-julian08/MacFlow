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

    private(set) var panel: ToolPanel?
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
                if self.context === context {
                    // When the result is revealed, Finder keeps the focus.
                    if ok { self.close(restoreFocus: !AppSettings.shared.openResultInFinder) }
                } else if !ok, let message = context.error {
                    // The panel was replaced while this job ran: report here.
                    HUDController.shared.fail(nil, title: "\(context.tool.title) failed", detail: message)
                }
            }
        }
        context.cancelHandler = { [weak self, weak context] in
            guard let self else { return }
            if context?.busy == true { self.runningTask?.cancel() } else { self.close(restoreFocus: true) }
        }
        self.context = context
        show(view: AnyView(ToolPanelRoot(context: context)), at: location, resizable: true)
    }

    /// A small confirmation card in the same style (used for best-effort conversions).
    func confirm(title: String, message: String, confirmTitle: String, at location: NSPoint, completion: @escaping (Bool) -> Void) {
        close(restoreFocus: false)
        let view = ConfirmView(title: title, message: message, confirmTitle: confirmTitle) { [weak self] ok in
            self?.close(restoreFocus: !ok)
            completion(ok)
        }
        show(view: AnyView(view), at: location, resizable: false)
    }

    private func show(view: AnyView, at location: NSPoint, resizable: Bool) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = front }

        // The hosting controller drives the window size, so the panel grows
        // and shrinks with its content (errors, options, previews).
        let controller = NSHostingController(rootView: view.environment(\.toolPanelAppearance, true))
        // Tool panels can grow (zoom, resize) but never shrink below their
        // content; the confirmation card always fits its content exactly.
        controller.sizingOptions = resizable ? [.minSize] : [.preferredContentSize]
        let size = controller.view.fittingSize
        let panel = ToolPanel(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: resizable ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
                                                   : [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        // The glass background covers the system buttons; the title bar
        // draws its own, centred with the title (same actions and shortcuts).
        for type: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(type)?.isHidden = true
        }
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
        VStack(alignment: .leading, spacing: 0) {
            PanelTitleBar(symbol: context.tool.sfSymbol, tint: AppSettings.shared.accentColor, title: context.tool.title, subtitle: context.subtitle)
            VStack(alignment: .leading, spacing: 16) {
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
            .padding(.top, 10)
            .padding(.bottom, 18)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        // The given width is the minimum; zoom/resize lets previews grow.
        .frame(minWidth: width, maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background { ToolPanelBackground() }
        .animation(.easeOut(duration: 0.18), value: context.error)
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
            Button(context.busy ? "Stop" : (showsPrimary ? "Cancel" : "Done")) { context.cancel() }
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
        VStack(alignment: .leading, spacing: 0) {
            PanelTitleBar(symbol: "exclamationmark", tint: Color(nsColor: .systemOrange), title: title, subtitle: nil)
            VStack(alignment: .leading, spacing: 14) {
                Text(message).font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("Cancel") { completion(false) }.keyboardShortcut(.cancelAction).controlSize(.large)
                    Button(confirmTitle) { completion(true) }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).controlSize(.large)
                        .tint(AppSettings.shared.accentColor)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 20)
        }
        .frame(width: 420)
        .background { ToolPanelBackground() }
    }
}

// MARK: - Title bar

/// Slim top bar of every panel: window buttons, icon, title and file name,
/// all vertically centred. The free area moves the window; double-click
/// follows the system "double-click a window's title bar" preference.
struct PanelTitleBar: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String?
    @State private var window: NSWindow?

    var body: some View {
        ZStack(alignment: .leading) {
            WindowDragArea()
            HStack(spacing: 0) {
                WindowButtons(window: window)
                    .padding(.trailing, 16)
                ZStack {
                    Circle().fill(tint)
                    Image(systemName: symbol)
                        .font(.system(size: 9.5, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 20, height: 20)
                .padding(.trailing, 8)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .layoutPriority(1)
                    .allowsHitTesting(false)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, 7)
                        .allowsHitTesting(false)
                }
                Spacer(minLength: 12)
            }
            .padding(.leading, 20)
        }
        .frame(height: 44)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WindowReader(window: $window))
        .accessibilityElement(children: .contain)
    }
}

/// Close / minimise / zoom in the macOS style: coloured when the window is
/// key, grey otherwise, glyphs on hover.
private struct WindowButtons: View {
    let window: NSWindow?
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false

    private var canMinimize: Bool { window?.styleMask.contains(.miniaturizable) ?? false }
    private var canZoom: Bool { window?.styleMask.contains(.resizable) ?? false }

    var body: some View {
        HStack(spacing: 8) {
            button(color: Color(red: 1.0, green: 0.37, blue: 0.34), glyph: "xmark", enabled: true, help: "Close") {
                window?.performClose(nil)
            }
            button(color: Color(red: 1.0, green: 0.74, blue: 0.18), glyph: "minus", enabled: canMinimize, help: "Minimise") {
                window?.performMiniaturize(nil)
            }
            button(color: Color(red: 0.16, green: 0.78, blue: 0.25), glyph: "plus", enabled: canZoom, help: "Zoom") {
                window?.performZoom(nil)
            }
        }
        .onHover { hovering = $0 }
    }

    private func button(color: Color, glyph: String, enabled: Bool, help: String, action: @escaping () -> Void) -> some View {
        let active = activeState == .key || activeState == .active || hovering
        let grey = scheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.16)
        return Button(action: action) {
            ZStack {
                Circle().fill(enabled && active ? color : grey)
                Circle().strokeBorder(Color.black.opacity(enabled && active ? 0.12 : 0.06), lineWidth: 0.5)
                if hovering && enabled {
                    Image(systemName: glyph)
                        .font(.system(size: 7.5, weight: .heavy))
                        .foregroundStyle(Color.black.opacity(0.55))
                }
            }
            .frame(width: 13, height: 13)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// Gives SwiftUI access to the hosting window.
private struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if window !== nsView.window { DispatchQueue.main.async { window = nsView.window } }
    }
}

/// Moves the window when the bar is dragged.
struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}

final class WindowDragView: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        if event.clickCount == 2 {
            let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String ?? "Maximize"
            switch action {
            case "Minimize": if window.styleMask.contains(.miniaturizable) { window.performMiniaturize(nil) }
            case "None": break
            default: if window.styleMask.contains(.resizable) { window.performZoom(nil) }
            }
            return
        }
        window.performDrag(with: event)
    }
}
