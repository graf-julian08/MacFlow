import AppKit
import ServiceManagement
import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable {
    case general, shortcuts, appearance, conversion, formats, engines, privacy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .appearance: return "Appearance"
        case .conversion: return "Conversion"
        case .formats: return "Formats"
        case .engines: return "Engines"
        case .privacy: return "Privacy"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .appearance: return "paintbrush"
        case .conversion: return "arrow.triangle.2.circlepath"
        case .formats: return "doc.on.doc"
        case .engines: return "cpu"
        case .privacy: return "hand.raised"
        }
    }
}

@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?
    private let selection = SettingsSelection()

    func show(tab: SettingsTab? = nil) {
        if let tab { selection.tab = tab }
        if window == nil {
            let hosting = NSHostingController(rootView: SettingsView(selection: selection))
            let window = NSWindow(contentViewController: hosting)
            window.title = "MacFlow Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.isReleasedWhenClosed = false
            window.setContentSize(NSSize(width: 680, height: 560))
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class SettingsSelection: ObservableObject {
    @Published var tab: SettingsTab = .general
}

struct SettingsView: View {
    @ObservedObject var selection: SettingsSelection

    var body: some View {
        TabView(selection: $selection.tab) {
            GeneralSettingsView().tabItem { Label("General", systemImage: "gearshape") }.tag(SettingsTab.general)
            ShortcutsSettingsView().tabItem { Label("Shortcuts", systemImage: "keyboard") }.tag(SettingsTab.shortcuts)
            AppearanceSettingsView().tabItem { Label("Appearance", systemImage: "paintbrush") }.tag(SettingsTab.appearance)
            ConversionSettingsView().tabItem { Label("Conversion", systemImage: "arrow.triangle.2.circlepath") }.tag(SettingsTab.conversion)
            FormatsSettingsView().tabItem { Label("Formats", systemImage: "doc.on.doc") }.tag(SettingsTab.formats)
            EnginesSettingsView().tabItem { Label("Engines", systemImage: "cpu") }.tag(SettingsTab.engines)
            PrivacySettingsView().tabItem { Label("Privacy", systemImage: "hand.raised") }.tag(SettingsTab.privacy)
        }
        .frame(width: 680, height: 560)
    }
}

// MARK: - General

struct GeneralSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Drag any file, then hold a key").font(.headline)
                        Text("\(AppSettings.symbol(for: settings.convertModifier)) Convert · \(AppSettings.symbol(for: settings.toolsModifier)) File Tools · \(AppSettings.symbol(for: settings.actionsModifier)) File Actions — release the file on a segment. Releasing it anywhere else does nothing.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            Section("Startup") {
                Toggle("Open MacFlow at login", isOn: $settings.launchAtLogin)
                    .onChange(of: settings.launchAtLogin) { _, _ in loginStatus = SMAppService.mainApp.status }
                HStack {
                    Text(loginStatusText).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if loginStatus == .requiresApproval {
                        Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
                if !settings.showMenuBarIcon {
                    Text("Open MacFlow again from Applications to reach Settings.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Results") {
                Picker("Save results", selection: $settings.saveNextToOriginal) {
                    Text("Next to the original").tag(true)
                    Text("In a chosen folder").tag(false)
                }
                if !settings.saveNextToOriginal {
                    HStack {
                        Text(settings.defaultOutputLocation?.path ?? "No folder chosen").font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…", action: chooseFolder)
                    }
                }
                Toggle("Reveal results in Finder", isOn: $settings.openResultInFinder)
                Toggle("Play sounds", isOn: $settings.playSounds)
                Text("Originals are never changed. Results are new files; an existing file is never overwritten — “Name (2)” is used instead.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("File Actions") {
                Picker("Terminal", selection: $settings.terminalApp) {
                    Text("Terminal").tag("Terminal")
                    Text("iTerm2").tag("iTerm")
                }
                Picker("Shelf position", selection: $settings.shelfEdge) {
                    Text("Right").tag("right"); Text("Left").tag("left"); Text("Bottom").tag("bottom")
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { loginStatus = SMAppService.mainApp.status }
    }

    private var loginStatusText: String {
        switch loginStatus {
        case .enabled: return "MacFlow opens automatically when you log in."
        case .requiresApproval: return "Allow MacFlow in System Settings → General → Login Items."
        case .notFound: return "Move MacFlow to the Applications folder to enable this."
        default: return "MacFlow does not open at login."
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        if panel.runModal() == .OK { settings.defaultOutputLocation = panel.url }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section("Hold while dragging") {
                modifierPicker("Convert", selection: $settings.convertModifier)
                modifierPicker("File Tools", selection: $settings.toolsModifier)
                modifierPicker("File Actions", selection: $settings.actionsModifier)
                if settings.hasModifierConflict {
                    Label("Two modes use the same keys. Choose different keys for each mode.", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Color(nsColor: .systemRed)).font(.callout)
                }
                Button("Restore Defaults") { settings.resetShortcuts() }
            }
            Section("Behaviour") {
                Text("The wheel stays open once it appears — you can let go of the key. Press another mode's key to switch. Drop outside a segment to cancel.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Keyboard") {
                Toggle("Arrow keys select segments while dragging", isOn: $settings.keyboardNavigation)
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .foregroundStyle(trusted ? Color.green : Color.orange)
                    Text(trusted ? "Accessibility access granted." : "Needs Accessibility access (optional — the wheel works without it).")
                        .font(.caption)
                    Spacer()
                    if !trusted {
                        Button("Grant Access…") {
                            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in trusted = AXIsProcessTrusted() }
    }

    private func modifierPicker(_ title: String, selection: Binding<String>) -> some View {
        Picker(title, selection: selection) {
            ForEach(AppSettings.modifierChoices, id: \.id) { Text($0.title).tag($0.id) }
        }
    }
}

// MARK: - Appearance

struct AppearanceSettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Preview") {
                WheelPreviewRow().frame(height: 210)
            }
            Section("Style") {
                Picker("Appearance", selection: $settings.appearance) {
                    Text("System").tag("system"); Text("Light").tag("light"); Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                Picker("Highlight", selection: $settings.accentChoice) {
                    Text("Blue").tag("blue"); Text("Orange").tag("orange"); Text("Purple").tag("purple")
                    Text("Pink").tag("pink"); Text("Green").tag("green"); Text("Graphite").tag("graphite"); Text("System Accent").tag("system")
                }
                SliderRow(title: "Wheel size", value: $settings.radialMenuScale, range: 0.8...1.3, format: { "\(Int($0 * 100))%" })
                Toggle("Animations", isOn: $settings.animationsEnabled)
                Text("Uses the system Liquid Glass material. “Reduce Motion” in Accessibility settings is respected.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The three wheels side by side, rendered with the real wheel view.
struct WheelPreviewRow: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 0) {
            ForEach(RadialMenuMode.allCases, id: \.self) { mode in
                VStack(spacing: 2) {
                    WheelPreview(mode: mode)
                        .scaleEffect(0.52)
                        .frame(width: 180, height: 180)
                    Text("\(AppSettings.symbol(for: settings.modifierSpec(for: mode))) \(mode.displayName)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .id(settings.accentChoice + "\(settings.radialMenuScale)")
    }
}

private struct WheelPreview: View {
    let mode: RadialMenuMode
    @StateObject private var model: RadialMenuViewModel

    init(mode: RadialMenuMode) {
        self.mode = mode
        let m = RadialMenuViewModel(mode: mode)
        let sample = ClassifiedFile(url: URL(fileURLWithPath: "/sample.jpg"), format: FormatRegistry.shared["jpg"], isDirectory: false, extensionMismatch: false)
        m.configure(mode: mode, files: [sample])
        _model = StateObject(wrappedValue: m)
    }

    var body: some View {
        RadialMenuView(viewModel: model).allowsHitTesting(false)
    }
}

// MARK: - Conversion

struct ConversionSettingsView: View {
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Images") {
                SliderRow(title: "Quality", value: $settings.defaultImageQuality, range: 0.5...1, format: { "\(Int(($0 * 100).rounded()))%" })
                Text("Used for JPEG, HEIC, AVIF, WebP and JPEG 2000. Lossless formats ignore it.").font(.caption).foregroundStyle(.secondary)
                Toggle("Keep metadata (camera, date, location)", isOn: $settings.preserveMetadata)
            }
            Section("Safety") {
                Toggle("Ask before reconstructing conversions", isOn: $settings.confirmOnQualityLoss)
                Text("PDF → Word and other “best effort” results are rebuilt from text and never exact. Lossy steps are shown under the wheel before you drop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Optional helpers") {
                Toggle("Use FFmpeg, cwebp and oggenc when installed", isOn: $settings.useExternalEngines)
                Text("Adds formats like MKV, WebM, MP3, OGG and WebP output. Changes apply after restarting MacFlow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Formats

struct FormatsSettingsView: View {
    private struct Row: Identifiable {
        let id: String
        let format: FileFormat
        let targets: [String]
        let tools: [String]
    }

    private var rows: [(FileCategory, [Row])] {
        let registry = FormatRegistry.shared
        var grouped: [FileCategory: [Row]] = [:]
        for format in registry.all where format.category != .folder {
            let file = ClassifiedFile(url: URL(fileURLWithPath: "/nonexistent.\(format.primaryExtension)"), format: format, isDirectory: false, extensionMismatch: false)
            var inspection = FileInspection()
            inspection.dataIsListOfObjects = format.id == "json"
            let targets = ConversionCatalog.shared.options(for: file, inspection: inspection).map(\.target.label)
            let tools = ToolCatalog.tools(for: [file])
            let toolNames = (tools.primary + tools.more).map(\.title)
            guard !targets.isEmpty || !toolNames.isEmpty else { continue }
            grouped[format.category, default: []].append(Row(id: format.id, format: format, targets: targets, tools: toolNames))
        }
        return FileCategory.allCases.compactMap { c in grouped[c].map { (c, $0.sorted { $0.format.label < $1.format.label }) } }
    }

    var body: some View {
        List {
            Text("Computed live from the engines on this Mac — only what works here is listed.")
                .font(.caption).foregroundStyle(.secondary)
            ForEach(rows, id: \.0) { category, items in
                Section(category.displayName) {
                    ForEach(items) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(row.format.label).font(.system(size: 12, weight: .semibold)).frame(width: 70, alignment: .leading)
                                Text(row.format.extensions.filter { !$0.isEmpty }.prefix(6).map { ".\($0)" }.joined(separator: " "))
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            if !row.targets.isEmpty {
                                Text("→ " + row.targets.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                            }
                            if !row.tools.isEmpty {
                                Text("Tools: " + row.tools.joined(separator: ", ")).font(.caption).foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

// MARK: - Engines

struct EnginesSettingsView: View {
    private let caps = EngineCapabilities.shared
    private let os = ProcessInfo.processInfo.operatingSystemVersionString

    var body: some View {
        Form {
            Section("Built into macOS") {
                engine("ImageIO & Core Image", "\(caps.imageDecodeTypes.count) readable, \(caps.imageEncodeTypes.count) writable image types", true)
                engine("AVFoundation & VideoToolbox", "Hardware video/audio encoding · \(os)", true)
                engine("PDFKit", "PDF rendering, text, encryption", true)
                engine("Vision", "OCR, faces, QR codes, subject cut-out", true)
                engine("Text system", "DOCX, DOC, ODT, RTF, HTML", true)
                engine("libarchive (bsdtar)", caps.bsdtarPath ?? "missing", caps.bsdtarPath != nil)
            }
            Section("Optional helpers") {
                engine("FFmpeg", caps.ffmpeg.map { "\($0.version)\n\($0.path)" } ?? "Not installed — MKV, WebM, AVI, MP3/Opus output unavailable", caps.ffmpeg != nil)
                engine("cwebp", caps.cwebp.map { "\($0.version) · \($0.path)" } ?? "Not installed — WebP output unavailable", caps.cwebp != nil)
                engine("oggenc", caps.oggenc.map { "\($0.version) · \($0.path)" } ?? "Not installed — OGG Vorbis output unavailable", caps.oggenc != nil)
                Text("Helpers are never downloaded by MacFlow. Install them yourself if you need these formats (e.g. with Homebrew), then restart MacFlow.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func engine(_ name: String, _ detail: String, _ ok: Bool) -> some View {
        HStack(alignment: .top) {
            Image(systemName: ok ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }
}

// MARK: - Privacy

struct PrivacySettingsView: View {
    @State private var trusted = AXIsProcessTrusted()

    var body: some View {
        Form {
            Section("Local processing") {
                Label("Every file is processed on this Mac. MacFlow makes no network connections.", systemImage: "lock.shield")
                Label("Originals are only read, never modified. Results are verified before they are saved.", systemImage: "checkmark.shield")
            }
            Section("Permissions") {
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    VStack(alignment: .leading) {
                        Text("Drag detection")
                        Text("Works without any permission.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Image(systemName: trusted ? "checkmark.circle.fill" : "circle").foregroundStyle(trusted ? Color.green : Color.secondary)
                    VStack(alignment: .leading) {
                        Text("Accessibility (optional)")
                        Text("Only for arrow-key navigation in the wheel.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
                Text("If macOS asks for access to Desktop, Documents or Downloads, MacFlow needs it to save results next to your files there.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in trusted = AXIsProcessTrusted() }
    }
}
