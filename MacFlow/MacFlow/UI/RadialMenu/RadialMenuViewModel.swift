import Foundation
import SwiftUI

/// State of the wheel: segments for the current mode and files, hover,
/// keyboard selection and the spring-loaded MORE page.
@MainActor
final class RadialMenuViewModel: ObservableObject {

    @Published private(set) var segments: [RadialSegment] = []
    @Published private(set) var hoveredSegmentID: String?
    @Published private(set) var centerLabel = ""
    @Published private(set) var subtitle = ""
    @Published private(set) var mode: RadialMenuMode
    @Published var isVisible = false
    @Published private(set) var fileCountBadge: Int = 1
    @Published private(set) var page = 0

    let config: RadialMenuConfiguration
    private(set) var files: [ClassifiedFile] = []
    private var allItems: [RadialSegment] = []
    private var defaultCenter = ""
    private var defaultSubtitle = ""
    private var moreTimer: Timer?
    /// Segment chosen with the arrow keys; kept while the pointer rests in
    /// the neutral centre so a drop there commits it.
    private var keyboardSelectionID: String?

    init(mode: RadialMenuMode, config: RadialMenuConfiguration = .current()) {
        self.mode = mode
        self.config = config
    }

    var isEmpty: Bool { segments.isEmpty }

    // MARK: - Building

    func configure(mode: RadialMenuMode, files: [ClassifiedFile]) {
        self.mode = mode
        self.files = files
        fileCountBadge = files.count
        page = 0
        allItems = Self.items(for: mode, files: files)
        let (center, subtitle) = Self.defaultLabels(mode: mode, files: files, hasItems: !allItems.isEmpty)
        defaultCenter = center
        defaultSubtitle = subtitle
        layoutPage()
    }

    static func items(for mode: RadialMenuMode, files: [ClassifiedFile]) -> [RadialSegment] {
        switch mode {
        case .convert:
            return ConversionCatalog.shared.options(for: files).map { option in
                var subtitle = "Convert to \(option.target.label)"
                if files.count > 1 && option.target.category == .archive && files.count > 1 {
                    subtitle = "Archive \(files.count) items as \(option.target.label)"
                }
                if let note = option.note { subtitle += " · \(note)" }
                return RadialSegment(id: "convert.\(option.id)", label: option.target.label, symbol: nil, subtitle: subtitle, action: .convert(option))
            }
        case .tools:
            let tools = ToolCatalog.tools(for: files)
            return (tools.primary + tools.more).map { tool in
                RadialSegment(id: "tool.\(tool.rawValue)", label: tool.label, symbol: tool.sfSymbol, subtitle: tool.title, action: .tool(tool))
            }
        case .actions:
            return FileAction.allCases.map { action in
                RadialSegment(id: "action.\(action.rawValue)", label: action.label, symbol: action.sfSymbol, subtitle: action.title, action: .action(action))
            }
        }
    }

    static func defaultLabels(mode: RadialMenuMode, files: [ClassifiedFile], hasItems: Bool) -> (String, String) {
        let formats = Set(files.compactMap { $0.format?.id })
        let sourceLabel: String = {
            if files.count == 1, let f = files.first?.format { return f.id == "folder" ? "FOLDER" : f.label }
            if formats.count == 1, let f = files.first?.format { return "\(files.count) \(f.label)" }
            return "\(files.count) FILES"
        }()
        switch mode {
        case .convert:
            guard hasItems else {
                let name = files.count == 1 ? (files.first?.format?.displayName ?? "this file") : "these files"
                return (sourceLabel, "No conversions available for \(name)")
            }
            return (sourceLabel, "Convert format")
        case .tools:
            guard hasItems else {
                let name = files.count == 1 ? (files.first?.format?.displayName ?? "this file") : "this selection"
                return ("TOOLS", "No tools available for \(name)")
            }
            return ("TOOLS", "File tools")
        case .actions:
            return ("ACTIONS", "File actions")
        }
    }

