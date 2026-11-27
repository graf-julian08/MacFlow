import Darwin
import Foundation

/// Transactional output handling.
///
/// Every operation renders into a private work directory on the *same volume*
/// as the destination. Only after the result has been verified is it moved
/// into place with `renamex_np(RENAME_EXCL)`, which is atomic and can never
/// replace an existing file — not even one created by another app a moment
/// earlier. Originals are never opened for writing.
enum OutputPublisher {

    /// Resolves where results for `source` should go, honouring settings and
    /// falling back to the Downloads folder when the source folder is not
    /// writable (read-only volumes, locked folders).
    static func outputDirectory(for source: URL, settings: AppSettings = .shared) -> URL {
        let preferred = settings.outputDirectory(for: source)
        if FileManager.default.isWritableFile(atPath: preferred.path) {
            return preferred
        }
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    /// Creates a private scratch directory on the destination's volume.
    static func makeWorkDirectory(near directory: URL) throws -> URL {
        let fm = FileManager.default
        if let scratch = try? fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: directory, create: true) {
            return scratch
        }
        let fallback = fm.temporaryDirectory.appendingPathComponent("MacFlow-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static func removeWorkDirectory(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// "Name.ext", "Name (2).ext", "Name (3).ext" …  (`ext` may be empty
    /// for folders).
    static func candidateName(base: String, ext: String, attempt: Int) -> String {
        let stem = attempt <= 1 ? base : "\(base) (\(attempt))"
        return ext.isEmpty ? stem : "\(stem).\(ext)"
    }

    /// First free URL for the given name. Advisory only — `publish` performs
    /// the authoritative, race-free reservation.
    static func uniqueURL(in directory: URL, base: String, ext: String) -> URL {
        var attempt = 1
        while true {
            let url = directory.appendingPathComponent(candidateName(base: base, ext: ext, attempt: attempt))
            if !FileManager.default.fileExists(atPath: url.path) { return url }
            attempt += 1
        }
    }

    /// Moves `item` into `directory` as `base.ext`, choosing the next free
    /// numbered name on conflict. Never overwrites anything.
    @discardableResult
    static func publish(_ item: URL, to directory: URL, base: String, ext: String) throws -> URL {
        let safeBase = sanitize(base)
        for attempt in 1...10_000 {
            let target = directory.appendingPathComponent(candidateName(base: safeBase, ext: ext, attempt: attempt))
            let result = item.withUnsafeFileSystemRepresentation { src in
                target.withUnsafeFileSystemRepresentation { dst in
                    renamex_np(src!, dst!, UInt32(RENAME_EXCL))
                }
            }
            if result == 0 {
                // Results of a background tool must be plainly visible.
                try? FileManager.default.setAttributes([.extensionHidden: false], ofItemAtPath: target.path)
                return target
            }
            let code = errno
            if code == EEXIST { continue }
            if code == EXDEV {
                // Different volume: copy to a reserved name, then delete scratch.
                if FileManager.default.fileExists(atPath: target.path) { continue }
                do {
                    try FileManager.default.copyItem(at: item, to: target)
                } catch CocoaError.fileWriteFileExists {
                    continue
                }
                try? FileManager.default.removeItem(at: item)
                return target
            }
            throw MacFlowError("Could not save the result.", detail: String(cString: strerror(code)))
        }
        throw MacFlowError("Could not find a free file name in \(directory.lastPathComponent).")
    }

    /// Removes characters that are invalid or confusing in file names.
    static func sanitize(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix(".") { cleaned = "_" + cleaned.dropFirst() }
        if cleaned.isEmpty { cleaned = "Untitled" }
        // Leave room for " (123).extension" within the 255-byte limit.
        while cleaned.utf8.count > 200 { cleaned.removeLast() }
        return cleaned
    }

    /// Base name of a source file, handling compound extensions.
    static func baseName(of url: URL) -> String {
        let name = url.lastPathComponent
        let lower = name.lowercased()
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst"] where lower.hasSuffix(suffix) {
            return String(name.dropLast(suffix.count))
        }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue,
           url.pathExtension.lowercased() != "rtfd" {
            return name
        }
        return url.deletingPathExtension().lastPathComponent
    }

    /// Free bytes on the volume of `directory`, if known.
    static func availableCapacity(at directory: URL) -> Int64? {
        let values = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    /// Rough check before starting large jobs.
    static func ensureSpace(_ bytes: Int64, at directory: URL) throws {
        guard let free = availableCapacity(at: directory), free > 0 else { return }
        if free < bytes + 50_000_000 {
            let need = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            throw MacFlowError("Not enough free disk space.", detail: "About \(need) is needed.")
        }
    }
}
