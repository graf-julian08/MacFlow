import AppKit
import AVFoundation
import Foundation
import PDFKit

/// Result of one finished operation.
struct OperationOutcome: Sendable {
    var outputs: [URL]
    var note: String?
}

/// Makes sure a file's content is locally available (iCloud, File Provider)
/// and readable before any engine touches it.
enum FileAccess {

    static func prepareForReading(_ url: URL) async throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MacFlowError("“\(url.lastPathComponent)” no longer exists.")
        }
        let keys: Set<URLResourceKey> = [.ubiquitousItemDownloadingStatusKey, .isUbiquitousItemKey]
        if let values = try? url.resourceValues(forKeys: keys), values.isUbiquitousItem == true,
           values.ubiquitousItemDownloadingStatus != .current {
            try? FileManager.default.startDownloadingUbiquitousItem(at: url)
            // Coordinated read waits for the download to complete.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    var coordinationError: NSError?
                    var accessError: Error?
                    NSFileCoordinator(filePresenter: nil).coordinate(readingItemAt: url, options: [], error: &coordinationError) { readURL in
                        if !FileManager.default.isReadableFile(atPath: readURL.path) {
                            accessError = MacFlowError("“\(url.lastPathComponent)” could not be downloaded from iCloud.")
                        }
                    }
                    if let error = coordinationError ?? accessError as NSError? {
                        continuation.resume(throwing: MacFlowError("“\(url.lastPathComponent)” is not available offline.", detail: error.localizedDescription))
                    } else {
                        continuation.resume()
                    }
                }
            }
        }
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if !isDir.boolValue && !FileManager.default.isReadableFile(atPath: url.path) {
            throw MacFlowError("MacFlow has no permission to read “\(url.lastPathComponent)”.",
                               detail: "Grant access in System Settings → Privacy & Security → Files and Folders.")
        }
    }
}

/// Runs a conversion transactionally:
/// work folder → engine → independent validation → atomic publish.
enum ConversionService {

