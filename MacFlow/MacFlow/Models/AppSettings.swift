import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

/// User preferences, persisted in UserDefaults.
final class AppSettings: ObservableObject {

    static let shared = AppSettings()

    // MARK: - General

    @AppStorage("launchAtLogin") var launchAtLogin: Bool = true { didSet { applyLoginItem() } }
    @AppStorage("showMenuBarIcon") var showMenuBarIcon: Bool = true
    @AppStorage("defaultOutputLocation") var defaultOutputLocationPath: String = ""
    @AppStorage("openResultInFinder") var openResultInFinder: Bool = true
    @AppStorage("saveNextToOriginal") var saveNextToOriginal: Bool = true
    @AppStorage("playSounds") var playSounds: Bool = true

    // MARK: - Shortcuts

    /// "shift", "command", "control", "option" or combinations like "option+shift".
    @AppStorage("convertModifier") var convertModifier: String = "shift"
    @AppStorage("toolsModifier") var toolsModifier: String = "command"
    @AppStorage("actionsModifier") var actionsModifier: String = "control"
    @AppStorage("keyboardNavigation") var keyboardNavigation: Bool = true

    // MARK: - Appearance

    @AppStorage("appearance") var appearance: String = "system"
    @AppStorage("animationsEnabled") var animationsEnabled: Bool = true
    @AppStorage("radialMenuScale") var radialMenuScale: Double = 1.0
    @AppStorage("accentChoice") var accentChoice: String = "blue"

    // MARK: - Conversion

    @AppStorage("defaultImageQuality") var defaultImageQuality: Double = 0.85
    @AppStorage("confirmOnQualityLoss") var confirmOnQualityLoss: Bool = true
    @AppStorage("preserveMetadata") var preserveMetadata: Bool = true
    @AppStorage("useExternalEngines") var useExternalEngines: Bool = true

    // MARK: - Actions

    @AppStorage("terminalApp") var terminalApp: String = "Terminal"
    @AppStorage("shelfEdge") var shelfEdge: String = "right"

    private init() {}

    // MARK: - Output location

    var defaultOutputLocation: URL? {
        get { defaultOutputLocationPath.isEmpty ? nil : URL(fileURLWithPath: defaultOutputLocationPath, isDirectory: true) }
        set { defaultOutputLocationPath = newValue?.path ?? "" }
    }

    func outputDirectory(for sourceURL: URL) -> URL {
        if !saveNextToOriginal, let custom = defaultOutputLocation,
           FileManager.default.fileExists(atPath: custom.path) {
            return custom
        }
        return sourceURL.deletingLastPathComponent()
    }

    // MARK: - Login item (SMAppService)

    func applyLoginItem() {
        do {
            if launchAtLogin {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MacFlow: login item update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Modifiers

    static let modifierChoices: [(id: String, title: String)] = [
        ("shift", "⇧ Shift"),
        ("command", "⌘ Command"),
        ("control", "⌃ Control"),
        ("option", "⌥ Option"),
        ("option+shift", "⌥⇧ Option + Shift"),
        ("option+command", "⌥⌘ Option + Command"),
        ("control+shift", "⌃⇧ Control + Shift"),
    ]

    static func flags(for spec: String) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        for part in spec.split(separator: "+") {
            switch part {
            case "shift": flags.insert(.shift)
            case "command": flags.insert(.command)
            case "control": flags.insert(.control)
            case "option": flags.insert(.option)
            default: break
            }
        }
        return flags
    }

    func modifierSpec(for mode: RadialMenuMode) -> String {
        switch mode {
        case .convert: return convertModifier
        case .tools: return toolsModifier
        case .actions: return actionsModifier
        }
    }

    func flags(for mode: RadialMenuMode) -> NSEvent.ModifierFlags {
        Self.flags(for: modifierSpec(for: mode))
    }

    /// Mode whose modifier set exactly matches the pressed modifiers (ignoring
    /// Caps Lock and Fn). Exact matching keeps ⇧ and ⌥⇧ distinct.
    func mode(for pressed: NSEvent.ModifierFlags) -> RadialMenuMode? {
        let relevant = pressed.intersection([.shift, .command, .control, .option])
        guard !relevant.isEmpty else { return nil }
        return RadialMenuMode.allCases.first { flags(for: $0) == relevant }
    }

    var hasModifierConflict: Bool {
        let specs = RadialMenuMode.allCases.map { Self.flags(for: modifierSpec(for: $0)).rawValue }
        return Set(specs).count != specs.count
    }

    func resetShortcuts() {
        convertModifier = "shift"
        toolsModifier = "command"
        actionsModifier = "control"
    }

    static func symbol(for spec: String) -> String {
        modifierChoices.first { $0.id == spec }?.title.split(separator: " ").first.map(String.init) ?? spec
    }

    // MARK: - Accent

    var accentColor: Color {
        switch accentChoice {
        case "orange": return Color(nsColor: .systemOrange)
        case "graphite": return Color(nsColor: .systemGray)
        case "purple": return Color(nsColor: .systemPurple)
        case "pink": return Color(nsColor: .systemPink)
        case "green": return Color(nsColor: .systemGreen)
        case "system": return Color.accentColor
        default: return Color(nsColor: .systemBlue)
        }
    }
}
