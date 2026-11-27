import AppKit
import AVFoundation
import ImageIO
import PDFKit
import XCTest
@testable import MacFlow

/// Runs every conversion the wheel offers for every fixture format and
/// verifies the transactional guarantees. Writes a report to
/// `$MACFLOW_REPORT` (or the temporary directory).
final class ConversionMatrixTests: XCTestCase {

    static var root: URL!
    static var fixtures: [Fixtures.Fixture] = []
    static var skipped: [String] = []

    override class func setUp() {
        super.setUp()
        EngineCapabilities.shared.probeExternalTools()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MacFlowTests-\(UUID().uuidString)", isDirectory: true)
        let done = XCTestExpectation(description: "fixtures")
        Task {
            do {
                let result = try await Fixtures.makeAll(in: root.appendingPathComponent("in"))
                fixtures = result.fixtures
                skipped = result.skipped
            } catch {
                XCTFail("Fixture generation failed: \(error)")
            }
            done.fulfill()
        }
        _ = XCTWaiter.wait(for: [done], timeout: 300)
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    /// Private copy of a fixture in its own folder.
    func isolated(_ fixture: Fixtures.Fixture, tag: String = "") throws -> URL {
        let dir = Self.root.appendingPathComponent("work/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(fixture.url.lastPathComponent)
        try FileManager.default.copyItem(at: fixture.url, to: copy)
        return copy
    }

    func fixture(_ name: String) throws -> Fixtures.Fixture {
        try XCTUnwrap(Self.fixtures.first { $0.url.lastPathComponent == name }, "missing fixture \(name)")
    }

    func testClassificationOfEveryFixture() {
        XCTAssertGreaterThan(Self.fixtures.count, 40)
        for fixture in Self.fixtures {
            XCTAssertEqual(FileClassifier.shared.classify(fixture.url).format?.id, fixture.expectedFormat, fixture.url.lastPathComponent)
        }
    }

    func testFullConversionMatrix() async throws {
        var lines: [String] = ["MacFlow conversion matrix — \(Date())", "Skipped fixtures: \(Self.skipped)", ""]
        var passed = 0
        var failed: [String] = []
        for fixture in Self.fixtures {
            let source = try isolated(fixture)
            let classified = FileClassifier.shared.classify(source)
            let options = ConversionCatalog.shared.options(for: [classified])
            let before = Fixtures.sha256(source)
            let dirBefore = Set(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path))
            for option in options {
                let started = Date()
                do {
                    let outcome = try await ConversionService.convert(classified, option: option) { _ in }
                    XCTAssertEqual(Fixtures.sha256(source), before, "source modified by \(option.id)")
                    let out = try XCTUnwrap(outcome.outputs.first)
                    XCTAssertTrue(FileManager.default.fileExists(atPath: out.path))
                    XCTAssertNotEqual(out.standardizedFileURL, source.standardizedFileURL)
                    passed += 1
                    lines.append(String(format: "PASS  %-20@ → %-7@ %6.2fs  %@  [%@]%@", fixture.url.lastPathComponent as NSString, option.target.label as NSString,
                                        Date().timeIntervalSince(started), out.lastPathComponent as NSString, option.status.rawValue as NSString,
                                        (outcome.note.map { "  \($0)" } ?? "") as NSString))
                } catch {
                    failed.append("\(fixture.url.lastPathComponent) → \(option.target.label): \(error.userMessage)")
                    lines.append("FAIL  \(fixture.url.lastPathComponent) → \(option.target.label): \(error.userMessage)")
                }
            }
            // No scratch files may leak next to the user's files.
            let after = Set(try FileManager.default.contentsOfDirectory(atPath: source.deletingLastPathComponent().path))
            let leaked = after.subtracting(dirBefore).filter { $0.hasPrefix("result.") || $0.hasPrefix("extract-") || $0.contains("webp-input") }
            XCTAssertTrue(leaked.isEmpty, "scratch files leaked: \(leaked)")
        }
        lines.append("")
        lines.append("PASSED \(passed)  FAILED \(failed.count)")
        let reportURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACFLOW_REPORT"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("macflow-matrix.txt").path)
        try lines.joined(separator: "\n").write(to: reportURL, atomically: true, encoding: .utf8)
        XCTAssertTrue(failed.isEmpty, "Failures:\n" + failed.joined(separator: "\n"))
        XCTAssertGreaterThan(passed, 350)
    }

    // MARK: - Semantic checks

    func convert(_ name: String, to target: String) async throws -> URL {
        let source = try isolated(try fixture(name))
        let classified = FileClassifier.shared.classify(source)
        let option = try XCTUnwrap(ConversionCatalog.shared.option(for: classified, target: target), "\(name) → \(target) not offered")
        let outcome = try await ConversionService.convert(classified, option: option) { _ in }
        return try XCTUnwrap(outcome.outputs.first)
    }

    func pixel(_ image: CGImage, x: Int, y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        return (Int(p[0]), Int(p[1]), Int(p[2]), Int(p[3]))
    }

    func testEXIFOrientationIsApplied() async throws {
        // The fixture is stored 640×400 with orientation 6 (rotate 90° CW).
        let png = try await convert("Photo Ü 1.jpg", to: "png")
        XCTAssertEqual(png.lastPathComponent, "Photo Ü 1.png")
        let image = try ImageEngine.load(png).image
        XCTAssertEqual(image.width, 400)
        XCTAssertEqual(image.height, 640)
        // Stored top-left red marker must now be at the top-right.
        let topRight = pixel(image, x: image.width - 10, y: 10)
        XCTAssertGreaterThan(topRight.r, 200); XCTAssertLessThan(topRight.g, 60)
        let topLeft = pixel(image, x: 10, y: 10)
        XCTAssertFalse(topLeft.r > 200 && topLeft.g < 60, "marker in wrong corner")
        let props = CGImageSourceCopyPropertiesAtIndex(try ImageEngine.makeSource(png), 0, nil) as? [CFString: Any]
        XCTAssertEqual((props?[kCGImagePropertyOrientation] as? Int) ?? 1, 1)
    }

    func testEveryOrientationMatchesImageIOReference() throws {
        let base = Fixtures.testImage(width: 60, height: 40, alpha: false)
        for orientation in 1...8 {
            let url = Self.root.appendingPathComponent("orient-\(orientation).jpg")
            try Fixtures.writeImage(base, to: url, type: "public.jpeg", properties: [kCGImagePropertyOrientation: orientation])
            let ours = try ImageEngine.load(url).image
            let reference = try XCTUnwrap(ImageEngine.thumbnail(url, maxPixel: 100))
            XCTAssertEqual(ours.width, reference.width, "orientation \(orientation)")
            XCTAssertEqual(ours.height, reference.height, "orientation \(orientation)")
            for (x, y) in [(2, 2), (ours.width - 3, 2), (2, ours.height - 3), (ours.width - 3, ours.height - 3)] {
                let a = pixel(ours, x: x, y: y), b = pixel(reference, x: x, y: y)
                XCTAssertLessThan(abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b), 60, "orientation \(orientation) at \(x),\(y)")
            }
        }
    }

