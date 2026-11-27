import AppKit
import SwiftUI

/// One status card.
struct HUDItem: Identifiable, Equatable {
    enum Kind: Equatable { case progress, success, failure, info }
    let id: UUID
    var kind: Kind
    var title: String
    var detail: String?
    var progress: Double?
    var outputs: [URL] = []
    var symbol: String

    static func == (a: HUDItem, b: HUDItem) -> Bool {
        a.id == b.id && a.kind == b.kind && a.title == b.title && a.detail == b.detail && a.progress == b.progress && a.outputs == b.outputs
    }
}

@MainActor
final class HUDModel: ObservableObject {
    @Published var items: [HUDItem] = []
    var cancelHandlers: [UUID: () -> Void] = [:]
}

/// Non-activating status overlay at the top of the active screen.
@MainActor
final class HUDController {

    static let shared = HUDController()

    private let model = HUDModel()
    private var panel: NSPanel?
    private var hideTimers: [UUID: Timer] = [:]
    private let width: CGFloat = 400

    // MARK: - API

    @discardableResult
    func begin(_ title: String, symbol: String, cancel: (() -> Void)? = nil) -> UUID {
        let id = UUID()
        let item = HUDItem(id: id, kind: .progress, title: title, detail: nil, progress: nil, symbol: symbol)
        model.cancelHandlers[id] = cancel
        // Short jobs finish before the card would be noticed; show it after
        // a brief delay to avoid flicker.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.model.cancelHandlers.keys.contains(id) || self.pending.contains(id) else { return }
                if self.finished.contains(id) { return }
                self.insert(item)
            }
        }
        pending.insert(id)
        return id
    }

    private var pending = Set<UUID>()
    private var finished = Set<UUID>()

    func update(_ id: UUID, progress: Double?, detail: String? = nil) {
        guard let index = model.items.firstIndex(where: { $0.id == id }) else { return }
        if let progress { model.items[index].progress = max(0, min(1, progress)) }
        if let detail { model.items[index].detail = detail }
    }

    func succeed(_ id: UUID?, title: String, detail: String?, outputs: [URL]) {
        finish(id, item: HUDItem(id: id ?? UUID(), kind: .success, title: title, detail: detail, progress: nil, outputs: outputs, symbol: "checkmark"), hideAfter: 4.5)
        if AppSettings.shared.openResultInFinder, !outputs.isEmpty {
            Self.reveal(outputs)
        }
    }

    func fail(_ id: UUID?, title: String, detail: String?) {
        finish(id, item: HUDItem(id: id ?? UUID(), kind: .failure, title: title, detail: detail, progress: nil, symbol: "exclamationmark"), hideAfter: 10)
        if AppSettings.shared.playSounds { NSSound(named: "Basso")?.play() }
    }

    func info(_ title: String, detail: String?, symbol: String = "info") {
        finish(nil, item: HUDItem(id: UUID(), kind: .info, title: title, detail: detail, progress: nil, symbol: symbol), hideAfter: 4)
    }

    /// Selects the new items in Finder and scrolls them into view. Items
    /// that vanished in the meantime are skipped.
    static func reveal(_ urls: [URL]) {
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting(existing)
    }

    func cancelled(_ id: UUID?) {
        guard let id else { return }
        pending.remove(id)
        finished.insert(id)
        model.cancelHandlers[id] = nil
        remove(id)
    }

    // MARK: - Internals

    private func finish(_ id: UUID?, item: HUDItem, hideAfter: TimeInterval) {
        if let id {
            pending.remove(id)
            finished.insert(id)
            model.cancelHandlers[id] = nil
        }
        if let index = model.items.firstIndex(where: { $0.id == item.id }) {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) { model.items[index] = item }
        } else {
            insert(item)
        }
        scheduleHide(item.id, after: hideAfter)
    }

    private func insert(_ item: HUDItem) {
        ensurePanel()
        withAnimation(.spring(response: 0.36, dampingFraction: 0.82)) {
            model.items.insert(item, at: 0)
            if model.items.count > 4 { model.items.removeLast(model.items.count - 4) }
        }
        layout()
    }

    private func scheduleHide(_ id: UUID, after seconds: TimeInterval) {
        hideTimers[id]?.invalidate()
        let timer = Timer(timeInterval: seconds, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.remove(id) }
        }
        RunLoop.main.add(timer, forMode: .common)
        hideTimers[id] = timer
    }

    func remove(_ id: UUID) {
        hideTimers[id]?.invalidate()
        hideTimers[id] = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.9)) {
            model.items.removeAll { $0.id == id }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) { [weak self] in
            MainActor.assumeIsolated { self?.layout() }
        }
    }

    func cancel(_ id: UUID) {
        model.cancelHandlers[id]?()
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = HUDPanel(contentRect: NSRect(x: 0, y: 0, width: width, height: 10), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        let hosting = NSHostingView(rootView: HUDView(model: model, controller: self))
        panel.contentView = hosting
        self.panel = panel
    }

    private func layout() {
        guard let panel else { return }
        if model.items.isEmpty {
            panel.orderOut(nil)
            return
        }
        let height = CGFloat(model.items.count) * 76 + 16
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = NSRect(x: visible.midX - width / 2, y: visible.maxY - height - 8, width: width, height: height)
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }
}

final class HUDPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private struct HUDView: View {
    @ObservedObject var model: HUDModel
    let controller: HUDController

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.items) { item in
                HUDCard(item: item, controller: controller)
                    .transition(.move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.96)))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct HUDCard: View {
    let item: HUDItem
    let controller: HUDController
    @State private var hovering = false

    private var tint: Color {
        switch item.kind {
        case .failure: return Color(nsColor: .systemRed)
        case .success: return AppSettings.shared.accentColor
        default: return AppSettings.shared.accentColor
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let detail = item.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
                if item.kind == .progress, let p = item.progress {
                    ProgressView(value: p)
                        .progressViewStyle(.linear)
                        .tint(tint)
                        .padding(.top, 3)
                }
            }
            Spacer(minLength: 4)
            trailing
        }
        .padding(.horizontal, 14)
        .frame(height: 68)
        .background { cardBackground }
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .onHover { hovering = $0 }
        .onTapGesture { tapped() }
        .help(item.detail ?? item.title)
    }

    @ViewBuilder private var icon: some View {
        ZStack {
            Circle().fill(tint.opacity(item.kind == .progress ? 0.14 : 1))
            if item.kind == .progress {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: item.symbol)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: 30, height: 30)
    }

    @ViewBuilder private var trailing: some View {
        switch item.kind {
        case .progress:
            Button { controller.cancel(item.id) } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Cancel")
        case .success where !item.outputs.isEmpty:
            Button("Show") { reveal() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        default:
            if hovering {
                Button { controller.remove(item.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        if #available(macOS 26.0, *) {
            shape.fill(Color.clear).glassEffect(.regular, in: shape)
        } else {
            shape.fill(.regularMaterial)
                .overlay(shape.stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 14, y: 4)
        }
    }

    private func tapped() {
        if item.kind == .success, !item.outputs.isEmpty { reveal() } else if item.kind != .progress { controller.remove(item.id) }
    }

    private func reveal() {
        HUDController.reveal(item.outputs)
        controller.remove(item.id)
    }
}
