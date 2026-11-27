import AppKit
import AVFoundation
import CryptoKit
import CoreGraphics
import Foundation
import ImageIO
import PDFKit
@testable import MacFlow

/// Generates real sample files for every input format the app claims to
/// read. Formats that need an optional helper are created only when the
/// helper is present; the report states which were skipped.
enum Fixtures {

    struct Fixture {
        let url: URL
        let expectedFormat: String
    }

    static func makeAll(in dir: URL) async throws -> (fixtures: [Fixture], skipped: [String]) {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var list: [Fixture] = []
        var skipped: [String] = []
        func add(_ name: String, _ format: String) { list.append(Fixture(url: dir.appendingPathComponent(name), expectedFormat: format)) }

        // Images
        let photo = testImage(width: 640, height: 400, alpha: false)
        let alpha = testImage(width: 320, height: 240, alpha: true)
        try writeImage(photo, to: dir.appendingPathComponent("Photo Ü 1.jpg"), type: "public.jpeg", properties: [
            kCGImagePropertyOrientation: 6,
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFArtist: "Test Author", kCGImagePropertyTIFFMake: "MacFlow", kCGImagePropertyTIFFModel: "Fixture"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2024:05:31 14:30:00"],
            kCGImagePropertyGPSDictionary: [kCGImagePropertyGPSLatitude: 47.37, kCGImagePropertyGPSLatitudeRef: "N",
                                            kCGImagePropertyGPSLongitude: 8.54, kCGImagePropertyGPSLongitudeRef: "E"],
        ])
        add("Photo Ü 1.jpg", "jpg")
        try writeImage(alpha, to: dir.appendingPathComponent("alpha.png"), type: "public.png"); add("alpha.png", "png")
        try writeImage(photo, to: dir.appendingPathComponent("photo.heic"), type: "public.heic"); add("photo.heic", "heic")
        try writeImage(alpha, to: dir.appendingPathComponent("photo.bmp"), type: "com.microsoft.bmp"); add("photo.bmp", "bmp")
        try writeImage(alpha, to: dir.appendingPathComponent("photo.avif"), type: "public.avif"); add("photo.avif", "avif")
        try writeImage(photo, to: dir.appendingPathComponent("photo.jp2"), type: "public.jpeg-2000"); add("photo.jp2", "jp2")
        try writeImage(testImage(width: 64, height: 64, alpha: true), to: dir.appendingPathComponent("icon.ico"), type: "com.microsoft.ico"); add("icon.ico", "ico")
        try writeImage(testImage(width: 512, height: 512, alpha: true), to: dir.appendingPathComponent("icon.icns"), type: "com.apple.icns"); add("icon.icns", "icns")
        try writeImage(alpha, to: dir.appendingPathComponent("layer.psd"), type: "com.adobe.photoshop-image"); add("layer.psd", "psd")
        try writeImage(alpha, to: dir.appendingPathComponent("photo.tga"), type: "com.truevision.tga-image"); add("photo.tga", "tga")
        try writeFrames([photo, testImage(width: 640, height: 400, alpha: false, hue: 0.5)], to: dir.appendingPathComponent("pages.tiff"), type: "public.tiff")
        add("pages.tiff", "tiff")
        try writeAnimatedGIF(dir.appendingPathComponent("anim.gif")); add("anim.gif", "gif")
        try svg.write(to: dir.appendingPathComponent("vector.svg"), atomically: true, encoding: .utf8); add("vector.svg", "svg")
        if let cwebp = EngineCapabilities.shared.cwebp {
            let png = dir.appendingPathComponent("webp-src.png")
            try writeImage(alpha, to: png, type: "public.png")
            _ = try await ProcessRunner.run(cwebp.path, ["-quiet", "-q", "80", png.path, "-o", dir.appendingPathComponent("photo.webp").path])
            try? FileManager.default.removeItem(at: png)
            add("photo.webp", "webp")
        } else { skipped.append("webp (no encoder to create a sample)") }
        // Extension lies about content: must be detected as PNG.
        try writeImage(alpha, to: dir.appendingPathComponent("misnamed.jpg"), type: "public.png"); add("misnamed.jpg", "png")

        // PDF
        let pdfText = NSAttributedString(string: (1...160).map { "Line \($0): The quick brown fox jumps over the lazy dog." }.joined(separator: "\n"),
                                         attributes: DocumentEngine.baseAttributes)
        try PDFTextRenderer.render(pdfText, to: dir.appendingPathComponent("document.pdf"), title: "Fixture")
        add("document.pdf", "pdf")
        try writeScannedPDF(dir.appendingPathComponent("scan.pdf")); add("scan.pdf", "pdf")

        // Documents
        let rich = NSMutableAttributedString(string: "Heading\n", attributes: [.font: NSFont.boldSystemFont(ofSize: 24)])
        rich.append(NSAttributedString(string: "Body text with ", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        rich.append(NSAttributedString(string: "bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)]))
        rich.append(NSAttributedString(string: " and Unicode: äöü 日本 🍊.\n", attributes: [.font: NSFont.systemFont(ofSize: 12)]))
        let range = NSRange(location: 0, length: rich.length)
        try rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]).write(to: dir.appendingPathComponent("rich.rtf")); add("rich.rtf", "rtf")
        try rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML]).write(to: dir.appendingPathComponent("word.docx")); add("word.docx", "docx")
        try rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.docFormat]).write(to: dir.appendingPathComponent("legacy.doc")); add("legacy.doc", "doc")
        try rich.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.openDocument]).write(to: dir.appendingPathComponent("open.odt")); add("open.odt", "odt")
        try rich.fileWrapper(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtfd])
            .write(to: dir.appendingPathComponent("package.rtfd"), options: [], originalContentsURL: nil); add("package.rtfd", "rtfd")
        try "Plain text\n\nSecond paragraph with äöü.\n".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8); add("notes.txt", "txt")
        try markdown.write(to: dir.appendingPathComponent("readme.md"), atomically: true, encoding: .utf8); add("readme.md", "md")
        try "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>T</title></head><body><h1>Title</h1><p>Hello <b>world</b> äöü</p><ul><li>One</li><li>Two</li></ul></body></html>"
            .write(to: dir.appendingPathComponent("page.html"), atomically: true, encoding: .utf8); add("page.html", "html")

        // Spreadsheets & data
        try "name,age,city\n\"Doe, Jane\",42,Zürich\nBob,007,\"Multi\nLine\"\n".write(to: dir.appendingPathComponent("table.csv"), atomically: true, encoding: .utf8); add("table.csv", "csv")
        try "a\tb\n1\t2\n".write(to: dir.appendingPathComponent("table.tsv"), atomically: true, encoding: .utf8); add("table.tsv", "tsv")
        try await writeXLSX(dir.appendingPathComponent("book.xlsx")); add("book.xlsx", "xlsx")
        try #"[{"id": 1, "name": "Ä", "price": 12.50, "tags": ["a", "b"], "nested": {"x": null}}, {"id": 2, "name": "B", "price": 1e3, "tags": [], "nested": {"x": true}}]"#
            .write(to: dir.appendingPathComponent("data.json"), atomically: true, encoding: .utf8); add("data.json", "json")
        try "# config\nname: MacFlow\nversion: 2\nratio: 0.5\nenabled: true\nempty: ~\nlist:\n  - one\n  - two: 2\n    three: 3\nblock: |\n  line one\n  line two\nflow: [1, 2, {a: b}]\n"
            .write(to: dir.appendingPathComponent("config.yaml"), atomically: true, encoding: .utf8); add("config.yaml", "yaml")
        try PropertyListSerialization.data(fromPropertyList: ["Name": "MacFlow", "Count": 3, "Enabled": true, "Items": ["a", "b"]], format: .xml, options: 0)
            .write(to: dir.appendingPathComponent("settings.plist")); add("settings.plist", "plist")
        try "<?xml version=\"1.0\"?><catalog><book id=\"1\"><title>A</title></book><book id=\"2\"><title>B</title></book></catalog>"
            .write(to: dir.appendingPathComponent("catalog.xml"), atomically: true, encoding: .utf8); add("catalog.xml", "xml")

        // Subtitles
        try "1\n00:00:01,000 --> 00:00:02,500\nHello <i>world</i>\n\n2\n00:00:03,001 --> 00:00:04,999\nSecond line\nwith two rows\n"
            .write(to: dir.appendingPathComponent("movie.srt"), atomically: true, encoding: .utf8); add("movie.srt", "srt")
        try "WEBVTT\n\nNOTE comment\n\n00:01.000 --> 00:02.500 align:start\n<v Bob>Hello</v>\n\n00:00:03.001 --> 00:00:04.999\nSecond\n"
            .write(to: dir.appendingPathComponent("movie.vtt"), atomically: true, encoding: .utf8); add("movie.vtt", "vtt")
        try "0:00:01.000,0:00:02.500\nHello\n\n0:00:03.001,0:00:04.999\nSecond\n".write(to: dir.appendingPathComponent("movie.sbv"), atomically: true, encoding: .utf8); add("movie.sbv", "sbv")
        try "[Script Info]\nTitle: T\n\n[Events]\nFormat: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text\nDialogue: 0,0:00:01.00,0:00:02.50,Default,,0,0,0,,{\\b1}Hello{\\b0}, world\\Nsecond\n"
            .write(to: dir.appendingPathComponent("movie.ass"), atomically: true, encoding: .utf8); add("movie.ass", "ass")
        try "[ti:Song]\n[00:01.00]First line\n[00:03.50]Second line\n".write(to: dir.appendingPathComponent("song.lrc"), atomically: true, encoding: .utf8); add("song.lrc", "lrc")

        // Archives
        let content = dir.appendingPathComponent("archive-src", isDirectory: true)
        try FileManager.default.createDirectory(at: content.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "alpha".write(to: content.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "beta".write(to: content.appendingPathComponent("sub/b.txt"), atomically: true, encoding: .utf8)
        for (name, args, fmt) in [("files.zip", ["--format", "zip"], "zip"), ("files.7z", ["--format", "7zip"], "7z"), ("files.tar", ["--format", "pax"], "tar"),
                                  ("files.tar.gz", ["-z"], "tgz"), ("files.tar.bz2", ["-j"], "tbz2"), ("files.tar.xz", ["-J"], "txz")] {
            _ = try await ProcessRunner.runChecked("/usr/bin/bsdtar", ["-c", "-f", dir.appendingPathComponent(name).path] + args + ["-C", dir.path, "archive-src"], tool: "bsdtar")
            add(name, fmt)
        }
        let folder = dir.appendingPathComponent("Folder With Spaces", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try "x".write(to: folder.appendingPathComponent("inside.txt"), atomically: true, encoding: .utf8)
        add("Folder With Spaces", "folder")

        // Media
        try await writeMovie(dir.appendingPathComponent("clip.mov"), type: .mov, codec: .hevc); add("clip.mov", "mov")
        try await writeMovie(dir.appendingPathComponent("clip.mp4"), type: .mp4, codec: .h264); add("clip.mp4", "mp4")
        try await writeMovie(dir.appendingPathComponent("clip.m4v"), type: .m4v, codec: .h264); add("clip.m4v", "m4v")
        try writeAudio(dir.appendingPathComponent("tone.wav"), settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]); add("tone.wav", "wav")
        try writeAudio(dir.appendingPathComponent("tone.aiff"), settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: true]); add("tone.aiff", "aiff")
        try writeAudio(dir.appendingPathComponent("tone.flac"), settings: [AVFormatIDKey: kAudioFormatFLAC, AVEncoderBitDepthHintKey: 24]); add("tone.flac", "flac")
        try writeAudio(dir.appendingPathComponent("tone.m4a"), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVEncoderBitRateKey: 192_000]); add("tone.m4a", "m4a")
        try writeAudio(dir.appendingPathComponent("tone.caf"), settings: [AVFormatIDKey: kAudioFormatAppleLossless, AVEncoderBitDepthHintKey: 16]); add("tone.caf", "caf")
        if let oggenc = EngineCapabilities.shared.oggenc {
            _ = try await ProcessRunner.runChecked(oggenc.path, ["--quiet", "-q", "5", "-o", dir.appendingPathComponent("tone.ogg").path,
                                                                dir.appendingPathComponent("tone.wav").path], tool: "oggenc")
            add("tone.ogg", "ogg")
        } else {
            skipped.append("ogg (oggenc not available to create a sample)")
        }
        if let ffmpeg = EngineCapabilities.shared.ffmpeg {
            let wav = dir.appendingPathComponent("tone.wav").path
            for (name, codec, fmt) in [("tone.mp3", "libmp3lame", "mp3"), ("tone.opus", "libopus", "opus")] where EngineCapabilities.shared.ffmpegHasEncoder(codec) {
                _ = try await ProcessRunner.run(ffmpeg.path, ["-nostdin", "-y", "-loglevel", "error", "-i", wav, "-c:a", codec, dir.appendingPathComponent(name).path])
                add(name, fmt)
            }
            let mp4 = dir.appendingPathComponent("clip.mp4").path
            _ = try await ProcessRunner.run(ffmpeg.path, ["-nostdin", "-y", "-loglevel", "error", "-i", mp4, "-c", "copy", dir.appendingPathComponent("clip.mkv").path]); add("clip.mkv", "mkv")
            if EngineCapabilities.shared.ffmpegHasEncoder("libvpx-vp9") {
                _ = try await ProcessRunner.run(ffmpeg.path, ["-nostdin", "-y", "-loglevel", "error", "-i", mp4, "-c:v", "libvpx-vp9", "-b:v", "300k", "-c:a", "libopus", dir.appendingPathComponent("clip.webm").path])
                add("clip.webm", "webm")
            }
            _ = try await ProcessRunner.run(ffmpeg.path, ["-nostdin", "-y", "-loglevel", "error", "-i", mp4, "-c:v", "mpeg4", "-c:a", "mp2", dir.appendingPathComponent("clip.avi").path]); add("clip.avi", "avi")
        } else {
            skipped.append("mp3, opus, mkv, webm, avi (FFmpeg not available to create samples)")
        }
        return (list, skipped)
    }

    // MARK: - Builders

    static func testImage(width: Int, height: Int, alpha: Bool, hue: CGFloat = 0.6) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        if alpha { ctx.clear(CGRect(x: 0, y: 0, width: width, height: height)) }
        let colors = [NSColor(hue: hue, saturation: 0.8, brightness: 0.9, alpha: 1).cgColor, NSColor(hue: hue + 0.2, saturation: 0.7, brightness: 0.6, alpha: 1).cgColor]
        let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colors: colors as CFArray, locations: [0, 1])!
        if alpha {
            ctx.addEllipse(in: CGRect(x: width / 8, y: height / 8, width: width * 3 / 4, height: height * 3 / 4)); ctx.clip()
        }
        ctx.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: width, y: height), options: [])
        // Top-left marker (red) to detect orientation and crop errors.
        ctx.resetClip()
        ctx.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: height - height / 5, width: width / 5, height: height / 5))
        return ctx.makeImage()!
    }

    static func writeImage(_ image: CGImage, to url: URL, type: String, properties: [CFString: Any] = [:]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, 1, nil) else { throw MacFlowError("fixture \(type)") }
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw MacFlowError("fixture finalize \(type)") }
    }

    static func writeFrames(_ images: [CGImage], to url: URL, type: String) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, type as CFString, images.count, nil)!
        for image in images { CGImageDestinationAddImage(dest, image, nil) }
        guard CGImageDestinationFinalize(dest) else { throw MacFlowError("fixture frames") }
    }

    static func writeAnimatedGIF(_ url: URL) throws {
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "com.compuserve.gif" as CFString, 3, nil)!
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        for hue in [0.0, 0.33, 0.66] {
            CGImageDestinationAddImage(dest, testImage(width: 120, height: 80, alpha: false, hue: CGFloat(hue)),
                                       [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.2]] as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else { throw MacFlowError("fixture gif") }
    }

    static func writeScannedPDF(_ url: URL) throws {
        let size = CGSize(width: 1240, height: 1754)
        let ctx = CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
        let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        NSAttributedString(string: "Invoice Number 4711", attributes: [.font: NSFont.systemFont(ofSize: 64), .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 120, y: 1400))
        NSAttributedString(string: "Scanned document text", attributes: [.font: NSFont.systemFont(ofSize: 48), .foregroundColor: NSColor.black]).draw(at: CGPoint(x: 120, y: 1200))
        NSGraphicsContext.restoreGraphicsState()
        try ImageEngine.writePDF(pages: [(ctx.makeImage()!, CGSize(width: 595, height: 842))], to: url)
    }

    static func writeXLSX(_ url: URL) async throws {
        let root = url.deletingLastPathComponent().appendingPathComponent("xlsx-src-\(UUID().uuidString)", isDirectory: true)
        let files: [String: String] = [
            "[Content_Types].xml": #"<?xml version="1.0" encoding="UTF-8"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/worksheets/sheet2.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>"#,
            "_rels/.rels": #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>"#,
            "xl/workbook.xml": #"<?xml version="1.0" encoding="UTF-8"?><workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sales" sheetId="1" r:id="rId1"/><sheet name="Notes" sheetId="2" r:id="rId2"/></sheets></workbook>"#,
            "xl/_rels/workbook.xml.rels": #"<?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/sharedStrings" Target="sharedStrings.xml"/><Relationship Id="rId4" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>"#,
            "xl/sharedStrings.xml": #"<?xml version="1.0" encoding="UTF-8"?><sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><si><t>Product</t></si><si><t>Price</t></si><si><t>Äpfel</t></si><si><t>Date</t></si></sst>"#,
            "xl/styles.xml": #"<?xml version="1.0" encoding="UTF-8"?><styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><cellXfs count="2"><xf numFmtId="0"/><xf numFmtId="14"/></cellXfs></styleSheet>"#,
            "xl/worksheets/sheet1.xml": #"<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="s"><v>0</v></c><c r="B1" t="s"><v>1</v></c><c r="C1" t="s"><v>3</v></c></row><row r="2"><c r="A2" t="s"><v>2</v></c><c r="B2"><v>3.25</v></c><c r="C2" s="1"><v>45444</v></c></row><row r="3"><c r="A3" t="inlineStr"><is><t>Birnen</t></is></c><c r="B3"><f>B2*2</f><v>6.5</v></c></row></sheetData></worksheet>"#,
            "xl/worksheets/sheet2.xml": #"<?xml version="1.0" encoding="UTF-8"?><worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData><row r="1"><c r="A1" t="str"><v>Note</v></c><c r="B1" t="b"><v>1</v></c></row></sheetData></worksheet>"#,
        ]
        for (path, text) in files {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        _ = try await ProcessRunner.runChecked("/usr/bin/bsdtar", ["-c", "-f", url.path, "--format", "zip", "-C", root.path, "[Content_Types].xml", "_rels", "xl"], tool: "bsdtar")
        try? FileManager.default.removeItem(at: root)
    }

    /// 2-second clip with a moving square and a 440 Hz tone.
    static func writeMovie(_ url: URL, type: AVFileType, codec: AVVideoCodecType, width: Int = 320, height: Int = 240) async throws {
        try? FileManager.default.removeItem(at: url)
        let writer = try AVAssetWriter(outputURL: url, fileType: type)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: codec, AVVideoWidthKey: width, AVVideoHeightKey: height])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000])
        // Offline generation: the inputs are fed alternately, so let the
        // writer accept data without waiting to interleave.
        video.expectsMediaDataInRealTime = true
        audio.expectsMediaDataInRealTime = true
        writer.add(video); writer.add(audio)
        writer.startWriting(); writer.startSession(atSourceTime: .zero)
        let fps = 30
        let rate = 44_100.0
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        var desc: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &desc)
        let chunk = Int(rate) / fps
        var written = 0
        // Video and audio are interleaved per frame; AVAssetWriter stalls
        // one input while waiting for the other otherwise.
        for frame in 0..<(fps * 2) {
            var spins = 0
            while !video.isReadyForMoreMediaData && spins < 2000 { try await Task.sleep(nanoseconds: 1_000_000); spins += 1 }
            var buffer: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, adaptor.pixelBufferPool!, &buffer)
            if let pb = buffer {
                CVPixelBufferLockBaseAddress(pb, [])
                let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
                ctx.setFillColor(CGColor(gray: 0.15, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
                ctx.setFillColor(CGColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)); ctx.fill(CGRect(x: frame * 4, y: 80, width: 60, height: 60))
                CVPixelBufferUnlockBaseAddress(pb, [])
                adaptor.append(pb, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
            }
            spins = 0
            while !audio.isReadyForMoreMediaData && spins < 2000 { try await Task.sleep(nanoseconds: 1_000_000); spins += 1 }
            var samples = [Float](repeating: 0, count: chunk * 2)
            for i in 0..<chunk { let v = Float(sin(Double(written + i) * 2 * .pi * 440 / rate) * 0.4); samples[2 * i] = v; samples[2 * i + 1] = v }
            var block: CMBlockBuffer?
            let bytes = samples.count * 4
            CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &block)
            samples.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: bytes) }
            var sample: CMSampleBuffer?
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block!, formatDescription: desc!, sampleCount: chunk,
                                                                 presentationTimeStamp: CMTime(value: CMTimeValue(written), timescale: CMTimeScale(rate)), packetDescriptions: nil, sampleBufferOut: &sample)
            audio.append(sample!)
            written += chunk
        }
        video.markAsFinished(); audio.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? MacFlowError("fixture movie") }
    }

    static func writeAudio(_ url: URL, settings base: [String: Any], seconds: Double = 2) throws {
        var settings = base
        settings[AVSampleRateKey] = 44_100
        settings[AVNumberOfChannelsKey] = 2
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let frames = AVAudioFrameCount(44_100 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<2 { for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = Float(sin(Double(i) * 2 * .pi * 440 / 44_100) * 0.5) } }
        try file.write(from: buffer)
    }

    static let svg = """
    <svg xmlns="http://www.w3.org/2000/svg" width="200" height="120" viewBox="0 0 200 120">
      <rect x="10" y="10" width="180" height="100" rx="16" fill="#ff7a00"/>
      <circle cx="100" cy="60" r="30" fill="#ffffff"/>
    </svg>
    """

    static let markdown = """
    # MacFlow

    A **bold** statement with *emphasis*, `code` and a [link](https://example.com).

    - One
    - Two
      - Nested

    1. First
    2. Second

    > Quote

    ```swift
    let x = 1
    ```

    | A | B |
    |---|:-:|
    | 1 | 2 |
    """

    /// Content hash of a file or (recursively) a folder.
    static func sha256(_ url: URL) -> String {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        var hasher = SHA256()
        if isDir.boolValue {
            let items = (FileManager.default.enumerator(atPath: url.path)?.allObjects as? [String] ?? []).sorted()
            for item in items {
                hasher.update(data: Data(item.utf8))
                if let data = try? Data(contentsOf: url.appendingPathComponent(item)) { hasher.update(data: data) }
            }
        } else if let data = try? Data(contentsOf: url) {
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
