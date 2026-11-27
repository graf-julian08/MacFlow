import AppKit
import SwiftUI

/// Borderless, non-activating panel that shows the wheel at the pointer and
/// is the drop target during a drag. It never takes focus from Finder.
@MainActor
final class RadialPanelController {

    /// Called when a segment was chosen. `files` are the URLs AppKit
    /// delivered with the drop; `location` is the wheel centre on screen.
    var onCommit: ((RadialSegment, [ClassifiedFile], NSPoint) -> Void)?

    private var panel: RadialPanel?
    private var viewModel: RadialMenuViewModel?
    private var dropView: DragDestinationView?
    private(set) var currentMode: RadialMenuMode?
    private var files: [ClassifiedFile] = []
    private var dropHandled = false
    private var pendingDismiss: DispatchWorkItem?

    var isVisible: Bool { panel != nil }
    var didHandleDrop: Bool { dropHandled }

    // MARK: - Show

    func show(mode: RadialMenuMode, files: [ClassifiedFile], at location: NSPoint) {
        pendingDismiss?.cancel()
        pendingDismiss = nil
        if let panel, let viewModel {
            // Switch mode in place; the wheel stays where it opened.
            guard mode != currentMode else { return }
            currentMode = mode
            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) {
                viewModel.configure(mode: mode, files: files)
            }
            panel.orderFrontRegardless()
            return
        }

        self.files = files
        currentMode = mode
        dropHandled = false

        let model = RadialMenuViewModel(mode: mode)
        model.configure(mode: mode, files: files)
        viewModel = model

        let size = RadialMenuView.layoutSize(for: model.config)
        let wheelCenterOffset = CGPoint(x: size.width / 2, y: size.height - size.width / 2)
        let frame = Self.frame(size: size, centeredAt: location, wheelCenterOffset: wheelCenterOffset)

        let panel = RadialPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        // Explicitly false: transparent pixels then still receive events and
        // drags, so a drop inside the wheel can never fall through to Finder.
        panel.ignoresMouseEvents = false
        panel.appearance = Self.appearance

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        let hosting = NSHostingView(rootView: RadialMenuView(viewModel: model))
        hosting.frame = root.bounds
        hosting.autoresizingMask = [.width, .height]
        root.addSubview(hosting)

        let drop = DragDestinationView(frame: root.bounds)
        drop.autoresizingMask = [.width, .height]
        let wheelSize = CGSize(width: size.width, height: size.width)
        drop.onHover = { [weak model] point in
            // The wheel occupies the top square of the panel (flipped view).
            model?.updateHover(at: point, in: wheelSize)
        }
        drop.onExit = { [weak model] in model?.clearHover() }
        drop.canAcceptDrop = { [weak model] in model?.committableSegment != nil }
        drop.onDrop = { [weak self] urls in self?.handleDrop(urls) ?? false }
        root.addSubview(drop)
        dropView = drop

        panel.contentView = root
        panel.orderFrontRegardless()
        self.panel = panel
    }

    private static var appearance: NSAppearance? {
        switch AppSettings.shared.appearance {
        case "light": return NSAppearance(named: .aqua)
        case "dark": return NSAppearance(named: .darkAqua)
        default: return nil
        }
    }

    /// Keeps the whole wheel on the screen that contains the pointer.
    static func frame(size: CGSize, centeredAt point: NSPoint, wheelCenterOffset: CGPoint) -> NSRect {
        var origin = NSPoint(x: point.x - wheelCenterOffset.x, y: point.y - wheelCenterOffset.y)
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            origin.y = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        }
        return NSRect(origin: origin, size: size).integral
    }

    // MARK: - Drop

    private func handleDrop(_ urls: [URL]) -> Bool {
        guard !dropHandled, let model = viewModel, let segment = model.committableSegment, let panel else { return false }
        dropHandled = true
        // The pasteboard of the actual drop is authoritative.
        let dropped = urls.map { FileClassifier.shared.classify($0) }
        let usable = dropped.map(\.url) == files.map(\.url) ? files : dropped
        let center = NSPoint(x: panel.frame.midX, y: panel.frame.maxY - panel.frame.width / 2)
        if AppSettings.shared.playSounds { NSSound(named: "Pop")?.play() }
        dismiss(animated: true)
        // Run after AppKit has finished the drag protocol.
        DispatchQueue.main.async { [onCommit] in
            onCommit?(segment, usable, center)
        }
        return true
    }

    // MARK: - Keyboard (optional, needs Accessibility)

    func moveSelection(by delta: Int) { viewModel?.moveSelection(by: delta) }

    // MARK: - Dismiss

    /// Called when the drag ends. Gives AppKit a moment to deliver the drop.
    func dragEnded() {
        guard panel != nil else { return }
        pendingDismiss?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.dismiss(animated: true) }
        }
        pendingDismiss = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func dismiss(animated: Bool) {
        pendingDismiss?.cancel()
        pendingDismiss = nil
        guard let panel else { return }
        self.panel = nil
        let model = viewModel
        viewModel = nil
        dropView?.unregisterDraggedTypes()
        dropView = nil
        currentMode = nil
        files = []
        guard animated, AppSettings.shared.animationsEnabled else {
            panel.orderOut(nil)
            return
        }
        withAnimation(.easeIn(duration: 0.14)) { model?.isVisible = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            panel.orderOut(nil)
            _ = model
        }
    }
}

/// Panel that can never become key or main: Finder keeps focus and its
/// drag session is never interrupted.
final class RadialPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
