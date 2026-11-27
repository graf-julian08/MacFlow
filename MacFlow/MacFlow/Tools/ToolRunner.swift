import AVFoundation
import Foundation
import ImageIO
import PDFKit

/// A fully configured tool invocation produced by a tool panel (or directly
/// for tools without settings).
enum ToolRequest: Sendable {
    case compress(CompressSettings)
    case resize(ResizeSettings?, percent: Double?)
    case crop(CGRect)
    case rotate(RotateSettings)
    case adjust(AdjustSettings)
    case background(BackgroundSettings)
    case redact(RedactSettings)
    case removeBackground
    case annotate([Annotation])
    case makePDF(MakePDFSettings)
    case metadata(MetadataEdit)
    case videoCompress(VideoCompressSettings)
    case trim(start: Double, end: Double)
    case videoRotate(Int)
    case mute
    case extractAudio
    case snapshot(seconds: Double, formatID: String)
    case speed(Double, keepPitch: Bool)
    case audioTrim(start: Double, end: Double)
    case volume(gainDB: Double, normalize: Bool)
    case fade(fadeIn: Double, fadeOut: Double)
    case channels(ChannelMode)
    case pdfCompress(PDFCompressLevel)
    case pages([PageItem])
    case pdfMetadata(PDFMetadataEdit)
    case protect(ProtectSettings)
    case watermark(WatermarkSettings)
    case pageNumbers(PageNumberSettings)
    case ocr(OCROutput)
    case split(SplitMode)
    case merge([URL])
    case extractText
    case extract(password: String?, selection: [String]?)
    case testArchive
    case prettyPrint
    case minify
    case shiftTiming(milliseconds: Int)

    /// Suffix for the new file name ("photo-cropped.jpg").
    var suffix: String {
        switch self {
        case .compress, .videoCompress, .pdfCompress: return "compressed"
        case .resize: return "resized"
        case .crop: return "cropped"
        case .rotate, .videoRotate: return "rotated"
        case .adjust: return "edited"
        case .background: return "background"
        case .redact: return "redacted"
        case .removeBackground: return "cutout"
        case .annotate: return "annotated"
        case .makePDF, .merge: return ""
        case .metadata, .pdfMetadata: return "metadata"
        case .trim, .audioTrim: return "trimmed"
        case .mute: return "muted"
        case .extractAudio: return ""
        case .snapshot: return "snapshot"
        case .speed: return "speed"
        case .volume: return "volume"
        case .fade: return "faded"
        case .channels: return "channels"
        case .pages: return "pages"
        case .protect: return "protected"
        case .watermark: return "watermarked"
        case .pageNumbers: return "numbered"
        case .ocr: return "ocr"
        case .split, .extract, .testArchive: return ""
        case .extractText: return ""
        case .prettyPrint: return "formatted"
        case .minify: return "min"
        case .shiftTiming: return "shifted"
        }
    }
}

/// Runs tool requests transactionally: work folder → processing →
/// independent validation → atomic publish next to the original.
enum ToolRunner {

    static func run(_ request: ToolRequest, on files: [URL], progress: @escaping ProgressHandler) async throws -> OperationOutcome {
        switch request {
        case .makePDF(let settings):
            return try await combined(files: settings.order.isEmpty ? files : settings.order, name: "Images", ext: "pdf", format: FormatRegistry.shared["pdf"]) { dest in
                try await ImageTools.makePDF(MakePDFSettings(order: settings.order.isEmpty ? files : settings.order, pageSize: settings.pageSize, margin: settings.margin, jpegQuality: settings.jpegQuality), destination: dest)
                return ValidationExpectation(pages: settings.order.isEmpty ? files.count : settings.order.count)
            }
        case .merge(let order):
            let urls = order.isEmpty ? files : order
            return try await combined(files: urls, name: "Merged", ext: "pdf", format: FormatRegistry.shared["pdf"]) { dest in
                let pages = try PDFTools.merge(urls, destination: dest)
                return ValidationExpectation(pages: pages)
            }
        default:
            var outputs: [URL] = []
            var notes: [String] = []
            for (n, file) in files.enumerated() {
                try Task.checkCancellation()
                let share = 1.0 / Double(files.count)
                let outcome = try await runSingle(request, file: file) { progress((Double(n) + $0) * share) }
                outputs += outcome.outputs
                if let note = outcome.note { notes.append(note) }
            }
            return OperationOutcome(outputs: outputs, note: notes.isEmpty ? nil : notes.joined(separator: "\n"))
        }
    }

