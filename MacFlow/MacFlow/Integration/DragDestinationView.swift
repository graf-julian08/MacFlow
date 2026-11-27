import AppKit

/// The radial panel's drop target. It reads the files from the *dragging
/// pasteboard of this drop* (never from a cache), reports pointer movement
/// for hover highlighting and accepts the drop only over a selectable segment.
final class DragDestinationView: NSView {

    /// Pointer location in SwiftUI (top-left) coordinates of this view.
    var onHover: ((CGPoint) -> Void)?
    var onExit: (() -> Void)?
    /// Asked whether a drop at the current hover state would do something.
    var canAcceptDrop: (() -> Bool)?
    /// Performs the drop; returns false if nothing was executed.
    var onDrop: (([URL]) -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        registerForDraggedTypes([.fileURL])
    }

    override var isFlipped: Bool { true }

    // The whole panel rectangle is a drop target, including transparent areas.
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    // MARK: - NSDraggingDestination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        update(sender)
    }

    override func wantsPeriodicDraggingUpdates() -> Bool { true }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        onExit?()
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        report(sender)
        return canAcceptDrop?() == true && !Self.fileURLs(sender).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        report(sender)
        let urls = Self.fileURLs(sender)
        guard !urls.isEmpty else { return false }
        return onDrop?(urls) ?? false
    }

    // MARK: - Helpers

    private func report(_ sender: NSDraggingInfo) {
        let point = convert(sender.draggingLocation, from: nil)
        onHover?(point)
    }

    private func update(_ sender: NSDraggingInfo) -> NSDragOperation {
        report(sender)
        guard canAcceptDrop?() == true, sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) else {
            return []
        }
        return Self.operation(for: sender.draggingSourceOperationMask)
    }

    /// The operation must be one the source allows *right now*. Holding ⌘
    /// restricts the mask to `.generic`, ⌃ to `.link`, ⌥ to `.copy` — a fixed
    /// `.copy` would make AppKit reject the drop and hand it back to Finder.
    /// `.move` is never requested: MacFlow does not want the source to delete
    /// anything.
    static func operation(for mask: NSDragOperation) -> NSDragOperation {
        for candidate in [NSDragOperation.copy, .generic, .link] where mask.contains(candidate) {
            return candidate
        }
        return []
    }

    static func fileURLs(_ sender: NSDraggingInfo) -> [URL] {
        DragSessionTracker.fileURLs(on: sender.draggingPasteboard)
    }
}
