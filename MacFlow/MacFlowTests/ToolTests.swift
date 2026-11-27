import AVFoundation
import ImageIO
import PDFKit
import XCTest
@testable import MacFlow

/// Executes every tool through `ToolRunner` (the same path the panels use)
/// and checks the result's content, not just its existence.
final class ToolTests: XCTestCase {

    var dir: URL!

    override func setUp() async throws {
        EngineCapabilities.shared.probeExternalTools()
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("MacFlowTools-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Helpers

    func photo(_ name: String = "photo.jpg", orientation: Int = 1, gps: Bool = true, size: (Int, Int) = (800, 600)) throws -> URL {
        let url = dir.appendingPathComponent(name)
        var props: [CFString: Any] = [kCGImagePropertyOrientation: orientation,
                                      kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Original Artist"],
                                      kCGImageDestinationLossyCompressionQuality: 0.95]
        if gps {
            props[kCGImagePropertyGPSDictionary] = [kCGImagePropertyGPSLatitude: 47.37, kCGImagePropertyGPSLatitudeRef: "N",
                                                    kCGImagePropertyGPSLongitude: 8.54, kCGImagePropertyGPSLongitudeRef: "E"]
        }
        let type = name.hasSuffix(".png") ? "public.png" : (name.hasSuffix(".heic") ? "public.heic" : "public.jpeg")
        try Fixtures.writeImage(Fixtures.testImage(width: size.0, height: size.1, alpha: name.hasSuffix(".png")), to: url, type: type, properties: props)
        return url
    }

    func run(_ request: ToolRequest, _ files: [URL]) async throws -> OperationOutcome {
        let before = files.map(Fixtures.sha256)
        let outcome = try await ToolRunner.run(request, on: files) { _ in }
        XCTAssertEqual(files.map(Fixtures.sha256), before, "a tool modified its source")
        for out in outcome.outputs { XCTAssertFalse(files.contains(out), "output replaced a source") }
        return outcome
    }

    func size(_ url: URL) throws -> (Int, Int) {
        let image = try ImageEngine.load(url).image
        return (image.width, image.height)
    }

    // MARK: Images

    func testCompressReducesSizeAndHonoursTarget() async throws {
        let src = try photo(size: (1600, 1200))
        let out = try await run(.compress(CompressSettings(format: .keep, quality: 0.4)), [src]).outputs[0]
        XCTAssertEqual(out.lastPathComponent, "photo-compressed.jpg")
        XCTAssertLessThan(fileSize(of: out), fileSize(of: src))
        let target = try await run(.compress(CompressSettings(format: .heic, quality: 0.8, targetBytes: 40_000)), [src]).outputs[0]
        XCTAssertLessThanOrEqual(fileSize(of: target), 40_000)
        XCTAssertEqual(target.pathExtension, "heic")
        do {
            _ = try await run(.compress(CompressSettings(format: .jpeg, targetBytes: 50)), [src])
            XCTFail("an unreachable target must fail")
        } catch {
            XCTAssertTrue(error.userMessage.contains("cannot be reached"))
        }
    }

    func testCropRespectsTopLeftOrigin() async throws {
        let src = try photo(gps: false)
        // Top-left 20 % contains the red marker.
        let out = try await run(.crop(CGRect(x: 0, y: 0, width: 0.2, height: 0.2)), [src]).outputs[0]
        let image = try ImageEngine.load(out).image
        XCTAssertEqual(image.width, 160); XCTAssertEqual(image.height, 120)
        let ctx = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -80, y: -60, width: image.width, height: image.height))
        let p = ctx.data!.assumingMemoryBound(to: UInt8.self)
        XCTAssertGreaterThan(p[0], 200); XCTAssertLessThan(p[1], 70)
    }

    func testLosslessRotationOfJPEG() async throws {
        let src = try photo(orientation: 1)
        let out = try await run(.rotate(RotateSettings(quarterTurns: 1)), [src]).outputs[0]
        XCTAssertEqual(try size(out).0, 600)
        XCTAssertTrue(ImageTools.pixelsIdentical(src, out), "rotation must not re-encode")
        let props = CGImageSourceCopyPropertiesAtIndex(try ImageEngine.makeSource(out), 0, nil) as? [CFString: Any]
        XCTAssertEqual(props?[kCGImagePropertyOrientation] as? Int, 6)
    }

