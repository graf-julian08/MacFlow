import AVFoundation
import ImageIO
import PDFKit
import XCTest
@testable import MacFlow

/// Applies every tool the ⌘ wheel offers to every fixture it is offered for
/// and checks the content of each result. Honest refusals (e.g. "this PDF
/// cannot be made smaller") are listed explicitly per tool; anything else
/// fails.
final class ToolMatrixTests: XCTestCase {

    func testEveryOfferedToolOnEveryFixture() async throws {
        EngineCapabilities.shared.probeExternalTools()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MacFlowToolMatrix-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (fixtures, _) = try await Fixtures.makeAll(in: root.appendingPathComponent("in"))
        var report: [String] = ["MacFlow tool matrix — \(Date())", ""]
        var failures: [String] = []
        var passed = 0, refused = 0

        for fixture in fixtures {
            let probe = FileClassifier.shared.classify(fixture.url)
            let tools = ToolCatalog.tools(for: [probe])
            for tool in tools.primary + tools.more {
                guard let request = request(for: tool, file: probe) else { continue }
                // Fresh copy per tool so results never feed each other.
                let dir = root.appendingPathComponent("work/\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let src = dir.appendingPathComponent(fixture.url.lastPathComponent)
                try FileManager.default.copyItem(at: fixture.url, to: src)
                let before = Fixtures.sha256(src)
                let label = "\(fixture.url.lastPathComponent) · \(tool.title)"
                do {
                    let outcome = try await ToolRunner.run(request, on: [src]) { _ in }
                    guard Fixtures.sha256(src) == before else { throw MacFlowError("SOURCE MODIFIED") }
                    try await verify(tool, source: src, outcome: outcome)
                    passed += 1
                    report.append("PASS  \(label) → \(outcome.outputs.map(\.lastPathComponent).joined(separator: ", "))\(outcome.note.map { "  (\($0))" } ?? "")")
                } catch {
                    let message = error.userMessage
                    if acceptableRefusal(tool, message) {
                        refused += 1
                        report.append("OK    \(label): refused honestly — \(message)")
                    } else {
                        failures.append("\(label): \(message)")
                        report.append("FAIL  \(label): \(message)")
                    }
                }
                let leftovers = (try FileManager.default.contentsOfDirectory(atPath: dir.path))
                    .filter { $0.hasPrefix("result.") || $0.hasPrefix("intermediate-") || $0.hasPrefix("oggenc-input") || $0.hasPrefix("extract-") }
                if !leftovers.isEmpty { failures.append("\(label): scratch files leaked \(leftovers)") }
            }
        }
        report.append("")
        report.append("PASSED \(passed)  HONEST REFUSALS \(refused)  FAILED \(failures.count)")
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACFLOW_TOOL_REPORT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("macflow-tools.txt").path)
        try report.joined(separator: "\n").write(to: out, atomically: true, encoding: .utf8)
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
        XCTAssertGreaterThan(passed, 150)
    }

    // MARK: - Requests

    func request(for tool: FileTool, file: ClassifiedFile) -> ToolRequest? {
        switch tool {
        case .compress:
            let size = PreviewLoader.orientedSize(file.url) ?? CGSize(width: 64, height: 64)
            return .compress(CompressSettings(format: .keep, quality: 0.6, maxDimension: max(8, Int(max(size.width, size.height) / 2))))
        case .metadata:
            var edit = MetadataEdit(); edit.fields[.author] = "MacFlow Test"; edit.fields[.title] = "Matrix"
            return .metadata(edit)
        case .adjust:
            var s = AdjustSettings(); s.exposure = 0.4; s.saturation = 1.2
            return .adjust(s)
        case .crop: return .crop(CGRect(x: 0.1, y: 0.1, width: 0.7, height: 0.7))
        case .rotate: return .rotate(RotateSettings(quarterTurns: 1))
        case .redact: return .redact(RedactSettings(regions: [RedactRegion(rect: CGRect(x: 0, y: 0, width: 0.4, height: 0.4), kind: .manual)], style: .black))
        case .background: return .background(BackgroundSettings())
        case .resize: return .resize(nil, percent: 50)
        case .removeBackground: return .removeBackground
        case .readQR: return nil // read-only, covered by ToolTests
        case .annotate:
            return .annotate([Annotation(kind: .rectangle, start: CGPoint(x: 0.2, y: 0.2), end: CGPoint(x: 0.6, y: 0.6), color: RGBAColor(r: 1, g: 0, b: 0), lineWidth: 0.01)])
        case .makePDF: return .makePDF(MakePDFSettings(order: [file.url]))
        case .videoCompress:
            var s = VideoCompressSettings(); s.quality = .low; s.maxShortSide = 120
            return .videoCompress(s)
        case .trim: return .trim(start: 0.5, end: 1.5)
        case .videoRotate: return .videoRotate(1)
        case .mute: return .mute
        case .extractAudio: return .extractAudio
        case .snapshot: return .snapshot(seconds: 1, formatID: "png")
        case .speed: return .speed(2, keepPitch: true)
        case .audioTrim: return .audioTrim(start: 0.25, end: 1.25)
        case .volume: return .volume(gainDB: -6, normalize: false)
        case .fade: return .fade(fadeIn: 0.5, fadeOut: 0.5)
        case .channels: return .channels(.mono)
        case .pdfCompress: return .pdfCompress(.smallest)
        case .pages:
            let count = PDFTools.pageCount(file.url)
            return .pages((0..<count).reversed().map { PageItem(sourceIndex: $0) })
        case .pdfMetadata:
            var e = PDFMetadataEdit(); e.title = "Matrix Title"; e.author = "MacFlow Test"
            return .pdfMetadata(e)
        case .protect:
            var p = ProtectSettings(); p.password = "matrix1"
            return .protect(p)
        case .watermark: return .watermark(WatermarkSettings(text: "MATRIXMARK"))
        case .pageNumbers: return .pageNumbers(PageNumberSettings())
        case .ocr: return .ocr(.text)
        case .splitPDF: return .split(.everyPage)
        case .mergePDF: return nil // needs two files, covered by ToolTests
        case .extractText: return .extractText
        case .extract: return .extract(password: nil, selection: nil)
        case .archiveContents: return .extract(password: nil, selection: ["archive-src/a.txt"])
        case .testArchive: return .testArchive
        case .prettyPrint: return .prettyPrint
        case .minify: return .minify
        case .shiftTiming: return .shiftTiming(milliseconds: 500)
        }
    }

