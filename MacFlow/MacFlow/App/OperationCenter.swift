import AppKit

/// Limits concurrent heavy jobs so the Mac stays responsive.
actor JobLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if !waiters.isEmpty { waiters.removeFirst().resume() } else { running -= 1 }
    }
}

/// Executes what the wheel selected and reports every outcome.
@MainActor
final class OperationCenter {

    static let shared = OperationCenter()

    let toolPanels = ToolPanelController()
    private let limiter = JobLimiter(limit: max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 3)))
    private var tasks: [UUID: Task<Void, Never>] = [:]

    // MARK: - Entry from the wheel

    func commit(_ segment: RadialSegment, files: [ClassifiedFile], at location: NSPoint) {
        switch segment.action {
        case .convert(let option):
            if option.requiresConfirmation && AppSettings.shared.confirmOnQualityLoss {
                toolPanels.confirm(title: "Convert to \(option.target.label)?",
                                   message: (option.note ?? "This conversion is not exact.") + ". The original stays unchanged; the result is a new file.",
                                   confirmTitle: "Convert", at: location) { [weak self] ok in
                    if ok { self?.convert(files, option: option) }
                }
            } else {
                convert(files, option: option)
            }
        case .tool(let tool):
            runTool(tool, files: files, at: location)
        case .action(let action):
            FileActions.perform(action, on: files.map(\.url))
        case .more, .back:
            break
        }
    }

    // MARK: - Conversion

    func convert(_ files: [ClassifiedFile], option: ConversionOption) {
        let target = option.target
        let isArchiveBundle = files.count > 1 && target.category == .archive
        let title = isArchiveBundle ? "Creating \(target.label) archive" :
            (files.count == 1 ? "Converting \(files[0].url.lastPathComponent)" : "Converting \(files.count) files to \(target.label)")
        run(title: title, symbol: "arrow.triangle.2.circlepath") { progress in
            if isArchiveBundle {
                return try await ConversionService.archive(files.map(\.url), format: target, progress: progress)
            }
            var outputs: [URL] = []
            var notes: [String] = []
            var failures: [(String, Error)] = []
            for (n, file) in files.enumerated() {
                try Task.checkCancellation()
                let fileOption = files.count == 1 ? option : (ConversionCatalog.shared.option(for: file, target: target.id) ?? option)
                do {
                    let outcome = try await ConversionService.convert(file, option: fileOption) { p in
                        progress((Double(n) + p) / Double(files.count))
                    }
                    outputs += outcome.outputs
                    if let note = outcome.note { notes.append(note) }
                } catch {
                    if error.isCancellation { throw error }
                    failures.append((file.url.lastPathComponent, error))
                }
            }
            if !failures.isEmpty {
                if outputs.isEmpty {
                    if failures.count == 1 { throw failures[0].1 }
                    throw MacFlowError("None of the \(failures.count) files could be converted.", detail: "\(failures[0].0): \(failures[0].1.userMessage)")
                }
                notes.append("\(failures.count) file\(failures.count == 1 ? "" : "s") failed — first: \(failures[0].0): \(failures[0].1.userMessage)")
            }
            return OperationOutcome(outputs: outputs, note: notes.isEmpty ? nil : notes.joined(separator: " · "))
        }
    }

    // MARK: - Tools

    func runTool(_ tool: FileTool, files: [ClassifiedFile], at location: NSPoint) {
        if tool.runsImmediately {
            let request: ToolRequest
            switch tool {
            case .mute: request = .mute
            case .extractAudio: request = .extractAudio
            case .extractText: request = .extractText
            case .extract: request = .extract(password: nil, selection: nil)
            case .testArchive: request = .testArchive
            case .prettyPrint: request = .prettyPrint
            default: request = .minify
            }
            let urls = files.map(\.url)
            run(title: "\(tool.title) — \(files.count == 1 ? urls[0].lastPathComponent : "\(files.count) files")", symbol: tool.sfSymbol) { progress in
                try await ToolRunner.run(request, on: urls, progress: progress)
            }
            return
        }
        toolPanels.present(tool: tool, files: files, at: location) { [weak self] request, context in
            await self?.runFromPanel(request, context: context) ?? false
        }
    }

    /// Runs a panel request. Errors stay in the panel so settings can be
    /// adjusted; success closes the panel and shows the result card.
    private func runFromPanel(_ request: ToolRequest, context: ToolContext) async -> Bool {
        let urls = context.files
        await limiter.acquire()
        defer { Task { await limiter.release() } }
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try await ToolRunner.run(request, on: urls) { p in
                    Task { @MainActor in context.progress = p }
                }
            }.valueCancellable()
            reportSuccess(outcome, id: nil, title: context.tool.title)
            return true
        } catch {
            if error.isCancellation {
                context.error = nil
                return false
            }
            context.error = error.userMessage
            return false
        }
    }

    // MARK: - Running

    private func run(title: String, symbol: String, body: @escaping @Sendable (@escaping ProgressHandler) async throws -> OperationOutcome) {
        let jobID = UUID()
        let hudID = HUDController.shared.begin(title, symbol: symbol) { [weak self] in
            self?.tasks[jobID]?.cancel()
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.limiter.acquire()
            defer { Task { await self.limiter.release() } }
            do {
                let outcome = try await Task.detached(priority: .userInitiated) {
                    try await body { p in
                        Task { @MainActor in HUDController.shared.update(hudID, progress: p) }
                    }
                }.valueCancellable()
                self.reportSuccess(outcome, id: hudID, title: title)
            } catch {
                if error.isCancellation {
                    HUDController.shared.cancelled(hudID)
                } else {
                    let message = error.userMessage
                    HUDController.shared.fail(hudID, title: Self.failureTitle(title), detail: message)
                }
            }
            self.tasks[jobID] = nil
        }
        tasks[jobID] = task
    }

    private func reportSuccess(_ outcome: OperationOutcome, id: UUID?, title: String) {
        if outcome.outputs.isEmpty {
            HUDController.shared.succeed(id, title: outcome.note ?? "Done", detail: nil, outputs: [])
            return
        }
        let names = outcome.outputs.map(\.lastPathComponent)
        let headline = names.count == 1 ? "Saved “\(names[0])”" : "Saved \(names.count) files"
        HUDController.shared.succeed(id, title: headline, detail: outcome.note ?? (names.count > 1 ? names.prefix(3).joined(separator: ", ") : nil), outputs: outcome.outputs)
    }

    private static func failureTitle(_ title: String) -> String {
        if title.hasPrefix("Converting") { return "Conversion failed" }
        if title.hasPrefix("Creating") { return "Archive could not be created" }
        return "\(title.components(separatedBy: " — ").first ?? title) failed"
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }
}

extension Task where Failure == Error {
    /// Awaits the value and forwards cancellation of the awaiting task.
    func valueCancellable() async throws -> Success {
        try await withTaskCancellationHandler {
            try await value
        } onCancel: {
            cancel()
        }
    }
}