    /// Splits items into pages of at most `maxVisibleSegments`, reserving a
    /// slot for MORE / BACK when needed.
    private func layoutPage() {
        let max = config.maxVisibleSegments
        hoveredSegmentID = nil
        if allItems.count <= max {
            segments = allItems
        } else {
            let firstPageCount = max - 1
            if page == 0 {
                let overflow = allItems.count - firstPageCount
                segments = Array(allItems.prefix(firstPageCount)) + [
                    RadialSegment(id: "more", label: "MORE", symbol: "ellipsis", subtitle: "\(overflow) more — hold here", action: .more)
                ]
            } else {
                let rest = Array(allItems.dropFirst(firstPageCount))
                let perPage = max - 1
                let start = (page - 1) * perPage
                let slice = Array(rest[start..<min(rest.count, start + perPage)])
                var items = slice
                let hasNext = start + perPage < rest.count
                items.append(RadialSegment(id: hasNext ? "more" : "back", label: hasNext ? "MORE" : "BACK",
                                           symbol: hasNext ? "ellipsis" : "chevron.backward",
                                           subtitle: hasNext ? "More — hold here" : "Back — hold here", action: hasNext ? .more : .back))
                segments = items
            }
        }
        updateLabels()
    }

    private func changePage(_ newPage: Int) {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            page = newPage
            layoutPage()
        }
    }

    // MARK: - Hover

    /// `point` is in the panel's top-left coordinate space.
    func updateHover(at point: CGPoint, in size: CGSize) {
        var id = segmentID(at: point, in: size)
        if id == nil, let keyboard = keyboardSelectionID { id = keyboard } else if id != nil { keyboardSelectionID = nil }
        guard id != hoveredSegmentID else { return }
        hoveredSegmentID = id
        updateLabels()
        scheduleSpringLoad()
    }

    func clearHover() {
        keyboardSelectionID = nil
        guard hoveredSegmentID != nil else { return }
        hoveredSegmentID = nil
        moreTimer?.invalidate()
        updateLabels()
    }

    func segmentID(at point: CGPoint, in size: CGSize) -> String? {
        guard !segments.isEmpty else { return nil }
        let dx = point.x - size.width / 2
        let dy = point.y - size.height / 2
        let distance = (dx * dx + dy * dy).squareRoot()
        // The inner disc is neutral; slightly beyond the rim still counts.
        guard distance > config.innerRadius - 2, distance < config.radius + 26 else { return nil }
        var angle = atan2(dx, -dy)
        if angle < 0 { angle += 2 * .pi }
        let slice = 2 * Double.pi / Double(segments.count)
        let index = Int((Double(angle) + slice / 2) / slice) % segments.count
        return segments[index].id
    }

    var hoveredSegment: RadialSegment? {
        guard let id = hoveredSegmentID else { return nil }
        return segments.first { $0.id == id }
    }

    /// Segment that a drop would trigger (never MORE/BACK).
    var committableSegment: RadialSegment? {
        guard let segment = hoveredSegment else { return nil }
        switch segment.action {
        case .more, .back: return nil
        default: return segment
        }
    }

    // MARK: - Keyboard

    func moveSelection(by delta: Int) {
        guard !segments.isEmpty else { return }
        let current = hoveredSegmentID.flatMap { id in segments.firstIndex { $0.id == id } } ?? (delta > 0 ? -1 : 0)
        let next = ((current + delta) % segments.count + segments.count) % segments.count
        hoveredSegmentID = segments[next].id
        keyboardSelectionID = hoveredSegmentID
        updateLabels()
    }

    func activateHoveredPager() -> Bool {
        guard let segment = hoveredSegment else { return false }
        switch segment.action {
        case .more: changePage(page + 1); return true
        case .back: changePage(0); return true
        default: return false
        }
    }

    // MARK: - Spring-loaded MORE

    private func scheduleSpringLoad() {
        moreTimer?.invalidate()
        guard let segment = hoveredSegment else { return }
        switch segment.action {
        case .more, .back:
            let timer = Timer(timeInterval: 0.5, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.hoveredSegment?.id == segment.id else { return }
                    _ = self.activateHoveredPager()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            moreTimer = timer
        default:
            break
        }
    }

    private func updateLabels() {
        if let segment = hoveredSegment {
            switch segment.action {
            case .more, .back: centerLabel = defaultCenter
            default: centerLabel = segment.label
            }
            subtitle = segment.subtitle
        } else {
            centerLabel = defaultCenter
            subtitle = defaultSubtitle
        }
    }

    deinit {
        moreTimer?.invalidate()
    }
}