    func acceptableRefusal(_ tool: FileTool, _ message: String) -> Bool {
        switch tool {
        case .removeBackground: return message.contains("No subject was found")
        case .pdfCompress: return message.contains("cannot be made smaller")
        case .ocr: return message.contains("No text was recognised")
        case .splitPDF: return message.contains("same document")
        case .channels: return message.contains("already mono")
        default: return false
        }
    }

    // MARK: - Content checks

    func dims(_ url: URL) throws -> (Int, Int) {
        let image = try ImageEngine.load(url).image
        return (image.width, image.height)
    }

    func verify(_ tool: FileTool, source: URL, outcome: OperationOutcome) async throws {
        if tool == .testArchive {
            guard outcome.note?.contains("intact") == true else { throw MacFlowError("no test result") }
            return
        }
        guard let out = outcome.outputs.first else { throw MacFlowError("no output") }
        guard FileManager.default.fileExists(atPath: out.path), out != source else { throw MacFlowError("output missing") }
        let original = PreviewLoader.orientedSize(source)
        switch tool {
        case .crop:
            let (w, h) = try dims(out)
            guard let o = original, abs(Double(w) - o.width * 0.7) <= 2, abs(Double(h) - o.height * 0.7) <= 2 else {
                throw MacFlowError("crop size \(w)×\(h) wrong for \(String(describing: original))")
            }
        case .rotate:
            let (w, h) = try dims(out)
            guard let o = original, w == Int(o.height), h == Int(o.width) else { throw MacFlowError("rotation not applied: \(w)×\(h)") }
        case .resize:
            let (w, h) = try dims(out)
            guard let o = original, abs(Double(w) - o.width / 2) <= 1, abs(Double(h) - o.height / 2) <= 1 else { throw MacFlowError("resize wrong \(w)×\(h)") }
        case .metadata:
            let fields = ImageTools.readFields(out)
            guard fields[.author] == "MacFlow Test", fields[.title] == "Matrix" else { throw MacFlowError("metadata not stored: \(fields)") }
            guard ImageTools.pixelsIdentical(source, out) else { throw MacFlowError("pixels changed") }
        case .compress, .adjust, .redact, .background, .annotate, .removeBackground:
            _ = try dims(out)
        case .makePDF:
            guard PDFDocument(url: out)?.pageCount == 1 else { throw MacFlowError("PDF page count") }
        case .videoCompress:
            let info = try await MediaEngine.info(out)
            guard min(info.size.width, info.size.height) == 120, abs(info.duration - 2) < 0.2 else { throw MacFlowError("compressed video \(info.size) \(info.duration)s") }
        case .trim:
            let d = try await MediaEngine.info(out).duration
            guard abs(d - 1) < 0.15 else { throw MacFlowError("trim duration \(d)") }
        case .videoRotate:
            let a = try await MediaEngine.info(source).size, b = try await MediaEngine.info(out).size
            guard a.width == b.height, a.height == b.width else { throw MacFlowError("video not rotated") }
        case .mute:
            guard try await !MediaEngine.info(out).hasAudio else { throw MacFlowError("audio still present") }
        case .extractAudio:
            let info = try await MediaEngine.info(out)
            guard info.hasAudio, !info.hasVideo else { throw MacFlowError("not audio-only") }
        case .snapshot:
            _ = try dims(out)
        case .speed:
            let d = try await MediaEngine.info(out).duration
            guard abs(d - 1) < 0.15 else { throw MacFlowError("speed duration \(d)") }
        case .audioTrim:
            let f = try AVAudioFile(forReading: out)
            let d = Double(f.length) / f.fileFormat.sampleRate
            guard abs(d - 1) < 0.06 else { throw MacFlowError("audio trim duration \(d)") }
        case .volume, .fade:
            let f = try AVAudioFile(forReading: out)
            guard f.length > 0 else { throw MacFlowError("empty audio") }
        case .channels:
            guard try AVAudioFile(forReading: out).fileFormat.channelCount == 1 else { throw MacFlowError("not mono") }
        case .pdfCompress, .pages, .watermark, .pageNumbers:
            guard PDFDocument(url: out)?.pageCount == PDFDocument(url: source)?.pageCount else { throw MacFlowError("page count changed") }
            if tool == .watermark, PDFDocument(url: out)?.string?.contains("MATRIXMARK") != true,
               PDFDocument(url: source)?.string?.isEmpty == false { throw MacFlowError("watermark missing") }
        case .pdfMetadata:
            let m = PDFTools.readMetadata(out)
            guard m.title == "Matrix Title", m.author == "MacFlow Test" else { throw MacFlowError("PDF metadata not stored") }
        case .protect:
            guard let doc = PDFDocument(url: out), doc.isLocked, doc.unlock(withPassword: "matrix1") else { throw MacFlowError("not protected") }
        case .ocr, .extractText:
            guard !(try String(contentsOf: out, encoding: .utf8)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw MacFlowError("no text") }
        case .splitPDF:
            let count = try FileManager.default.contentsOfDirectory(atPath: out.path).count
            guard count == PDFDocument(url: source)?.pageCount else { throw MacFlowError("split count \(count)") }
        case .extract:
            let all = FileManager.default.enumerator(atPath: out.path)?.allObjects as? [String] ?? []
            guard all.contains(where: { $0.hasSuffix("a.txt") }), all.contains(where: { $0.hasSuffix("b.txt") }) else { throw MacFlowError("extracted content incomplete: \(all)") }
        case .archiveContents:
            let all = FileManager.default.enumerator(atPath: out.path)?.allObjects as? [String] ?? []
            guard all.contains(where: { $0.hasSuffix("a.txt") }), !all.contains(where: { $0.hasSuffix("b.txt") }) else { throw MacFlowError("selection not honoured: \(all)") }
        case .prettyPrint, .minify:
            _ = try JSONCodec.parse(try String(contentsOf: out, encoding: .utf8))
        case .shiftTiming:
            let format = FileClassifier.shared.format(of: source)!.id
            let a = try SubtitleEngine.parse(try String(contentsOf: source, encoding: .utf8), format: format)
            let b = try SubtitleEngine.parse(try String(contentsOf: out, encoding: .utf8), format: format)
            guard zip(a, b).allSatisfy({ $1.start == $0.start + 500 && $1.end == $0.end + 500 }) else { throw MacFlowError("timing not shifted exactly") }
        case .readQR, .mergePDF, .testArchive:
            break
        }
    }
}

