import AppKit

/// Control-wheel actions. Each reports its outcome in the HUD.
@MainActor
enum FileActions {

    static func perform(_ action: FileAction, on files: [URL]) {
        let existing = files.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !existing.isEmpty else {
            HUDController.shared.fail(nil, title: "\(action.title) failed", detail: "The dropped items no longer exist.")
            return
        }
        switch action {
        case .airdrop: airDrop(existing)
        case .float: FloatingShelf.shared.add(existing)
        case .copy: copy(existing)
        case .move: move(existing)
        case .copyPath: copyPath(existing)
        case .terminal: openTerminal(existing)
        }
    }

    static func describe(_ files: [URL]) -> String {
        files.count == 1 ? "“\(files[0].lastPathComponent)”" : "\(files.count) items"
    }

    // MARK: AirDrop

    static func airDrop(_ files: [URL]) {
        guard let service = NSSharingService(named: .sendViaAirDrop) else {
            HUDController.shared.fail(nil, title: "AirDrop is not available", detail: "AirDrop is not supported on this Mac.")
            return
        }
        guard service.canPerform(withItems: files) else {
            HUDController.shared.fail(nil, title: "AirDrop is not available",
                                      detail: "Turn on Wi-Fi and Bluetooth, and allow AirDrop in Control Centre. Folders must be zipped first.")
            return
        }
        // The recipient picker is a system window; bring it to the front.
        NSApp.activate(ignoringOtherApps: true)
        service.perform(withItems: files)
    }

    // MARK: Copy

    static func copy(_ files: [URL]) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        // File URLs (not paths): Finder pastes these as real copies.
        guard pasteboard.writeObjects(files as [NSURL]) else {
            HUDController.shared.fail(nil, title: "Copy failed", detail: "The clipboard could not be written.")
            return
        }
        HUDController.shared.info("Copied \(describe(files))", detail: "Paste in Finder with ⌘V.", symbol: "doc.on.doc")
    }

    static func copyPath(_ files: [URL]) {
        let text = files.map(\.path).joined(separator: "\n")
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        HUDController.shared.info(files.count == 1 ? "Path copied" : "\(files.count) paths copied",
                                  detail: files.count == 1 ? files[0].path : "One path per line.", symbol: "doc.text")
    }

    // MARK: Move

    static func move(_ files: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Move Here"
        panel.message = "Move \(describe(files)) to:"
        panel.directoryURL = files.first?.deletingLastPathComponent()
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            MainActor.assumeIsolated { finishMove(files, to: destination) }
        }
    }

    static func finishMove(_ files: [URL], to destination: URL) {
        var moved: [URL] = []
        var problems: [String] = []
        for file in files {
            if file.deletingLastPathComponent().standardizedFileURL == destination.standardizedFileURL {
                problems.append("\(file.lastPathComponent) is already there")
                continue
            }
            if destination.standardizedFileURL.path.hasPrefix(file.standardizedFileURL.path + "/") {
                problems.append("\(file.lastPathComponent) cannot be moved into itself")
                continue
            }
            let target = destination.appendingPathComponent(file.lastPathComponent)
            // Never overwrite: an existing item with the same name stops the move.
            if FileManager.default.fileExists(atPath: target.path) {
                problems.append("“\(file.lastPathComponent)” already exists in \(destination.lastPathComponent)")
                continue
            }
            var coordinationError: NSError?
            var moveError: Error?
            NSFileCoordinator(filePresenter: nil).coordinate(writingItemAt: file, options: .forMoving, writingItemAt: target, options: .forReplacing, error: &coordinationError) { from, to in
                do { try FileManager.default.moveItem(at: from, to: to) } catch { moveError = error }
            }
            if let error = coordinationError ?? (moveError as NSError?) {
                problems.append("\(file.lastPathComponent): \(error.localizedDescription)")
            } else {
                moved.append(target)
            }
        }
        if moved.isEmpty {
            HUDController.shared.fail(nil, title: "Nothing was moved", detail: problems.joined(separator: "\n"))
        } else {
            HUDController.shared.succeed(nil, title: "Moved \(describe(moved)) to \(destination.lastPathComponent)",
                                         detail: problems.isEmpty ? nil : problems.joined(separator: "; "), outputs: moved)
        }
    }

    // MARK: Terminal

    static func terminalDirectory(for file: URL) -> URL {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir), isDir.boolValue,
           !NSWorkspace.shared.isFilePackage(atPath: file.path) {
            return file
        }
        return file.deletingLastPathComponent()
    }

    static func openTerminal(_ files: [URL]) {
        let directory = terminalDirectory(for: files[0])
        let wantsITerm = AppSettings.shared.terminalApp == "iTerm"
        let bundleID = wantsITerm && NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.googlecode.iterm2") != nil
            ? "com.googlecode.iterm2" : "com.apple.Terminal"
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            HUDController.shared.fail(nil, title: "Terminal not found", detail: nil)
            return
        }
        // Opening a folder with Terminal/iTerm starts a shell in it — no
        // script, no string concatenation, no Apple Events permission.
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        NSWorkspace.shared.open([directory], withApplicationAt: appURL, configuration: config) { _, error in
            if let error {
                Task { @MainActor in HUDController.shared.fail(nil, title: "Could not open Terminal", detail: error.localizedDescription) }
            }
        }
    }
}
