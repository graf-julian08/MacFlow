import Foundation

/// Runs a helper executable with an argument *array* (never a shell string),
/// captures its output, honours Swift task cancellation and enforces a
/// timeout. Used for system tools (bsdtar, ditto) and optional helpers
/// (FFmpeg, cwebp) that were discovered at an absolute path.
enum ProcessRunner {

    struct Result: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: Data

        var stdoutString: String { String(decoding: stdout, as: UTF8.self) }
        var stderrString: String { String(decoding: stderr, as: UTF8.self) }

        /// Last meaningful stderr line, for error messages.
        var errorSummary: String {
            stderrString
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty }) ?? "exit status \(status)"
        }
    }

    /// Runs `executable` and returns its result. Throws only for launch
    /// failures, cancellation and timeouts; a non-zero exit is returned.
    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 3600,
        environment: [String: String]? = nil,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        var env = environment ?? [:]
        // Deterministic, non-interactive helpers.
        env["LC_ALL"] = env["LC_ALL"] ?? "C"
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        process.environment = env
        process.standardInput = FileHandle.nullDevice

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let collector = OutputCollector()
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty { collector.appendOut(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            collector.appendErr(data)
            if let onStderrLine {
                for line in String(decoding: data, as: UTF8.self).split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
                    onStderrLine(String(line))
                }
            }
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                let finished = OnceFlag()
                process.terminationHandler = { proc in
                    guard finished.set() else { return }
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    // Drain whatever is left in the pipes.
                    collector.appendOut(outPipe.fileHandleForReading.readDataToEndOfFile())
                    collector.appendErr(errPipe.fileHandleForReading.readDataToEndOfFile())
                    if collector.timedOut {
                        continuation.resume(throwing: MacFlowError("The helper tool timed out."))
                    } else if collector.cancelled {
                        continuation.resume(throwing: CancellationError())
                    } else {
                        continuation.resume(returning: Result(status: proc.terminationStatus, stdout: collector.out, stderr: collector.err))
                    }
                }
                do {
                    try process.run()
                    collector.process = process
                } catch {
                    guard finished.set() else { return }
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: MacFlowError("Could not start \((executable as NSString).lastPathComponent).", detail: error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if process.isRunning {
                        collector.timedOut = true
                        process.terminate()
                    }
                }
            }
        } onCancel: {
            collector.cancelled = true
            if process.isRunning { process.terminate() }
        }
    }

    /// Convenience: throws a readable error for a non-zero exit status.
    @discardableResult
    static func runChecked(
        _ executable: String,
        _ arguments: [String],
        tool: String,
        currentDirectory: URL? = nil,
        timeout: TimeInterval = 3600,
        onStderrLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let result = try await run(executable, arguments, currentDirectory: currentDirectory, timeout: timeout, onStderrLine: onStderrLine)
        guard result.status == 0 else {
            throw MacFlowError("\(tool) failed.", detail: result.errorSummary)
        }
        return result
    }

    /// Synchronous variant for quick capability probes at launch.
    static func runSync(_ executable: String, _ arguments: [String], timeout: TimeInterval = 10) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        do { try process.run() } catch { return nil }
        let collector = OutputCollector()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            collector.appendOut(out.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        group.enter()
        DispatchQueue.global().async {
            collector.appendErr(err.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }
        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            return nil
        }
        process.waitUntilExit()
        return Result(status: process.terminationStatus, stdout: collector.out, stderr: collector.err)
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func set() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var _out = Data()
    private var _err = Data()
    var process: Process?
    var cancelled = false
    var timedOut = false

    func appendOut(_ d: Data) { lock.lock(); _out.append(d); lock.unlock() }
    func appendErr(_ d: Data) {
        lock.lock()
        _err.append(d)
        // Keep memory bounded for chatty tools such as FFmpeg.
        if _err.count > 256_000 { _err = _err.suffix(128_000) }
        lock.unlock()
    }
    var out: Data { lock.lock(); defer { lock.unlock() }; return _out }
    var err: Data { lock.lock(); defer { lock.unlock() }; return _err }
}