    // MARK: - Helpers

    private struct Context {
        let source: URL
        let format: FileFormat
        let base: String
        let outputDir: URL
        let work: URL
    }

    private static func combined(files: [URL], name: String, ext: String, format: FileFormat,
                                 body: (URL) async throws -> ValidationExpectation) async throws -> OperationOutcome {
        guard let first = files.first else { throw MacFlowError("No files were dropped.") }
        for f in files { try await FileAccess.prepareForReading(f) }
        let outputDir = OutputPublisher.outputDirectory(for: first)
        let work = try OutputPublisher.makeWorkDirectory(near: outputDir)
        defer { OutputPublisher.removeWorkDirectory(work) }
        let base = files.count == 1 ? OutputPublisher.baseName(of: first) : name
        let dest = work.appendingPathComponent("result.\(ext)")
        let expectation = try await body(dest)
        try await IntegrityValidator.validate(dest, as: format, expecting: expectation)
        let url = try OutputPublisher.publish(dest, to: outputDir, base: OutputPublisher.sanitize(base), ext: ext)
        return OperationOutcome(outputs: [url], note: nil)
    }

    private static func publishFile(_ produced: URL, ctx: Context, suffix: String, format: FileFormat, ext: String? = nil,
                                    expectation: ValidationExpectation = .none) async throws -> URL {
        try Task.checkCancellation()
        try await IntegrityValidator.validate(produced, as: format, expecting: expectation)
        let base = suffix.isEmpty ? ctx.base : "\(ctx.base)-\(suffix)"
        return try OutputPublisher.publish(produced, to: ctx.outputDir, base: base, ext: ext ?? format.outputExtension)
    }