    func testTransparencyKeptOrFlattened() async throws {
        let heic = try await convert("alpha.png", to: "heic")
        XCTAssertTrue(ImageEngine.hasAlpha(try ImageEngine.load(heic).image))
        let jpg = try await convert("alpha.png", to: "jpg")
        let image = try ImageEngine.load(jpg).image
        let corner = pixel(image, x: image.width - 2, y: image.height - 2)
        XCTAssertGreaterThan(corner.r, 240, "transparent area must become white")
    }

    func testAnimationKeptForGIFToPNG() async throws {
        let png = try await convert("anim.gif", to: "png")
        XCTAssertEqual(CGImageSourceGetCount(try ImageEngine.makeSource(png)), 3)
    }

    func testMultipageTIFFToPDF() async throws {
        let pdf = try await convert("pages.tiff", to: "pdf")
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 2)
    }

    func testSVGToPDFStaysVector() async throws {
        let pdf = try await convert("vector.svg", to: "pdf")
        let page = try XCTUnwrap(PDFDocument(url: pdf)?.page(at: 0))
        XCTAssertEqual(page.bounds(for: .mediaBox).width, 200, accuracy: 0.5)
        XCTAssertLessThan(fileSize(of: pdf), 20_000, "vector PDF should be tiny")
    }

    func testPDFPagesBecomeFolder() async throws {
        let folder = try await convert("document.pdf", to: "png")
        XCTAssertTrue(folder.lastPathComponent.hasSuffix("(PNG)"))
        let pages = PDFDocument(url: try fixture("document.pdf").url)!.pageCount
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, pages)
    }

    func testScannedPDFUsesOCR() async throws {
        let txt = try await convert("scan.pdf", to: "txt")
        let text = try String(contentsOf: txt, encoding: .utf8)
        XCTAssertTrue(text.contains("4711"), "OCR text: \(text)")
    }

    func testDocxTextAndUnicodeSurvive() async throws {
        let pdf = try await convert("word.docx", to: "pdf")
        // PDF text layers may use compatibility code points for CJK glyphs.
        let text = (PDFDocument(url: pdf)?.string ?? "").precomposedStringWithCompatibilityMapping
        XCTAssertTrue(text.contains("äöü"))
        XCTAssertTrue(text.contains("日本"))
        let mdURL = try await convert("word.docx", to: "md")
        let md = try String(contentsOf: mdURL, encoding: .utf8)
        XCTAssertTrue(md.contains("**bold**"), md)
    }

    func testMarkdownToHTML() async throws {
        let htmlURL = try await convert("readme.md", to: "html")
        let html = try String(contentsOf: htmlURL, encoding: .utf8)
        for fragment in ["<h1>MacFlow</h1>", "<strong>bold</strong>", "<em>emphasis</em>", "<code>code</code>", "<a href=\"https://example.com\">link</a>",
                         "<li>Nested</li>", "<ol>", "<blockquote>", "language-swift", "<table>", "text-align: center"] {
            XCTAssertTrue(html.contains(fragment), "missing \(fragment)")
        }
    }

    func testCSVRoundTripKeepsQuotingAndExactValues() async throws {
        let jsonURL = try await convert("table.csv", to: "json")
        let json = try String(contentsOf: jsonURL, encoding: .utf8)
        let value = try JSONCodec.parse(json)
        guard case .array(let rows) = value, case .object(let first) = rows[0], case .object(let second) = rows[1] else { return XCTFail() }
        XCTAssertEqual(first.first { $0.0 == "name" }?.1, .string("Doe, Jane"))
        XCTAssertEqual(first.first { $0.0 == "age" }?.1, .number("42"))
        XCTAssertEqual(second.first { $0.0 == "age" }?.1, .string("007"), "leading zeros must not become a number")
        XCTAssertEqual(second.first { $0.0 == "city" }?.1, .string("Multi\nLine"))
    }

    func testXLSXSheetsDatesAndFormulas() async throws {
        let folder = try await convert("book.xlsx", to: "csv")
        let sales = try String(contentsOf: folder.appendingPathComponent("Sales.csv"), encoding: .utf8)
        XCTAssertTrue(sales.contains("Äpfel,3.25,2024-06-01"), sales)
        XCTAssertTrue(sales.contains("Birnen,6.5"), sales)
        let notes = try String(contentsOf: folder.appendingPathComponent("Notes.csv"), encoding: .utf8)
        XCTAssertTrue(notes.contains("Note,TRUE"))
    }

    func testSubtitleTimingExact() async throws {
        let vttURL = try await convert("movie.srt", to: "vtt")
        let vtt = try String(contentsOf: vttURL, encoding: .utf8)
        XCTAssertTrue(vtt.contains("00:00:03.001 --> 00:00:04.999"))
        let srtURL = try await convert("movie.ass", to: "srt")
        let srt = try String(contentsOf: srtURL, encoding: .utf8)
        XCTAssertTrue(srt.contains("00:00:01,000 --> 00:00:02,500"))
        XCTAssertTrue(srt.contains("Hello, world\nsecond"), srt)
    }

    func testArchiveRepackKeepsContent() async throws {
        let zip = try await convert("files.7z", to: "zip")
        let entries = try await ArchiveEngine.list(zip).filter { !$0.isDirectory }.map(\.path).sorted()
        XCTAssertEqual(entries, ["archive-src/a.txt", "archive-src/sub/b.txt"])
        let tgz = try await convert("Folder With Spaces", to: "tgz")
        XCTAssertEqual(tgz.lastPathComponent, "Folder With Spaces.tar.gz")
    }

    func testAudioBitDepthAndDuration() async throws {
        let wav = try await convert("tone.flac", to: "wav")
        let file = try AVAudioFile(forReading: wav)
        XCTAssertEqual(file.fileFormat.streamDescription.pointee.mBitsPerChannel, 24)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 2, accuracy: 0.01)
    }

    func testVideoContainerChangeKeepsDuration() async throws {
        let mov = try await convert("clip.mp4", to: "mov")
        let info = try await MediaEngine.info(mov)
        XCTAssertEqual(info.duration, 2, accuracy: 0.1)
        XCTAssertTrue(info.hasAudio)
        XCTAssertTrue(info.hasVideo)
    }

    func testRepeatedConversionNeverOverwrites() async throws {
        let source = try isolated(try fixture("alpha.png"))
        let classified = FileClassifier.shared.classify(source)
        let option = try XCTUnwrap(ConversionCatalog.shared.option(for: classified, target: "jpg"))
        let a = try await ConversionService.convert(classified, option: option) { _ in }.outputs[0]
        let b = try await ConversionService.convert(classified, option: option) { _ in }.outputs[0]
        let c = try await ConversionService.convert(classified, option: option) { _ in }.outputs[0]
        XCTAssertEqual([a, b, c].map(\.lastPathComponent), ["alpha.jpg", "alpha (2).jpg", "alpha (3).jpg"])
    }

    func testCatalogHidesTargetsThatCannotRepresentContent() throws {
        let json = FileClassifier.shared.classify(try fixture("data.json").url)
        let ids = ConversionCatalog.shared.options(for: [json]).map(\.id)
        XCTAssertFalse(ids.contains("plist"), "JSON with null must not offer PLIST")
        XCTAssertTrue(ids.contains("csv"))
        let png = FileClassifier.shared.classify(try fixture("alpha.png").url)
        XCTAssertFalse(ConversionCatalog.shared.options(for: [png]).contains { $0.id == "png" }, "source format offered")
    }
}
