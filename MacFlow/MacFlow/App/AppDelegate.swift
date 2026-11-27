import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var statusItem: NSStatusItem?
    private let tracker = DragSessionTracker()
    private let radial = RadialPanelController()
    private var sessionFiles: [ClassifiedFile] = []
    private var keyMonitor: Any?
    private var localMouseMonitor: Any?
    private var settingsObserver: NSObjectProtocol?

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        if terminateIfAlreadyRunning() { return }

        // Helper probes run off the main thread; until they finish, helper-
        // backed formats are simply not offered.
        DispatchQueue.global(qos: .utility).async {
            EngineCapabilities.shared.probeExternalTools()
        }

        setupStatusItem()
        setupDragHandling()
        applyKeyboardMonitor()

        if !UserDefaults.standard.bool(forKey: "didFirstLaunch") {
            UserDefaults.standard.set(true, forKey: "didFirstLaunch")
            AppSettings.shared.applyLoginItem()
            showWelcome()
        } else if AppSettings.shared.launchAtLogin, SMAppService.mainApp.status == .notRegistered {
            AppSettings.shared.applyLoginItem()
        }

        settingsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.statusItem?.isVisible = AppSettings.shared.showMenuBarIcon
                self?.applyKeyboardMonitor()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker.stop()
        radial.dismiss(animated: false)
        OperationCenter.shared.cancelAll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Re-opening the app (Finder, Spotlight) while it runs shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        SettingsWindowController.shared.show()
        return true
    }

    private func terminateIfAlreadyRunning() -> Bool {
        guard let id = Bundle.main.bundleIdentifier else { return false }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { $0 != .current }
        guard !others.isEmpty else { return false }
        NSApp.terminate(nil)
        return true
    }

    // MARK: - Drag → wheel

    private func setupDragHandling() {
        tracker.onBegan = { [weak self] urls, flags in
            guard let self else { return }
            self.sessionFiles = urls.prefix(500).map { FileClassifier.shared.classify($0) }
            self.showWheel(for: flags)
        }
        tracker.onModifiersChanged = { [weak self] flags in
            self?.showWheel(for: flags)
        }
        tracker.onEnded = { [weak self] in
            self?.radial.dragEnded()
            self?.sessionFiles = []
        }
        radial.onCommit = { segment, files, location in
            OperationCenter.shared.commit(segment, files: files, at: location)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.tracker.noteLocalMouseDown()
            return event
        }
        if !UserDefaults.standard.bool(forKey: "paused") { tracker.start() }
    }

    /// Opens or switches the wheel. Releasing all modifiers keeps it open;
    /// only the end of the drag closes it.
    private func showWheel(for flags: NSEvent.ModifierFlags) {
        guard tracker.isDragging, !sessionFiles.isEmpty, let mode = AppSettings.shared.mode(for: flags) else { return }
        radial.show(mode: mode, files: sessionFiles, at: NSEvent.mouseLocation)
    }

    // MARK: - Keyboard navigation (optional, needs Accessibility)

    private func applyKeyboardMonitor() {
        let wanted = AppSettings.shared.keyboardNavigation && AXIsProcessTrusted()
        if wanted && keyMonitor == nil {
            keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handleKey(event) }
            }
        } else if !wanted, let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    private func handleKey(_ event: NSEvent) {
        guard radial.isVisible else { return }
        switch event.keyCode {
        case 123, 126: radial.moveSelection(by: -1) // left, up
        case 124, 125: radial.moveSelection(by: 1)  // right, down
        case 53: radial.dismiss(animated: true)     // escape
        default: break
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "MacFlow")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "MacFlow — drag a file and hold ⇧, ⌘ or ⌃"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        item.isVisible = AppSettings.shared.showMenuBarIcon
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let header = NSMenuItem(title: "MacFlow", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let hint = NSMenuItem(title: "Drag a file, then hold \(AppSettings.symbol(for: AppSettings.shared.convertModifier)) \(AppSettings.symbol(for: AppSettings.shared.toolsModifier)) or \(AppSettings.symbol(for: AppSettings.shared.actionsModifier))", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let paused = UserDefaults.standard.bool(forKey: "paused")
        let shelf = NSMenuItem(title: FloatingShelf.shared.isVisible ? "Hide Shelf" : "Show Shelf", action: #selector(toggleShelf), keyEquivalent: "")
        shelf.target = self
        shelf.isEnabled = !FloatingShelf.shared.items.isEmpty
        menu.addItem(shelf)
        let pause = NSMenuItem(title: paused ? "Resume MacFlow" : "Pause MacFlow", action: #selector(togglePause), keyEquivalent: "")
        pause.target = self
        menu.addItem(pause)
        menu.addItem(.separator())

        let formats = NSMenuItem(title: "Supported Formats…", action: #selector(showFormats), keyEquivalent: "")
        formats.target = self
        menu.addItem(formats)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit MacFlow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    @objc private func toggleShelf() { FloatingShelf.shared.toggle() }

    @objc private func togglePause() {
        let paused = !UserDefaults.standard.bool(forKey: "paused")
        UserDefaults.standard.set(paused, forKey: "paused")
        if paused { tracker.stop() } else { tracker.start() }
        HUDController.shared.info(paused ? "MacFlow paused" : "MacFlow active",
                                  detail: paused ? "The wheel will not appear while dragging." : "Drag a file and hold a modifier key.",
                                  symbol: paused ? "pause" : "play")
    }

    @objc private func showFormats() { SettingsWindowController.shared.show(tab: .formats) }
    @objc private func showSettings() { SettingsWindowController.shared.show() }

    private func showWelcome() {
        SettingsWindowController.shared.show(tab: .general)
    }
}