    private static func runSingle(_ request: ToolRequest, file: URL, progress: @escaping ProgressHandler) async throws -> OperationOutcome {
        try await FileAccess.prepareForReading(file)
        let classified = FileClassifier.shared.classify(file)
        guard let format = classified.format else { throw MacFlowError("The file type of “\(file.lastPathComponent)” could not be identified.") }
        let outputDir = OutputPublisher.outputDirectory(for: file)
        let work = try OutputPublisher.makeWorkDirectory(near: outputDir)
        defer { OutputPublisher.removeWorkDirectory(work) }
        let ctx = Context(source: file, format: format, base: OutputPublisher.sanitize(OutputPublisher.baseName(of: file)), outputDir: outputDir, work: work)
        let quality = AppSettings.shared.defaultImageQuality
        let hasAlpha = FileInspection.inspect(classified).hasAlpha
        let imageOut = ImageToolOutput.format(for: format, hasAlpha: hasAlpha)
        func temp(_ f: FileFormat) -> URL { work.appendingPathComponent("result.\(f.outputExtension)") }
        func single(_ url: URL, note: String? = nil) -> OperationOutcome { OperationOutcome(outputs: [url], note: note) }

        switch request {
        // MARK: Image
        case .compress(let settings):
            let out = ImageTools.compressOutputFormat(sourceFormat: format, settings: settings)
            let dest = temp(out)
            let result = try await ImageTools.compress(source: file, sourceFormat: format, settings: settings, destination: dest)
            let before = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let note = before > 0 ? "\(ByteCountFormatter.string(fromByteCount: before, countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)) (−\(max(0, Int((1 - Double(result.bytes) / Double(before)) * 100)))%)" : nil
            return single(try await publishFile(dest, ctx: ctx, suffix: "compressed", format: out), note: note)

        case .resize(let size, let percent):
            let dest = temp(imageOut)
            var expected: CGSize?
            try await ImageTools.process(source: file, to: dest, output: imageOut, quality: quality) { image in
                let w: Int, h: Int
                if let size { w = size.width; h = size.height } else {
                    let p = (percent ?? 50) / 100
                    w = max(1, Int((Double(image.width) * p).rounded())); h = max(1, Int((Double(image.height) * p).rounded()))
                }
                guard w <= 30_000, h <= 30_000 else { throw MacFlowError("The new size is too large.") }
                expected = CGSize(width: w, height: h)
                return try ImageEngine.resize(image, width: w, height: h)
            }
            return single(try await publishFile(dest, ctx: ctx, suffix: "resized", format: imageOut, expectation: ValidationExpectation(pixelSize: expected)))

        case .crop(let rect):
            let dest = temp(imageOut)
            try await ImageTools.process(source: file, to: dest, output: imageOut, quality: quality) { try ImageTools.crop($0, normalized: rect) }
            return single(try await publishFile(dest, ctx: ctx, suffix: "cropped", format: imageOut))

        case .rotate(let settings):
            guard !settings.isIdentity else { throw MacFlowError("Choose a rotation or flip first.") }
            let dest = temp(imageOut)
            if (format.id == "jpg" || format.id == "heic") && imageOut == format {
                try ImageTools.rotateLosslessly(source: file, settings: settings, destination: dest, format: format)
                guard ImageTools.pixelsIdentical(file, dest) else {
                    throw MacFlowError.validation("Lossless rotation changed the image data.")
                }
                return single(try await publishFile(dest, ctx: ctx, suffix: "rotated", format: imageOut), note: "Rotated losslessly")
            }
            try await ImageTools.process(source: file, to: dest, output: imageOut, quality: quality) { try ImageTools.rotate($0, settings) }
            return single(try await publishFile(dest, ctx: ctx, suffix: "rotated", format: imageOut))

        case .adjust(let settings):
            guard !settings.isNeutral else { throw MacFlowError("No adjustments were made.") }
            let dest = temp(imageOut)
            try await ImageTools.process(source: file, to: dest, output: imageOut, quality: quality) { try ImageTools.adjust($0, settings) }
            return single(try await publishFile(dest, ctx: ctx, suffix: "edited", format: imageOut))

        case .background(let settings):
            // The result is opaque: keep the format unless it is GIF.
            let out = imageOut.id == "gif" ? FormatRegistry.shared["png"] : imageOut
            let dest = temp(out)
            try await ImageTools.process(source: file, to: dest, output: out, quality: quality) { try ImageTools.addBackground($0, settings) }
            return single(try await publishFile(dest, ctx: ctx, suffix: "background", format: out))

        case .redact(let settings):
            let dest = temp(imageOut)
            // Redaction never carries metadata (it could contain what was hidden).
            try await ImageTools.process(source: file, to: dest, output: imageOut, quality: quality, keepMetadata: false) { try ImageTools.redact($0, settings) }
            return single(try await publishFile(dest, ctx: ctx, suffix: "redacted", format: imageOut), note: "Metadata removed")

        case .removeBackground:
            let png = FormatRegistry.shared["png"]
            let dest = temp(png)
            try await ImageTools.process(source: file, to: dest, output: png, quality: 1) { try ImageTools.removeBackground($0) }
            return single(try await publishFile(dest, ctx: ctx, suffix: "cutout", format: png))

        case .annotate(let items):
            guard !items.isEmpty else { throw MacFlowError("Add at least one annotation.") }
            let dest = temp(imageOut)
            try await ImageTools.process(source: file, to: dest, output: imageOut, quality: quality) { try ImageTools.annotate($0, items) }
            return single(try await publishFile(dest, ctx: ctx, suffix: "annotated", format: imageOut))

        case .metadata(let edit):
            let dest = temp(format)
            try ImageTools.writeMetadata(source: file, edit: edit, destination: dest)
            guard ImageTools.pixelsIdentical(file, dest) else {
                throw MacFlowError.validation("The image data changed while editing metadata.")
            }
            return single(try await publishFile(dest, ctx: ctx, suffix: "metadata", format: format), note: "Image data untouched")

        // MARK: Video
        case .videoCompress(let settings):
            let (type, out) = VideoTools.outputType(for: format)
            let dest = temp(out)
            try await VideoTools.compress(source: file, settings: settings, destination: dest, fileType: type, progress: progress)
            let before = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let after = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            if after >= before {
                throw MacFlowError("The video is already smaller than these settings produce.", detail: "Choose a lower quality or resolution.")
            }
            let info = try await MediaEngine.info(file)
            let url = try await publishFile(dest, ctx: ctx, suffix: "compressed", format: out, expectation: ValidationExpectation(minimumDuration: info.duration * 0.98))
            return single(url, note: "\(ByteCountFormatter.string(fromByteCount: before, countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: after, countStyle: .file))")

        case .trim(let start, let end):
            let (type, out) = VideoTools.outputType(for: format)
            let dest = temp(out)
            try await VideoTools.trim(source: file, start: start, end: end, destination: dest, type: type, progress: progress)
            return single(try await publishFile(dest, ctx: ctx, suffix: "trimmed", format: out, expectation: ValidationExpectation(minimumDuration: (end - start) * 0.95)))

        case .videoRotate(let turns):
            let (type, out) = VideoTools.outputType(for: format)
            let dest = temp(out)
            try await VideoTools.rotate(source: file, quarterTurns: turns, destination: dest, type: type, progress: progress)
            return single(try await publishFile(dest, ctx: ctx, suffix: "rotated", format: out), note: "Rotated without re-encoding")

        case .mute:
            let (type, out) = VideoTools.outputType(for: format)
            let dest = temp(out)
            try await VideoTools.mute(source: file, destination: dest, type: type, progress: progress)
            return single(try await publishFile(dest, ctx: ctx, suffix: "muted", format: out))

        case .extractAudio:
            let m4a = FormatRegistry.shared["m4a"]
            let dest = temp(m4a)
            try await MediaEngine.extractAudioM4A(source: file, destination: dest, progress: progress)
            return single(try await publishFile(dest, ctx: ctx, suffix: "", format: m4a))

        case .snapshot(let seconds, let formatID):
            let out = FormatRegistry.shared.format(for: formatID) ?? FormatRegistry.shared["png"]
            let image = try await VideoTools.snapshot(source: file, at: seconds)
            let dest = temp(out)
            try ImageEngine.write([ImageEngine.Frame(image: image, properties: [:])], to: dest, format: out, quality: quality)
            let stamp = String(format: "%02d.%02d", Int(seconds) / 60, Int(seconds) % 60)
            return single(try await publishFile(dest, ctx: ctx, suffix: "frame \(stamp)", format: out))

        case .speed(let factor, let keepPitch):
            let (type, out) = VideoTools.outputType(for: format)
            let dest = temp(out)
            try await VideoTools.speed(source: file, factor: factor, keepPitch: keepPitch, destination: dest, type: type, progress: progress)
            let label = factor == factor.rounded() ? "\(Int(factor))x" : String(format: "%.2gx", factor)
            return single(try await publishFile(dest, ctx: ctx, suffix: label, format: out))

        // MARK: Audio
        case .audioTrim(let start, let end):
            let out = AudioTools.outputFormat(for: format)
            let dest = temp(out)
            let range = try AudioTools.frameRange(file, start: start, end: end)
            try await AudioTools.process(source: file, output: out, destination: dest, progress: progress, range: range)
            return single(try await publishFile(dest, ctx: ctx, suffix: "trimmed", format: out, expectation: ValidationExpectation(minimumDuration: (end - start) * 0.97)))

        case .volume(let gainDB, let normalize):
            let out = AudioTools.outputFormat(for: format)
            let dest = temp(out)
            var gain = Float(pow(10, gainDB / 20))
            if normalize {
                let peak = try AudioTools.peak(file)
                guard peak > 0.0001 else { throw MacFlowError("The audio is silent.") }
                gain = Float(pow(10, -1.0 / 20)) / peak
            }
            guard abs(gain - 1) > 0.001 else { throw MacFlowError("The volume would not change.") }
            try await AudioTools.process(source: file, output: out, destination: dest, progress: progress, transform: AudioTools.gainTransform(gain))
            return single(try await publishFile(dest, ctx: ctx, suffix: normalize ? "normalized" : "volume", format: out))

        case .fade(let fadeIn, let fadeOut):
            guard fadeIn > 0 || fadeOut > 0 else { throw MacFlowError("Set a fade-in or fade-out length.") }
            let out = AudioTools.outputFormat(for: format)
            let dest = temp(out)
            let input = try AVAudioFile(forReading: file)
            let transform = AudioTools.fadeTransform(fadeIn: fadeIn, fadeOut: fadeOut, totalFrames: input.length, sampleRate: input.processingFormat.sampleRate)
            try await AudioTools.process(source: file, output: out, destination: dest, progress: progress, transform: transform)
            return single(try await publishFile(dest, ctx: ctx, suffix: "faded", format: out))

        case .channels(let mode):
            let out = AudioTools.outputFormat(for: format)
            let dest = temp(out)
            try await AudioTools.channels(source: file, mode: mode, output: out, destination: dest, progress: progress)
            return single(try await publishFile(dest, ctx: ctx, suffix: mode.rawValue.lowercased(), format: out))

        // MARK: PDF
        case .pdfCompress(let level):
            let pdf = FormatRegistry.shared["pdf"]
            let dest = temp(pdf)
            try PDFTools.compress(file, level: level, destination: dest)
            let before = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            let after = (try? dest.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            return single(try await publishFile(dest, ctx: ctx, suffix: "compressed", format: pdf, expectation: ValidationExpectation(pages: PDFTools.pageCount(file))),
                          note: "\(ByteCountFormatter.string(fromByteCount: before, countStyle: .file)) → \(ByteCountFormatter.string(fromByteCount: after, countStyle: .file))")

        case .pages(let items):
            let pdf = FormatRegistry.shared["pdf"]
            let dest = temp(pdf)
            try PDFTools.organize(file, pages: items, destination: dest)
            return single(try await publishFile(dest, ctx: ctx, suffix: "pages", format: pdf, expectation: ValidationExpectation(pages: items.count)))

        case .pdfMetadata(let edit):
            let pdf = FormatRegistry.shared["pdf"]
            let dest = temp(pdf)
            try PDFTools.writeMetadata(file, edit: edit, destination: dest)
            return single(try await publishFile(dest, ctx: ctx, suffix: "metadata", format: pdf, expectation: ValidationExpectation(pages: PDFTools.pageCount(file))))

        case .protect(let settings):
            let pdf = FormatRegistry.shared["pdf"]
            let dest = temp(pdf)
            try PDFTools.protect(file, settings: settings, destination: dest)
            let removing = !settings.removeWithPassword.isEmpty
            if !removing {
                guard let check = PDFDocument(url: dest), check.isEncrypted, check.isLocked, check.unlock(withPassword: settings.password) else {
                    throw MacFlowError.validation("The password protection could not be verified.")
                }
            } else {
                try await IntegrityValidator.validate(dest, as: pdf)
            }
            let base = "\(ctx.base)-\(removing ? "unlocked" : "protected")"
            return single(try OutputPublisher.publish(dest, to: ctx.outputDir, base: base, ext: "pdf"))

        case .watermark(let settings):
            let pdf = FormatRegistry.shared["pdf"]
            let dest = temp(pdf)
            try PDFTools.watermark(file, settings: settings, destination: dest)
            return single(try await publishFile(dest, ctx: ctx, suffix: "watermarked", format: pdf, expectation: ValidationExpectation(pages: PDFTools.pageCount(file))))

        case .pageNumbers(let settings):
            let pdf = FormatRegistry.shared["pdf"]
            let dest = temp(pdf)
            try PDFTools.pageNumbers(file, settings: settings, destination: dest)
            return single(try await publishFile(dest, ctx: ctx, suffix: "numbered", format: pdf, expectation: ValidationExpectation(pages: PDFTools.pageCount(file))))

        case .ocr(let output):
            let out = output == .text ? FormatRegistry.shared["txt"] : FormatRegistry.shared["pdf"]
            let dest = temp(out)
            try await PDFTools.ocr(file, output: output, destination: dest, progress: progress)
            var e = ValidationExpectation(requireText: true)
            if output == .searchablePDF { e.pages = PDFTools.pageCount(file) }
            return single(try await publishFile(dest, ctx: ctx, suffix: "ocr", format: out, expectation: e))

        case .split(let mode):
            let folder = work.appendingPathComponent("split", isDirectory: true)
            let count = try PDFTools.split(file, mode: mode, into: folder, baseName: ctx.base)
            try await IntegrityValidator.validate(folder, as: FormatRegistry.shared["pdf"], expecting: ValidationExpectation(pages: count))
            return single(try OutputPublisher.publish(folder, to: outputDir, base: "\(ctx.base) (Split)", ext: ""), note: "\(count) PDFs")

        case .extractText:
            let txt = FormatRegistry.shared["txt"]
            let dest = temp(txt)
            let doc = try PDFEngine.open(file)
            try DocumentEngine.write(try PDFEngine.requireText(doc, name: file.lastPathComponent) + "\n", to: dest)
            return single(try await publishFile(dest, ctx: ctx, suffix: "", format: txt, expectation: ValidationExpectation(requireText: true)))

        case .makePDF, .merge:
            preconditionFailure("handled in run(_:on:)")

        // MARK: Archives
        case .extract(let password, let selection):
            let folder = try await ArchiveEngine.extract(file, into: work, baseName: ctx.base, passphrase: password, only: selection, progress: progress)
            let items = (try? FileManager.default.contentsOfDirectory(atPath: folder.path).count) ?? 0
            guard items > 0 else { throw MacFlowError.validation("Nothing was extracted.") }
            return single(try OutputPublisher.publish(folder, to: outputDir, base: OutputPublisher.sanitize(folder.lastPathComponent.hasPrefix("extract-") ? ctx.base : folder.lastPathComponent), ext: ""))

        case .testArchive:
            let count = try await ArchiveEngine.test(file, workDir: work)
            return OperationOutcome(outputs: [], note: "“\(file.lastPathComponent)” is intact — \(count) file\(count == 1 ? "" : "s") verified.")

        // MARK: Data & subtitles
        case .prettyPrint, .minify:
            let value = try DataEngine.read(file, format: format)
            let dest = temp(format)
            if case .minify = request {
                try DocumentEngine.write(JSONCodec.serialize(value, pretty: false), to: dest)
            } else {
                try DocumentEngine.write(JSONCodec.serialize(value, pretty: true), to: dest)
            }
            let reparsed = try JSONCodec.parse(try DocumentEngine.readText(dest))
            guard reparsed == value else { throw MacFlowError.validation("The formatted JSON differs from the original data.") }
            return single(try await publishFile(dest, ctx: ctx, suffix: request.suffix, format: format))

        case .shiftTiming(let ms):
            guard ms != 0 else { throw MacFlowError("Enter a shift other than zero.") }
            let cues = try SubtitleEngine.parse(try DocumentEngine.readText(file), format: format.id)
            let shifted = try SubtitleEngine.shift(cues, by: ms)
            let dest = temp(format)
            try DocumentEngine.write(try SubtitleEngine.serialize(shifted, as: format.id), to: dest)
            return single(try await publishFile(dest, ctx: ctx, suffix: "shifted", format: format, expectation: ValidationExpectation(cues: cues.count)))
        }
    }
}
