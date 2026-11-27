import AppKit
import SwiftUI

/// Floating shelf: collects references to files (never copies or modifies
/// them), pinned to a screen edge. Items can be dragged out into any app
/// and new files dropped onto it.
@MainActor
final class FloatingShelf: ObservableObject {

    static let shared = FloatingShelf()

    @Published private(set) var items: [URL] = []
    private var panel: ShelfPanel?
    private var watcher: Timer?

    var isVisible: Bool { panel?.isVisible == true }

    func add(_ urls: [URL]) {
        var added = 0
        for url in urls where FileManager.default.fileExists(atPath: url.path) && !items.contains(url) {
            items.append(url)
            added += 1
        }
        show()
        if added > 0 {
            HUDController.shared.info("Added \(FileActions.describe(Array(urls.prefix(added)))) to the shelf",
                                      detail: "Drag items out of the shelf into any app.", symbol: "pin")
        }
    }

    func remove(_ url: URL) {
        items.removeAll { $0 == url }
        if items.isEmpty { hide() } else { layout(animated: true) }
    }

    func clear() {
        items.removeAll()
        hide()
    }

    func toggle() { isVisible ? hide() : show() }

    func show() {
        guard !items.isEmpty else {
            HUDController.shared.info("The shelf is empty", detail: "Drag a file, hold ⌃ and drop it on FLOAT.", symbol: "pin")
            return
        }
        if panel == nil { makePanel() }
        layout(animated: false)
        panel?.orderFrontRegardless()
        startWatching()
    }

    func hide() {
        panel?.orderOut(nil)
        watcher?.invalidate()
        watcher = nil
    }

    /// Drops items whose files were deleted or moved away.
    private func startWatching() {
        guard watcher == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let alive = self.items.filter { FileManager.default.fileExists(atPath: $0.path) }
                if alive.count != self.items.count {
                    self.items = alive
                    if alive.isEmpty { self.hide() } else { self.layout(animated: true) }
                }
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
    }

    private func makePanel() {
        let panel = ShelfPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: ShelfView(shelf: self))
        let drop = ShelfDropView(frame: .zero)
        drop.onDrop = { [weak self] urls in self?.add(urls) }
        hosting.autoresizingMask = [.width, .height]
        drop.addSubview(hosting)
        panel.contentView = drop
        self.panel = panel
    }

    var edge: String { AppSettings.shared.shelfEdge }

    func layout(animated: Bool) {
        guard let panel else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        let count = CGFloat(min(items.count, 8))
        let vertical = edge != "bottom"
        let length = 58 * count + 56
        let thickness: CGFloat = 92
        let frame: NSRect
        switch edge {
        case "left": frame = NSRect(x: visible.minX + 8, y: visible.midY - length / 2, width: thickness, height: length)
        case "bottom": frame = NSRect(x: visible.midX - length / 2, y: visible.minY + 8, width: length, height: thickness)
        default: frame = NSRect(x: visible.maxX - thickness - 8, y: visible.midY - length / 2, width: thickness, height: length)
        }
        _ = vertical
        panel.setFrame(frame, display: true, animate: animated)
        panel.contentView?.subviews.first?.frame = panel.contentView?.bounds ?? .zero
    }
}

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { false }
}

/// Accepts file drops onto the shelf.
final class ShelfDropView: NSView {
    var onDrop: (([URL]) -> Void)?
    override init(frame: NSRect) { super.init(frame: frame); registerForDraggedTypes([.fileURL]) }
    required init?(coder: NSCoder) { super.init(coder: coder); registerForDraggedTypes([.fileURL]) }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        // Ignore drags that started on the shelf itself.
        if sender.draggingSource is ShelfItemDragView { return [] }
        return DragDestinationView.operation(for: sender.draggingSourceOperationMask)
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if sender.draggingSource is ShelfItemDragView { return false }
        let urls = DragSessionTracker.fileURLs(on: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

private struct ShelfView: View {
    @ObservedObject var shelf: FloatingShelf

    var body: some View {
        let vertical = shelf.edge != "bottom"
        let layout = vertical ? AnyLayout(VStackLayout(spacing: 6)) : AnyLayout(HStackLayout(spacing: 6))
        layout {
            HStack(spacing: 4) {
                Button { shelf.clear() } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Clear the shelf")
                if shelf.items.count > 8 {
                    Text("+\(shelf.items.count - 8)").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                }
            }
            .padding(.top, vertical ? 6 : 0)
            ForEach(Array(shelf.items.prefix(8)), id: \.self) { url in
                ShelfItem(url: url) { shelf.remove(url) }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
            if #available(macOS 26.0, *) {
                shape.fill(Color.clear).glassEffect(.regular, in: shape)
            } else {
                shape.fill(.regularMaterial)
            }
        }
    }
}

private struct ShelfItem: View {
    let url: URL
    let onRemove: () -> Void
    @State private var hovering = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ShelfItemDragRepresentable(url: url)
                .frame(width: 52, height: 52)
                .help(url.lastPathComponent)
            if hovering {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill").symbolRenderingMode(.palette).foregroundStyle(.white, .gray)
                }
                .buttonStyle(.plain)
                .offset(x: 4, y: -4)
            }
        }
        .onHover { hovering = $0 }
    }
}

/// AppKit view so the drag carries a real file URL (and a file promise is
/// never needed): any app receives the original file.
private struct ShelfItemDragRepresentable: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> ShelfItemDragView { ShelfItemDragView(url: url) }
    func updateNSView(_ nsView: ShelfItemDragView, context: Context) { nsView.url = url }
}

final class ShelfItemDragView: NSView, NSDraggingSource {
    var url: URL { didSet { needsDisplay = true } }

    init(url: URL) {
        self.url = url
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.draw(in: bounds.insetBy(dx: 4, dy: 4))
    }

    override func mouseDown(with event: NSEvent) {}

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        item.setDraggingFrame(bounds, contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 { NSWorkspace.shared.open(url) }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        // Copy and link only: the destination decides; MacFlow never deletes the original.
        context == .outsideApplication ? [.copy, .link, .generic] : [.copy, .generic]
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {}
}
