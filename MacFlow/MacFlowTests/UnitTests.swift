import AppKit
import XCTest
@testable import MacFlow

final class DragAndWheelTests: XCTestCase {

    /// The core Finder bug: holding ⌘ or ⌃ restricts the drag mask. The
    /// wheel must always answer with an operation inside the mask.
    func testDropOperationAlwaysInsideSourceMask() {
        XCTAssertEqual(DragDestinationView.operation(for: [.copy, .link, .generic, .move, .delete]), .copy)
        XCTAssertEqual(DragDestinationView.operation(for: .generic), .generic)   // ⌘ held
        XCTAssertEqual(DragDestinationView.operation(for: .link), .link)         // ⌃ held
        XCTAssertEqual(DragDestinationView.operation(for: .copy), .copy)         // ⌥ held
        XCTAssertEqual(DragDestinationView.operation(for: .move), [], "never ask the source to move/delete")
        for mask: NSDragOperation in [.copy, .generic, .link, [.copy, .move], [.generic, .link]] {
            XCTAssertTrue(mask.contains(DragDestinationView.operation(for: mask)))
        }
    }

    func testModeMatchingIsExact() {
        let s = AppSettings.shared
        let saved = (s.convertModifier, s.toolsModifier, s.actionsModifier)
        defer { s.convertModifier = saved.0; s.toolsModifier = saved.1; s.actionsModifier = saved.2 }
        s.resetShortcuts()
        XCTAssertEqual(s.mode(for: .shift), .convert)
        XCTAssertEqual(s.mode(for: .command), .tools)
        XCTAssertEqual(s.mode(for: .control), .actions)
        XCTAssertNil(s.mode(for: [.shift, .command]))
        XCTAssertNil(s.mode(for: []))
        XCTAssertEqual(s.mode(for: [.shift, .capsLock]), .convert, "Caps Lock is ignored")
        s.toolsModifier = "option+shift"
        XCTAssertEqual(s.mode(for: [.option, .shift]), .tools)
        XCTAssertEqual(s.mode(for: .shift), .convert)
        s.toolsModifier = "shift"
        XCTAssertTrue(s.hasModifierConflict)
    }

    @MainActor
    func testWheelHitTestingAndPaging() throws {
        let png = ClassifiedFile(url: URL(fileURLWithPath: "/x.png"), format: FormatRegistry.shared["png"], isDirectory: false, extensionMismatch: false)
        let model = RadialMenuViewModel(mode: .convert, config: .default)
        model.configure(mode: .convert, files: [png])
        XCTAssertLessThanOrEqual(model.segments.count, 8)
        let size = CGSize(width: 314, height: 314)
        let center = CGPoint(x: 157, y: 157)
        XCTAssertNil(model.segmentID(at: center, in: size), "the centre never selects")
        // Straight up hits segment 0.
        XCTAssertEqual(model.segmentID(at: CGPoint(x: 157, y: 157 - 90), in: size), model.segments[0].id)
        // Every segment is reachable at its mid angle.
        for (i, segment) in model.segments.enumerated() {
            let angle = 2 * Double.pi * Double(i) / Double(model.segments.count)
            let p = CGPoint(x: 157 + 90 * sin(angle), y: 157 - 90 * cos(angle))
            XCTAssertEqual(model.segmentID(at: p, in: size), segment.id)
        }
        model.updateHover(at: CGPoint(x: 157, y: 67), in: size)
        XCTAssertNotNil(model.committableSegment)
        model.updateHover(at: center, in: size)
        XCTAssertNil(model.committableSegment, "dropping in the centre does nothing")
        // Keyboard selection persists over the neutral centre.
        model.moveSelection(by: 1)
        model.updateHover(at: center, in: size)
        XCTAssertEqual(model.committableSegment?.id, model.segments[0].id)
    }

    @MainActor
    func testToolsWheelForImageMatchesReferenceOrder() {
        let jpg = ClassifiedFile(url: URL(fileURLWithPath: "/x.jpg"), format: FormatRegistry.shared["jpg"], isDirectory: false, extensionMismatch: false)
        let tools = ToolCatalog.tools(for: [jpg])
        XCTAssertEqual(Array(tools.primary.prefix(7)), [.compress, .metadata, .adjust, .crop, .rotate, .redact, .background])
        let model = RadialMenuViewModel(mode: .tools, config: .default)
        model.configure(mode: .tools, files: [jpg])
        XCTAssertEqual(model.segments.count, 8)
        XCTAssertEqual(model.segments.last?.label, "MORE")
    }

    func testAllSymbolsExist() {
        for tool in FileTool.allCases { XCTAssertNotNil(NSImage(systemSymbolName: tool.sfSymbol, accessibilityDescription: nil), tool.sfSymbol) }
        for action in FileAction.allCases { XCTAssertNotNil(NSImage(systemSymbolName: action.sfSymbol, accessibilityDescription: nil), action.sfSymbol) }
    }