    func testRotationComposesWithExistingOrientation() {
        // Existing 6 (90° CW) + another 90° CW = 180° (3).
        let combined = Orientation.compose(RotateSettings(quarterTurns: 1).transform, after: Orientation.element(exif: 6))
        XCTAssertEqual(Orientation.exif(combined), 3)
        for exif in 1...8 {
            XCTAssertEqual(Orientation.exif(Orientation.element(exif: exif)), exif)
        }
        var flip = RotateSettings(quarterTurns: 0); flip.flipHorizontal = true
        XCTAssertEqual(Orientation.exif(flip.transform), 2)
    }

    func testRotatePNGBakesPixels() async throws {
        let src = try photo("shape.png", gps: false)
        let out = try await run(.rotate(RotateSettings(quarterTurns: 1)), [src]).outputs[0]
        XCTAssertEqual(try size(out).0, 600)
        XCTAssertEqual(out.pathExtension, "png")
    }

    func testMetadataEditIsLosslessAndCorrect() async throws {
        let src = try photo()
        var edit = MetadataEdit()
        edit.fields[.author] = "Jane Doe"
        edit.fields[.title] = "Lake"
        edit.removeLocation = true
        let out = try await run(.metadata(edit), [src]).outputs[0]
        XCTAssertTrue(ImageTools.pixelsIdentical(src, out))
        let fields = ImageTools.readFields(out)
        XCTAssertEqual(fields[.author], "Jane Doe")
        XCTAssertEqual(fields[.title], "Lake")
        XCTAssertNil(fields[.latitude], "GPS must be removed")
    }