    static func convert(_ file: ClassifiedFile, option: ConversionOption, progress: @escaping ProgressHandler) async throws -> OperationOutcome {
        guard let sourceFormat = file.format else { throw MacFlowError("The file type could not be identified.") }
        try await FileAccess.prepareForReading(file.url)
        let settings = AppSettings.shared
        let outputDir = OutputPublisher.outputDirectory(for: file.url)
        let work = try OutputPublisher.makeWorkDirectory(near: outputDir)
        defer { OutputPublisher.removeWorkDirectory(work) }

        let base = OutputPublisher.sanitize(OutputPublisher.baseName(of: file.url))
        let target = option.target
        let ext = target.outputExtension
        let temp = work.appendingPathComponent("\(base).\(ext)")
        var expectation = ValidationExpectation.none
        var note: String?
        var produced = temp

        let inputSize = (try? file.url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        try OutputPublisher.ensureSpace(inputSize, at: outputDir)

        switch option.engine {
        case .image:
            let info = FileInspection.inspect(file)
            if target.id == "pdf" && sourceFormat.id == "tiff" { expectation.pages = info.frameCount }
            if (target.id == "gif" || target.id == "png") && info.frameCount > 1 && sourceFormat.supportsAnimation {
                expectation.frames = info.frameCount
            }
            try await ImageEngine.convert(source: file.url, sourceFormat: sourceFormat, target: target, destination: temp,
                                          quality: settings.defaultImageQuality, preserveMetadata: settings.preserveMetadata)
            progress(1)

        case .pdfRender:
            let doc = try PDFEngine.open(file.url)
            produced = try await PDFEngine.renderToImages(file.url, target: target, workDir: work, baseName: base,
                                                         quality: settings.defaultImageQuality, progress: progress)
            if target.id == "tiff" { expectation.frames = doc.pageCount } else if doc.pageCount > 1 { expectation.pages = doc.pageCount }

        case .pdfText:
            let doc = try PDFEngine.open(file.url)
            let hasText = !PDFEngine.plainText(doc).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasText {
                switch target.id {
                case "txt": try DocumentEngine.write(PDFEngine.plainText(doc) + "\n", to: temp)
                case "md": try DocumentEngine.write(PDFEngine.markdown(doc), to: temp)
                default: try await DocumentEngine.write(PDFEngine.attributedText(doc), as: target, to: temp, title: base)
                }
            } else {
                // Scanned PDF: recognise the text on-device.
                let text = try await PDFTools.recognizedText(doc, progress: progress)
                if target.id == "txt" {
                    try DocumentEngine.write(text + "\n", to: temp)
                } else {
                    let attributed = NSAttributedString(string: text, attributes: DocumentEngine.baseAttributes)
                    try await DocumentEngine.write(attributed, as: target, to: temp, title: base)
                }
                note = "Text recognised with OCR — please check it."
            }
            expectation.requireText = true
            progress(1)

        case .document:
            try await DocumentEngine.convert(source: file.url, sourceFormat: sourceFormat, target: target, destination: temp)
            let sourceHasText = ((try? Data(contentsOf: file.url, options: .mappedIfSafe).count) ?? 0) > 0
            expectation.requireText = sourceHasText && target.id != "pdf"
            progress(1)

        case .structuredData:
            try DataEngine.convertStructured(source: file.url, sourceFormat: sourceFormat, target: target, destination: temp)
            progress(1)

        case .spreadsheet:
            produced = try await DataEngine.convertSpreadsheet(source: file.url, sourceFormat: sourceFormat, target: target, workDir: work, baseName: base)
            progress(1)

        case .subtitle:
            let cues = try SubtitleEngine.parse(try DocumentEngine.readText(file.url), format: sourceFormat.id)
            try DocumentEngine.write(try SubtitleEngine.serialize(cues, as: target.id), to: temp)
            if target.category == .subtitle { expectation.cues = cues.count }
            progress(1)

        case .media:
            let info = try? await MediaEngine.info(file.url)
            note = try await MediaEngine.convert(source: file.url, sourceFormat: sourceFormat, target: target, destination: temp, progress: progress)
            if let d = info?.duration, d > 0, target.id != "gif" { expectation.minimumDuration = d * 0.98 }

        case .archive:
            if sourceFormat.category == .folder {
                try await ArchiveEngine.create([file.url], format: target, destination: temp)
            } else {
                try await ArchiveEngine.repack(file.url, to: target, destination: temp, workDir: work)
            }
            progress(1)
        }

        try Task.checkCancellation()
        try await IntegrityValidator.validate(produced, as: target, expecting: expectation)
        try Task.checkCancellation()

        let isFolder = (try? produced.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && target.id != "rtfd"
        let published: URL
        if isFolder {
            published = try OutputPublisher.publish(produced, to: outputDir, base: "\(base) (\(target.label))", ext: "")
        } else {
            published = try OutputPublisher.publish(produced, to: outputDir, base: base, ext: ext)
        }
        return OperationOutcome(outputs: [published], note: note)
    }

    /// Bundles several items into one archive next to the first item.
    static func archive(_ items: [URL], format: FileFormat, progress: @escaping ProgressHandler) async throws -> OperationOutcome {
        guard let first = items.first else { throw MacFlowError("Nothing to archive.") }
        for item in items { try await FileAccess.prepareForReading(item) }
        let outputDir = OutputPublisher.outputDirectory(for: first)
        let work = try OutputPublisher.makeWorkDirectory(near: outputDir)
        defer { OutputPublisher.removeWorkDirectory(work) }
        let base = items.count == 1 ? OutputPublisher.baseName(of: first) : "Archive"
        let temp = work.appendingPathComponent("\(OutputPublisher.sanitize(base)).\(format.outputExtension)")
        try await ArchiveEngine.create(items, format: format, destination: temp)
        progress(1)
        try await IntegrityValidator.validate(temp, as: format)
        let published = try OutputPublisher.publish(temp, to: outputDir, base: OutputPublisher.sanitize(base), ext: format.outputExtension)
        return OperationOutcome(outputs: [published], note: nil)
    }
}