    func testFileURLsFromPasteboard() throws {
        let pb = NSPasteboard(name: NSPasteboard.Name("MacFlowTest-\(UUID().uuidString)"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pb-\(UUID().uuidString).txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file); pb.releaseGlobally() }
        pb.clearContents()
        pb.writeObjects([file as NSURL, URL(fileURLWithPath: "/does/not/exist") as NSURL, file as NSURL])
        XCTAssertEqual(DragSessionTracker.fileURLs(on: pb), [file.standardizedFileURL])
        pb.clearContents()
        pb.setString("just text", forType: .string)
        XCTAssertTrue(DragSessionTracker.fileURLs(on: pb).isEmpty)
    }
}

final class CoreUnitTests: XCTestCase {

    func testNamingNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("names-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "orig".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        for i in 0..<3 {
            let temp = dir.appendingPathComponent("tmp\(i)")
            try "new\(i)".write(to: temp, atomically: true, encoding: .utf8)
            _ = try OutputPublisher.publish(temp, to: dir, base: "a", ext: "txt")
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8), "orig")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a (4).txt"), encoding: .utf8), "new2")
        XCTAssertEqual(OutputPublisher.sanitize("a/b:c"), "a-b-c")
        XCTAssertEqual(OutputPublisher.sanitize(".hidden"), "_hidden")
        XCTAssertEqual(OutputPublisher.baseName(of: URL(fileURLWithPath: "/x/Backup.tar.gz")), "Backup")
    }

    func testJSONParserIsLosslessAndStrict() throws {
        let value = try JSONCodec.parse(#"{"z": 1.10, "a": [true, null, "🍊"], "n": -0.5e10}"#)
        XCTAssertEqual(JSONCodec.serialize(value, pretty: false), #"{"z":1.10,"a":[true,null,"🍊"],"n":-0.5e10}"#)
        XCTAssertThrowsError(try JSONCodec.parse("{\"a\": }"))
        XCTAssertThrowsError(try JSONCodec.parse("[1,]x"))
    }

    func testYAMLRoundTripAndRejection() throws {
        let yaml = "name: MacFlow\nlist:\n  - one\n  - two: 2\n    three: [a, b]\nblock: |\n  line one\n  line two\nempty:\nquoted: \"a: b\"\n"
        let value = try YAMLCodec.parse(yaml)
        let back = try YAMLCodec.parse(YAMLCodec.serialize(value))
        XCTAssertEqual(value, back)
        guard case .object(let m) = value else { return XCTFail() }
        XCTAssertEqual(m.first { $0.0 == "block" }?.1, .string("line one\nline two\n"))
        XCTAssertEqual(m.first { $0.0 == "empty" }?.1, .null)
        XCTAssertEqual(m.first { $0.0 == "quoted" }?.1, .string("a: b"))
        XCTAssertThrowsError(try YAMLCodec.parse("a: &anchor 1\nb: *anchor\n"))
        XCTAssertThrowsError(try YAMLCodec.parse("a: 1\na: 2\n"), "duplicate keys")
        XCTAssertEqual(YAMLCodec.quoteIfNeeded("yes"), "\"yes\"", "Norway problem avoided")
    }

    func testCSVParser() {
        let rows = DelimitedText.parse("a,\"b,c\",\"d\"\"e\"\r\n1,\"multi\nline\",3\n", delimiter: ",")
        XCTAssertEqual(rows, [["a", "b,c", "d\"e"], ["1", "multi\nline", "3"]])
        XCTAssertEqual(DelimitedText.parse(DelimitedText.serialize(rows, delimiter: ","), delimiter: ","), rows)
    }

    func testSubtitleTimeParsing() {
        XCTAssertEqual(SubtitleEngine.parseTime("01:02:03,456"), 3_723_456)
        XCTAssertEqual(SubtitleEngine.parseTime("02:03.5"), 123_500)
        XCTAssertNil(SubtitleEngine.parseTime("aa:bb"))
        XCTAssertEqual(SubtitleEngine.format(3_723_456, separator: ","), "01:02:03,456")
    }

    func testMagicBytesBeatExtension() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).txt")
        try Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let c = FileClassifier.shared.classify(url)
        XCTAssertEqual(c.format?.id, "png")
        XCTAssertTrue(c.extensionMismatch)
        let empty = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data().write(to: empty)
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertNil(FileClassifier.shared.classify(empty).format, "empty files have no convertible content")
    }

    func testFFmpegEncoderParsingSkipsExperimental() {
        let text = """
        Encoders:
         V..... = Video
         ------
         V....D libx264              H.264
         A..X.D vorbis               Vorbis
         A....D libmp3lame           MP3
        """
        XCTAssertEqual(EngineCapabilities.parseEncoders(text), ["libx264", "libmp3lame"])
    }
}
