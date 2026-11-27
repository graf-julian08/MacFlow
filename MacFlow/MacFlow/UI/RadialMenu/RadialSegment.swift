import SwiftUI

/// What a wheel segment does when a file is dropped on it.
enum SegmentAction: Hashable {
    case convert(ConversionOption)
    case tool(FileTool)
    case action(FileAction)
    case more
    case back
}

/// One wheel segment.
struct RadialSegment: Identifiable, Hashable {
    let id: String
    let label: String
    let symbol: String?
    /// Line shown under the wheel while hovered.
    let subtitle: String
    let action: SegmentAction

    static func == (lhs: RadialSegment, rhs: RadialSegment) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Wheel geometry and colours.
struct RadialMenuConfiguration {
    var radius: CGFloat = 128
    var innerRadius: CGFloat = 57
    var segmentGap: CGFloat = 3.5
    var accentColor: Color = Color(nsColor: .systemBlue)
    /// Visible segments including a MORE segment when items overflow.
    var maxVisibleSegments: Int = 8

    static let `default` = RadialMenuConfiguration()

    static func current() -> RadialMenuConfiguration {
        let settings = AppSettings.shared
        var config = RadialMenuConfiguration()
        let scale = CGFloat(min(1.3, max(0.8, settings.radialMenuScale)))
        config.radius *= scale
        config.innerRadius *= scale
        config.accentColor = settings.accentColor
        return config
    }
}