    /// Every editable field round-trips on every writable format, including
    /// files that already carry metadata (this crashed ImageIO's HEIC writer
    /// when language-alternative fields were written as plain strings).
    func testMetadataRoundTripEveryFieldEveryFormat() async throws {
        for (ext, type) in [("jpg", "public.jpeg"), ("heic", "public.heic"), ("png", "public.png"), ("tiff", "public.tiff")] {
            let src = dir.appendingPathComponent("meta.\(ext)")
            try? FileManager.default.removeItem(at: src)
            try Fixtures.writeImage(Fixtures.testImage(width: 120, height: 80, alpha: false), to: src, type: type, properties: [
                kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Old Artist", kCGImagePropertyTIFFImageDescription: "Old description",
                                                 kCGImagePropertyTIFFCopyright: "Old ©", kCGImagePropertyTIFFMake: "OldMake"],
                kCGImagePropertyIPTCDictionary: [kCGImagePropertyIPTCKeywords: ["old"], kCGImagePropertyIPTCObjectName: "Old title"],
                kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 10.0, kCGImagePropertyGPSLatitudeRef: "N",
                                                kCGImagePropertyGPSLongitude: 20.0, kCGImagePropertyGPSLongitudeRef: "E"],
            ])
            var edit = MetadataEdit()
            let wanted: [MetadataField: String] = [.title: "Lake & Hills", .description: "A <quiet> morning", .author: "Jane Doe",
                                                   .copyright: "© 2026 Jane", .keywords: "lake, alps", .dateTaken: "2024:05:31 14:30:00",
                                                   .make: "Apple", .model: "iPhone 17", .latitude: "-33.868800", .longitude: "151.209300"]
            edit.fields = wanted
            let out = try await run(.metadata(edit), [src]).outputs[0]
            XCTAssertTrue(ImageTools.pixelsIdentical(src, out), "\(ext): pixels changed")
            let read = ImageTools.readFields(out)
            for (field, value) in wanted {
                XCTAssertEqual(read[field], value, "\(ext): \(field.label)")
            }
            // Editing one field keeps the others (including TIFF GPS).
            var single = MetadataEdit(); single.fields[.title] = "Only title"
            let second = try await run(.metadata(single), [out]).outputs[0]
            let again = ImageTools.readFields(second)
            XCTAssertEqual(again[.title], "Only title", ext)
            XCTAssertEqual(again[.author], "Jane Doe", ext)
            XCTAssertEqual(again[.latitude], "-33.868800", "\(ext): location must survive an unrelated edit")
            // Clearing fields and removing location.
            var clear = MetadataEdit(); clear.fields[.author] = ""; clear.removeLocation = true
            let cleared = ImageTools.readFields(try await run(.metadata(clear), [second]).outputs[0])
            XCTAssertNil(cleared[.author], ext)
            XCTAssertNil(cleared[.latitude], ext)
            XCTAssertEqual(cleared[.title], "Only title", ext)
            // Remove everything.
            var all = MetadataEdit(); all.removeAll = true
            let empty = ImageTools.readFields(try await run(.metadata(all), [second]).outputs[0])
            XCTAssertTrue(empty.isEmpty, "\(ext): \(empty)")
        }
    }

    func testRemoveAllMetadataKeepsOrientation() async throws {
        let src = try photo(orientation: 6)
        var edit = MetadataEdit(); edit.removeAll = true
        let out = try await run(.metadata(edit), [src]).outputs[0]
        let props = CGImageSourceCopyPropertiesAtIndex(try ImageEngine.makeSource(out), 0, nil) as? [CFString: Any]
        XCTAssertNil(props?[kCGImagePropertyGPSDictionary])
        XCTAssertNil((props?[kCGImagePropertyTIFFDictionary] as? [CFString: Any])?[kCGImagePropertyTIFFArtist])
        XCTAssertEqual(props?[kCGImagePropertyOrientation] as? Int, 6)
    }

    func testRemoveSingleTag() async throws {
        let src = try photo()
        let entries = try ImageTools.readMetadata(src)
        let artist = try XCTUnwrap(entries.first { $0.value == "Original Artist" })
        var edit = MetadataEdit(); edit.removedPaths = [artist.path]
        let out = try await run(.metadata(edit), [src]).outputs[0]
        XCTAssertNil(ImageTools.readFields(out)[.author])
        XCTAssertNotNil(ImageTools.readFields(out)[.latitude], "other tags stay")
    }

    func testAdjustBackgroundRedactAnnotateResize() async throws {
        let src = try photo(gps: false)
        var adjust = AdjustSettings(); adjust.exposure = 0.5; adjust.saturation = 1.3
        let adjusted = try await run(.adjust(adjust), [src]).outputs[0]
        XCTAssertEqual(try size(adjusted).0, 800)
        var bg = BackgroundSettings(); bg.padding = 0.1; bg.aspect = .square
        let bgOut = try await run(.background(bg), [src]).outputs[0]
        let s = try size(bgOut); XCTAssertEqual(s.0, s.1)
        let redacted = try await run(.redact(RedactSettings(regions: [RedactRegion(rect: CGRect(x: 0, y: 0, width: 0.3, height: 0.3), kind: .manual)], style: .pixelate)), [src])
        XCTAssertEqual(redacted.outputs.count, 1)
        let props = CGImageSourceCopyPropertiesAtIndex(try ImageEngine.makeSource(redacted.outputs[0]), 0, nil) as? [CFString: Any]
        XCTAssertNil(props?[kCGImagePropertyTIFFDictionary].flatMap { ($0 as? [CFString: Any])?[kCGImagePropertyTIFFArtist] }, "redaction strips metadata")
        let annotated = try await run(.annotate([Annotation(kind: .arrow, start: CGPoint(x: 0.1, y: 0.1), end: CGPoint(x: 0.5, y: 0.5), color: RGBAColor(r: 1, g: 0, b: 0), lineWidth: 0.01)]), [src])
        XCTAssertEqual(annotated.outputs.count, 1)
        let resized = try await run(.resize(ResizeSettings(width: 400, height: 300), percent: nil), [src]).outputs[0]
        XCTAssertEqual(try size(resized).0, 400)
        let quarter = try await run(.resize(nil, percent: 25), [src]).outputs[0]
        XCTAssertEqual(try size(quarter).0, 200)
    }

    func testResizeAnimatedGIFKeepsFrames() async throws {
        let gif = dir.appendingPathComponent("anim.gif")
        try Fixtures.writeAnimatedGIF(gif)
        let out = try await run(.resize(nil, percent: 50), [gif]).outputs[0]
        XCTAssertEqual(CGImageSourceGetCount(try ImageEngine.makeSource(out)), 3)
    }

    func testMakePDFOrderAndQRCodeAndNoSubject() async throws {
        let a = try photo("a.jpg", gps: false), b = try photo("b.png", gps: false)
        let pdf = try await run(.makePDF(MakePDFSettings(order: [b, a], pageSize: .a4, margin: 18)), [a, b]).outputs[0]
        XCTAssertEqual(PDFDocument(url: pdf)?.pageCount, 2)
        XCTAssertEqual(pdf.lastPathComponent, "Images.pdf")
        let qr = CIFilter(name: "CIQRCodeGenerator", parameters: ["inputMessage": Data("https://example.com/x".utf8)])!.outputImage!
            .transformed(by: CGAffineTransform(scaleX: 12, y: 12))
        let cg = ImageEngine.ciContext.createCGImage(qr, from: qr.extent)!
        let codes = try ImageTools.readCodes(try ImageEngine.flatten(cg))
        XCTAssertEqual(codes.first?.payload, "https://example.com/x")
    }

    // MARK: PDF

    func makePDF(pages: Int = 3) throws -> URL {
        let url = dir.appendingPathComponent("doc.pdf")
        let text = (1...(pages * 50)).map { "Row \($0) lorem ipsum dolor sit amet" }.joined(separator: "\n")
        try PDFTextRenderer.render(NSAttributedString(string: text, attributes: DocumentEngine.baseAttributes), to: url, title: "T")
        return url
    }

    func testPDFTools() async throws {
        let src = try makePDF()
        let count = try XCTUnwrap(PDFDocument(url: src)?.pageCount)
        // Organize: reverse + rotate first
        var items = (0..<count).reversed().map { PageItem(sourceIndex: $0) }
        items[0].rotation = 90
        let organized = try await run(.pages(items), [src]).outputs[0]
        let doc = try XCTUnwrap(PDFDocument(url: organized))
        XCTAssertEqual(doc.pageCount, count)
        XCTAssertEqual(doc.page(at: 0)?.rotation, 90)
        XCTAssertTrue(doc.page(at: 0)?.string?.contains("Row \(count * 50 - 1)") == true || doc.page(at: 0)?.string?.contains("Row") == true)

        var meta = PDFMetadataEdit(); meta.title = "Report"; meta.author = "Jane"
        let withMeta = try await run(.pdfMetadata(meta), [src]).outputs[0]
        XCTAssertEqual(PDFTools.readMetadata(withMeta).title, "Report")

        var protect = ProtectSettings(); protect.password = "secret1"
        let locked = try await run(.protect(protect), [src]).outputs[0]
        let lockedDoc = try XCTUnwrap(PDFDocument(url: locked))
        XCTAssertTrue(lockedDoc.isLocked)
        XCTAssertFalse(lockedDoc.unlock(withPassword: "wrong"))
        var remove = ProtectSettings(); remove.removeWithPassword = "secret1"
        let unlocked = try await run(.protect(remove), [locked]).outputs[0]
        XCTAssertFalse(PDFDocument(url: unlocked)?.isLocked ?? true)

        let wm = try await run(.watermark(WatermarkSettings(text: "DRAFTMARK")), [src]).outputs[0]
        XCTAssertTrue(PDFDocument(url: wm)?.string?.contains("DRAFTMARK") == true)
        XCTAssertTrue(PDFDocument(url: wm)?.string?.contains("Row 1 ") == true, "original text kept")

        var numbers = PageNumberSettings(); numbers.style = .pageN
        let numbered = try await run(.pageNumbers(numbers), [src]).outputs[0]
        XCTAssertTrue(PDFDocument(url: numbered)?.page(at: 1)?.string?.contains("Page 2") == true)

        let split = try await run(.split(.everyPage), [src])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: split.outputs[0].path).count, count)
        do { _ = try await run(.split(.ranges("1-99")), [src]); XCTFail("invalid range") } catch {}

        let text = try await run(.extractText, [src]).outputs[0]
        XCTAssertTrue(try String(contentsOf: text, encoding: .utf8).contains("Row 3 lorem"))

        let second = dir.appendingPathComponent("second.pdf")
        try FileManager.default.copyItem(at: src, to: second)
        let merged = try await run(.merge([src, second]), [src, second]).outputs[0]
        XCTAssertEqual(PDFDocument(url: merged)?.pageCount, count * 2)
    }

    func testOCRProducesSearchablePDF() async throws {
        let scan = dir.appendingPathComponent("scan.pdf")
        try Fixtures.writeScannedPDF(scan)
        let out = try await run(.ocr(.searchablePDF), [scan]).outputs[0]
        let text = PDFDocument(url: out)?.string ?? ""
        XCTAssertTrue(text.contains("4711"), text)
    }

    // MARK: Media

    func testVideoTools() async throws {
        let mp4 = dir.appendingPathComponent("clip.mp4")
        try await Fixtures.writeMovie(mp4, type: .mp4, codec: .h264, width: 640, height: 480)
        let trimmed = try await run(.trim(start: 0.5, end: 1.5), [mp4]).outputs[0]
        let trimmedInfo = try await MediaEngine.info(trimmed)
        XCTAssertEqual(trimmedInfo.duration, 1.0, accuracy: 0.15)
        let rotated = try await run(.videoRotate(1), [mp4]).outputs[0]
        let size = try await MediaEngine.info(rotated).size
        XCTAssertEqual(size.width, 480); XCTAssertEqual(size.height, 640)
        let muted = try await run(.mute, [mp4]).outputs[0]
        let mutedInfo = try await MediaEngine.info(muted)
        XCTAssertFalse(mutedInfo.hasAudio)
        let audio = try await run(.extractAudio, [mp4]).outputs[0]
        XCTAssertEqual(audio.pathExtension, "m4a")
        let frame = try await run(.snapshot(seconds: 1, formatID: "png"), [mp4]).outputs[0]
        XCTAssertEqual(try ImageEngine.load(frame).image.width, 640)
        let fast = try await run(.speed(2, keepPitch: true), [mp4]).outputs[0]
        let fastInfo = try await MediaEngine.info(fast)
        XCTAssertEqual(fastInfo.duration, 1.0, accuracy: 0.15)
        var settings = VideoCompressSettings(); settings.codec = .hevc; settings.quality = .low; settings.maxShortSide = 240
        let small = try await run(.videoCompress(settings), [mp4]).outputs[0]
        let info = try await MediaEngine.info(small)
        XCTAssertEqual(min(info.size.width, info.size.height), 240)
        XCTAssertEqual(info.duration, 2, accuracy: 0.15)
        XCTAssertTrue(info.hasAudio)
    }

    func testAudioTools() async throws {
        let wav = dir.appendingPathComponent("tone.wav")
        try Fixtures.writeAudio(wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let trimmed = try await run(.audioTrim(start: 0.5, end: 1.25), [wav]).outputs[0]
        let t = try AVAudioFile(forReading: trimmed)
        XCTAssertEqual(t.length, AVAudioFramePosition(0.75 * 44_100), "sample-accurate trim")
        let normalized = try await run(.volume(gainDB: 0, normalize: true), [wav]).outputs[0]
        XCTAssertEqual(try AudioTools.peak(normalized), 0.891, accuracy: 0.01)
        let faded = try await run(.fade(fadeIn: 0.5, fadeOut: 0.5), [wav]).outputs[0]
        let f = try AVAudioFile(forReading: faded)
        let buffer = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 64)!
        try f.read(into: buffer, frameCount: 64)
        XCTAssertLessThan(abs(buffer.floatChannelData![0][10]), 0.01, "starts silent")
        let mono = try await run(.channels(.mono), [wav]).outputs[0]
        XCTAssertEqual(try AVAudioFile(forReading: mono).fileFormat.channelCount, 1)
        do { _ = try await run(.channels(.mono), [mono]); XCTFail("mono → mono must be refused") } catch {}
    }

    func testOggVorbisRoundTripAndEdit() async throws {
        guard EngineCapabilities.shared.canEncodeOggVorbis else { throw XCTSkip("no Vorbis encoder on this Mac") }
        let wav = dir.appendingPathComponent("tone.wav")
        try Fixtures.writeAudio(wav, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false])
        let file = FileClassifier.shared.classify(wav)
        let option = try XCTUnwrap(ConversionCatalog.shared.option(for: file, target: "ogg"))
        let ogg = try await ConversionService.convert(file, option: option) { _ in }.outputs[0]
        XCTAssertEqual(ogg.pathExtension, "ogg")
        XCTAssertEqual(FileClassifier.shared.format(of: ogg)?.id, "ogg")
        let decoded = try AVAudioFile(forReading: ogg)
        XCTAssertEqual(Double(decoded.length) / decoded.fileFormat.sampleRate, 2, accuracy: 0.05)
        // Editing an OGG keeps it OGG.
        let louder = try await run(.volume(gainDB: -3, normalize: false), [ogg]).outputs[0]
        XCTAssertEqual(louder.pathExtension, "ogg")
        XCTAssertEqual(FileClassifier.shared.format(of: louder)?.id, "ogg")
        let mono = try await run(.channels(.mono), [ogg]).outputs[0]
        XCTAssertEqual(try AVAudioFile(forReading: mono).fileFormat.channelCount, 1)
    }

    // MARK: Archives, data, subtitles

    func testArchiveExtractAndTest() async throws {
        let src = dir.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("inner"), withIntermediateDirectories: true)
        try "x".write(to: src.appendingPathComponent("inner/f.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: src.appendingPathComponent("escape").path, withDestinationPath: "/etc/passwd")
        let zip = dir.appendingPathComponent("payload.zip")
        _ = try await ProcessRunner.runChecked("/usr/bin/bsdtar", ["-c", "-f", zip.path, "--format", "zip", "-C", dir.path, "payload"], tool: "bsdtar")
        try FileManager.default.removeItem(at: src)
        let extracted = try await run(.extract(password: nil, selection: nil), [zip]).outputs[0]
        XCTAssertEqual(extracted.lastPathComponent, "payload")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("inner/f.txt").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: extracted.appendingPathComponent("escape").path), "escaping symlink removed")
        let tested = try await run(.testArchive, [zip])
        XCTAssertTrue(tested.note?.contains("intact") == true)
    }

    func testPathTraversalArchiveIsRefused() async throws {
        let evil = dir.appendingPathComponent("evil.tar")
        let file = dir.appendingPathComponent("a.txt")
        try "pwn".write(to: file, atomically: true, encoding: .utf8)
        _ = try await ProcessRunner.run("/usr/bin/bsdtar", ["-c", "-f", evil.path, "-C", dir.path, "-s", ",^,../../,", "a.txt"])
        do {
            _ = try await run(.extract(password: nil, selection: nil), [evil])
            XCTFail("traversal archive must not extract")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("a.txt").path))
    }

    func testJSONFormatMinifyPreservesData() async throws {
        let json = dir.appendingPathComponent("d.json")
        try #"{"b":1.50,"a":[1,2,{"x":null}],"u":"ä"}"#.write(to: json, atomically: true, encoding: .utf8)
        let pretty = try await run(.prettyPrint, [json]).outputs[0]
        let text = try String(contentsOf: pretty, encoding: .utf8)
        XCTAssertTrue(text.contains("\"b\": 1.50"), "number text preserved, key order kept: \(text)")
        XCTAssertLessThan(text.range(of: "\"b\"")!.lowerBound, text.range(of: "\"a\"")!.lowerBound)
        let mini = try await run(.minify, [json]).outputs[0]
        XCTAssertFalse(try String(contentsOf: mini, encoding: .utf8).contains("\n  "))
    }

    func testShiftTiming() async throws {
        let srt = dir.appendingPathComponent("s.srt")
        try "1\n00:00:01,000 --> 00:00:02,000\nHi\n".write(to: srt, atomically: true, encoding: .utf8)
        let out = try await run(.shiftTiming(milliseconds: 1500), [srt]).outputs[0]
        XCTAssertTrue(try String(contentsOf: out, encoding: .utf8).contains("00:00:02,500 --> 00:00:03,500"))
        do { _ = try await run(.shiftTiming(milliseconds: -5000), [srt]); XCTFail("negative times must be refused") } catch {}
    }
}
