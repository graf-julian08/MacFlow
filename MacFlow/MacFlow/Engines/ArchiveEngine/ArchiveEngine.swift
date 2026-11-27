import Foundation

/// Archive handling via macOS's own `bsdtar` (libarchive).
///
/// Safety rules for extraction:
/// * Entries with absolute paths or `..` components are refused (bsdtar
///   default without `-P`), extraction never writes through symlinks.
/// * Symlinks pointing outside the extraction folder are removed afterwards.
/// * The declared uncompressed size is checked first (zip-bomb guard and
///   free-space check); entry count is capped.
/// * Nothing extracted is ever opened or executed.
enum ArchiveEngine {

    struct Entry: Hashable {
        let path: String
        let size: Int64
        let isDirectory: Bool
        let isSymlink: Bool
    }

    static let maxEntries = 250_000
    static let bombRatio: Int64 = 100
    static let bombMinimum: Int64 = 1_000_000_000

    private static func tool() throws -> String {
        guard let path = EngineCapabilities.shared.bsdtarPath else { throw MacFlowError("bsdtar is missing from this Mac.") }
        return path
    }

    // MARK: - Listing

    static func list(_ archive: URL, passphrase: String? = nil) async throws -> [Entry] {
        var args = ["-t", "-v", "-f", archive.path]
        if let passphrase { args += ["--passphrase", passphrase] }
        let result = try await ProcessRunner.run(try tool(), args, timeout: 600)
        guard result.status == 0 else {
            throw describe(result, archive: archive)
        }
        var entries: [Entry] = []
        let pattern = try NSRegularExpression(pattern: #"^(\S+)\s+\d+\s+\S+\s+\S+\s+(\d+)\s+\w{3}\s+\d+\s+[\d:]+\s+(.*)$"#)
        for line in result.stdoutString.split(separator: "\n", omittingEmptySubsequences: true) {
            let s = String(line)
            let ns = s as NSString
            guard let m = pattern.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { continue }
            let mode = ns.substring(with: m.range(at: 1))
            let size = Int64(ns.substring(with: m.range(at: 2))) ?? 0
            var name = ns.substring(with: m.range(at: 3))
            let isLink = mode.hasPrefix("l")
            if isLink, let arrow = name.range(of: " -> ") { name = String(name[..<arrow.lowerBound]) }
            if mode.hasPrefix("h"), let arrow = name.range(of: " link to ") { name = String(name[..<arrow.lowerBound]) }
            entries.append(Entry(path: name, size: size, isDirectory: mode.hasPrefix("d") || name.hasSuffix("/"), isSymlink: isLink))
            if entries.count > maxEntries { throw MacFlowError("The archive contains too many items to be handled safely.") }
        }
        return entries
    }

    private static func describe(_ result: ProcessRunner.Result, archive: URL) -> MacFlowError {
        let message = result.stderrString.lowercased()
        if message.contains("passphrase") || message.contains("encrypted") || message.contains("password") {
            return MacFlowError("“\(archive.lastPathComponent)” is encrypted.", detail: "Open File Tools → Extract and enter its password.")
        }
        if message.contains("unrecognized archive format") || message.contains("damaged") || message.contains("truncated") {
            return MacFlowError("“\(archive.lastPathComponent)” is damaged or not a supported archive.", detail: result.errorSummary)
        }
        return MacFlowError("The archive could not be read.", detail: result.errorSummary)
    }

    // MARK: - Extraction

    /// Extracts into a new folder inside `workDir`. Returns the folder that
    /// should be published (a lone top-level folder is used directly).
    static func extract(_ archive: URL, into workDir: URL, baseName: String, passphrase: String? = nil,
                        only selection: [String]? = nil, progress: ProgressHandler? = nil) async throws -> URL {
        let root = try await extractToRoot(archive, into: workDir, passphrase: passphrase, only: selection)
        progress?(1)
        let top = try topLevelItems(root)
        guard !top.isEmpty else { throw MacFlowError("Nothing was extracted.") }
        if top.count == 1, (try? top[0].resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            return top[0]
        }
        let named = workDir.appendingPathComponent(OutputPublisher.sanitize(baseName), isDirectory: true)
        try FileManager.default.moveItem(at: root, to: named)
        return named
    }

    static func topLevelItems(_ root: URL) throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [])
        for junk in all where junk.lastPathComponent == "__MACOSX" { try? FileManager.default.removeItem(at: junk) }
        return all.filter { $0.lastPathComponent != "__MACOSX" && $0.lastPathComponent != ".DS_Store" }
    }

    /// Safe extraction into a fresh folder; returns that folder.
    static func extractToRoot(_ archive: URL, into workDir: URL, passphrase: String? = nil, only selection: [String]? = nil) async throws -> URL {
        let entries = try await list(archive, passphrase: passphrase)
        guard !entries.isEmpty else { throw MacFlowError("The archive is empty.") }
        let declared = entries.reduce(Int64(0)) { $0 + max(0, $1.size) }
        let archiveSize = (try? archive.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if declared > bombMinimum && archiveSize > 0 && declared / max(archiveSize, 1) > bombRatio {
            let size = ByteCountFormatter.string(fromByteCount: declared, countStyle: .file)
            throw MacFlowError("Extraction stopped for safety.", detail: "The archive would expand to \(size), over \(bombRatio)× its own size.")
        }
        try OutputPublisher.ensureSpace(declared, at: workDir)

        let root = workDir.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var args = ["-x", "-f", archive.path, "-C", root.path, "--no-same-owner", "--no-same-permissions"]
        if let passphrase { args += ["--passphrase", passphrase] }
        if let selection, !selection.isEmpty { args += ["--"] + selection }
        let result = try await ProcessRunner.run(try tool(), args, timeout: 6 * 3600)
        if result.status != 0 {
            throw describe(result, archive: archive)
        }
        try removeEscapingSymlinks(in: root)
        return root
    }

    /// Deletes symlinks whose target resolves outside `root`.
    static func removeEscapingSymlinks(in root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: []) else { return }
        for case let url as URL in enumerator {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true else { continue }
            let destination = (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? ""
            let resolved: String
            if destination.hasPrefix("/") {
                resolved = URL(fileURLWithPath: destination).standardizedFileURL.path
            } else {
                resolved = url.deletingLastPathComponent().appendingPathComponent(destination).standardizedFileURL.path
            }
            if !(resolved == rootPath || resolved.hasPrefix(rootPath + "/")) {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Creation

    static func formatArguments(_ id: String) throws -> [String] {
        switch id {
        case "zip": return ["--format", "zip", "--options", "zip:compression=deflate"]
        case "7z": return ["--format", "7zip"]
        case "tar": return ["--format", "pax"]
        case "tgz": return ["--format", "pax", "-z"]
        case "tbz2": return ["--format", "pax", "-j"]
        case "txz": return ["--format", "pax", "-J"]
        default: throw MacFlowError.unsupported("Writing \(id.uppercased()) archives")
        }
    }

    /// Creates an archive from items, keeping each item's name at the top level.
    static func create(_ items: [URL], format: FileFormat, destination: URL) async throws {
        var args = ["-c", "-f", destination.path] + (try formatArguments(format.id))
        args += ["--no-mac-metadata", "--exclude", ".DS_Store"]
        for item in items {
            args += ["-C", item.deletingLastPathComponent().path, item.lastPathComponent]
        }
        try await ProcessRunner.runChecked(try tool(), args, tool: "Archiving", timeout: 6 * 3600)
    }

    /// Re-packs an archive into another format via a safe extraction,
    /// keeping the original top-level layout.
    static func repack(_ archive: URL, to format: FileFormat, destination: URL, workDir: URL) async throws {
        let root = try await extractToRoot(archive, into: workDir)
        let items = try topLevelItems(root)
        guard !items.isEmpty else { throw MacFlowError("The archive is empty.") }
        try await create(items, format: format, destination: destination)
    }

    /// Full read test: decompresses every entry into a scratch folder.
    static func test(_ archive: URL, workDir: URL, passphrase: String? = nil) async throws -> Int {
        let entries = try await list(archive, passphrase: passphrase)
        let root = workDir.appendingPathComponent("test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var args = ["-x", "-f", archive.path, "-C", root.path, "--no-same-owner"]
        if let passphrase { args += ["--passphrase", passphrase] }
        let result = try await ProcessRunner.run(try tool(), args, timeout: 6 * 3600)
        guard result.status == 0 else { throw describe(result, archive: archive) }
        return entries.filter { !$0.isDirectory }.count
    }
}
