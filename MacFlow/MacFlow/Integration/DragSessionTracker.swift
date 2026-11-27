import AppKit

/// Detects real file drags from Finder, the Desktop or any app that puts
/// file URLs on the system drag pasteboard — without special permissions.
///
/// How it works:
/// * While the mouse button is up, a low-frequency timer (5 Hz, with
///   tolerance) only records the drag pasteboard's change count.
/// * When the button goes down (global mouse monitor, or the timer as a
///   fallback) tracking switches to 60 Hz until the button is released.
/// * A drag session exists when the drag pasteboard changed during the
///   press and holds file URLs of existing items.
/// * Modifier keys are read from `NSEvent.modifierFlags`, which reflects
///   the hardware state at any time.
@MainActor
final class DragSessionTracker {

    var onBegan: (([URL], NSEvent.ModifierFlags) -> Void)?
    var onModifiersChanged: ((NSEvent.ModifierFlags) -> Void)?
    var onEnded: (() -> Void)?

    private(set) var isDragging = false
    private(set) var files: [URL] = []

    private var idleTimer: Timer?
    private var activeTimer: Timer?
    private var mouseMonitor: Any?
    private var baselineChangeCount = 0
    private var lastFlags: NSEvent.ModifierFlags = []
    private var ignoreUntilRelease = false

    private let dragPasteboard = NSPasteboard(name: .drag)

    func start() {
        baselineChangeCount = dragPasteboard.changeCount
        let idle = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.idleTick() }
        }
        idle.tolerance = 0.1
        RunLoop.main.add(idle, forMode: .common)
        idleTimer = idle
        // Mouse monitors need no permission; they only speed up the start.
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseDragged]) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginActiveTracking() }
        }
    }

    func stop() {
        idleTimer?.invalidate(); idleTimer = nil
        activeTimer?.invalidate(); activeTimer = nil
        if let mouseMonitor { NSEvent.removeMonitor(mouseMonitor) }
        mouseMonitor = nil
        endSession()
    }

    /// Our own windows also report mouse-downs through local monitors.
    func noteLocalMouseDown() { beginActiveTracking() }

    private var buttonPressed: Bool { NSEvent.pressedMouseButtons & 1 != 0 }

    private func idleTick() {
        if buttonPressed {
            beginActiveTracking()
        } else if !isDragging {
            baselineChangeCount = dragPasteboard.changeCount
        }
    }

    private func beginActiveTracking() {
        guard activeTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.activeTick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        // Event tracking mode keeps the timer alive while menus track.
        RunLoop.main.add(timer, forMode: .eventTracking)
        activeTimer = timer
        activeTick()
    }

    private func activeTick() {
        guard buttonPressed else {
            activeTimer?.invalidate()
            activeTimer = nil
            ignoreUntilRelease = false
            if isDragging { endSession() }
            baselineChangeCount = dragPasteboard.changeCount
            return
        }
        if isDragging {
            let flags = NSEvent.modifierFlags.intersection([.shift, .command, .control, .option])
            if flags != lastFlags {
                lastFlags = flags
                onModifiersChanged?(flags)
            }
            return
        }
        guard !ignoreUntilRelease else { return }
        let count = dragPasteboard.changeCount
        guard count != baselineChangeCount else { return }
        baselineChangeCount = count
        let urls = Self.fileURLs(on: dragPasteboard)
        guard !urls.isEmpty else {
            // Text, images or promises without files: not ours to handle.
            ignoreUntilRelease = true
            return
        }
        files = urls
        isDragging = true
        lastFlags = NSEvent.modifierFlags.intersection([.shift, .command, .control, .option])
        onBegan?(urls, lastFlags)
    }

    private func endSession() {
        guard isDragging else { return }
        isDragging = false
        files = []
        lastFlags = []
        onEnded?()
    }

    /// Existing file URLs on a pasteboard, de-duplicated, in order.
    nonisolated static func fileURLs(on pasteboard: NSPasteboard) -> [URL] {
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        var seen = Set<String>()
        var result: [URL] = []
        for url in objects {
            let standardized = url.standardizedFileURL
            guard standardized.isFileURL, FileManager.default.fileExists(atPath: standardized.path),
                  !seen.contains(standardized.path) else { continue }
            seen.insert(standardized.path)
            result.append(standardized)
        }
        return result
    }
}