@MainActor
final class PagerLockTests: XCTestCase {
    /// After MORE flips the page, the BACK segment that lands under the
    /// pointer must not flip it back until the pointer has left it.
    func testMoreDoesNotPingPong() throws {
        let jpg = ClassifiedFile(url: URL(fileURLWithPath: "/x.jpg"), format: FormatRegistry.shared["jpg"], isDirectory: false, extensionMismatch: false)
        let model = RadialMenuViewModel(mode: .tools, config: .default)
        model.configure(mode: .tools, files: [jpg])
        let size = CGSize(width: 314, height: 314)
        func point(index: Int, of count: Int) -> CGPoint {
            let angle = 2 * Double.pi * Double(index) / Double(count)
            return CGPoint(x: 157 + 90 * sin(angle), y: 157 - 90 * cos(angle))
        }
        func wait(_ s: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        let moreIndex = try XCTUnwrap(model.segments.firstIndex { $0.label == "MORE" })
        let morePoint = point(index: moreIndex, of: model.segments.count)
        model.updateHover(at: morePoint, in: size)
        wait(0.7)
        XCTAssertEqual(model.page, 1, "MORE flips after the dwell time")
        // Pointer stays where it was, now over BACK: must stay on page 1.
        for _ in 0..<10 { model.updateHover(at: morePoint, in: size); wait(0.1) }
        XCTAssertEqual(model.segmentID(at: morePoint, in: size), "back", "fixture: BACK lies under the pointer")
        XCTAssertEqual(model.page, 1, "BACK must not trigger without leaving it first")
        // Visit another segment, come back: BACK works again.
        model.updateHover(at: point(index: 0, of: model.segments.count), in: size)
        model.updateHover(at: morePoint, in: size)
        wait(0.7)
        XCTAssertEqual(model.page, 0)
        // Same rule on the way back: MORE is locked until left (via the centre here).
        for _ in 0..<8 { model.updateHover(at: morePoint, in: size); wait(0.1) }
        XCTAssertEqual(model.page, 0)
        model.updateHover(at: CGPoint(x: 157, y: 157), in: size)
        model.updateHover(at: morePoint, in: size)
        wait(0.7)
        XCTAssertEqual(model.page, 1)
    }
}
