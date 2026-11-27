import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Vision

/// Image tool processing. All functions write into `destination` (a file in
/// a private work folder); publishing and validation happen in `ToolRunner`.
enum ImageTools {

    // MARK: - Frame-aware pipeline

    /// Applies `transform` to every frame of animated GIF/APNG sources (so a
    /// crop or rotation never silently drops the animation) and to the
    /// primary image otherwise. Metadata is carried over unless stripped.
    static func process(
        source url: URL,
        to destination: URL,
        output: FileFormat,
        quality: Double,
        keepMetadata: Bool = true,
        transform: (CGImage) throws -> CGImage
    ) async throws {
        let format = FileClassifier.shared.format(of: url)
        if format?.id == "svg" {
            let image = try transform(try ImageEngine.renderSVG(url, scale: 2))
            try await write([ImageEngine.Frame(image: image, properties: [:])], to: destination, format: output, quality: quality)
            return
        }
        let source = try ImageEngine.makeSource(url)
        let count = CGImageSourceGetCount(source)
        let animated = count > 1 && (format?.supportsAnimation ?? false) && output.supportsAnimation && output.id != "webp"
        var frames: [ImageEngine.Frame] = []
        var container: [CFString: Any] = [:]
        if animated {
            for index in 0..<count {
                try Task.checkCancellation()
                var props: [CFString: Any] = [:]
                if let delay = ImageEngine.frameDelay(source, index: index) {
                    props = ImageEngine.animationProperties(for: output, delay: delay)
                }
                frames.append(ImageEngine.Frame(image: try transform(try ImageEngine.orientedImage(source, index: index)), properties: props))
            }
            container = ImageEngine.loopProperties(for: output)
        } else {
            let index = ImageEngine.primaryIndex(source)
            let image = try transform(try ImageEngine.orientedImage(source, index: index))
            frames = [ImageEngine.Frame(image: image, properties: keepMetadata ? ImageEngine.metadataForWriting(source, index: index) : [:])]
        }
        try await write(frames, to: destination, format: output, quality: quality, container: container)
    }

    static func write(_ frames: [ImageEngine.Frame], to destination: URL, format: FileFormat, quality: Double, container: [CFString: Any] = [:]) async throws {
        if format.id == "webp" {
            guard let first = frames.first else { return }
            try await WebPEncoder.encode(image: first.image, destination: destination, quality: quality)
            return
        }
        if format.id == "pdf" {
            try ImageEngine.writePDF(pages: frames.map { ($0.image, CGSize(width: $0.image.width, height: $0.image.height)) }, to: destination)
            return
        }
        try ImageEngine.write(frames, to: destination, format: format, quality: quality, containerProperties: container)
    }

    // MARK: - Compress

    struct CompressResult { let bytes: Int64; let quality: Double }

    static func compress(source url: URL, sourceFormat: FileFormat, settings: CompressSettings, destination: URL) async throws -> CompressResult {
        let output = compressOutputFormat(sourceFormat: sourceFormat, settings: settings)
        let originalSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        let loaded = try ImageEngine.load(url)
        var image = loaded.image
        if let maxSide = settings.maxDimension, max(image.width, image.height) > maxSide {
            let scale = Double(maxSide) / Double(max(image.width, image.height))
            image = try ImageEngine.resize(image, width: max(1, Int((Double(image.width) * scale).rounded())), height: max(1, Int((Double(image.height) * scale).rounded())))
        }
        let metadata: [CFString: Any] = settings.stripMetadata || loaded.source == nil ? [:] : ImageEngine.metadataForWriting(loaded.source!, index: 0)

        var quality = settings.quality
        if let target = settings.targetBytes {
            guard !output.isLossless else {
                throw MacFlowError("A target size needs a lossy format.", detail: "Choose JPEG, HEIC, WebP or AVIF.")
            }
            guard output.id != "webp" else {
                throw MacFlowError("Target size is not available for WebP.", detail: "Use the quality slider instead.")
            }
            // Binary search for the highest quality that fits.
            var low = 0.02, high = 0.98, best: Double?
            for _ in 0..<9 {
                try Task.checkCancellation()
                let mid = (low + high) / 2
                guard let data = ImageEngine.encodeData(image, format: output, quality: mid, properties: metadata) else {
                    throw MacFlowError.encode(output.label)
                }
                if Int64(data.count) <= target { best = mid; low = mid } else { high = mid }
            }
            guard let found = best else {
                let minimum = ImageEngine.encodeData(image, format: output, quality: 0.02, properties: metadata)?.count ?? 0
                throw MacFlowError("The target size cannot be reached.",
                                   detail: "The smallest possible result is \(ByteCountFormatter.string(fromByteCount: Int64(minimum), countStyle: .file)). Reduce the dimensions or raise the target.")
            }
            quality = found
        }
        try await write([ImageEngine.Frame(image: image, properties: metadata)], to: destination, format: output, quality: quality)
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        if let target = settings.targetBytes, size > target {
            throw MacFlowError("The target size cannot be reached.", detail: "The result is \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)).")
        }
        if size >= originalSize && settings.maxDimension == nil && output == sourceFormat {
            throw MacFlowError("Compression would not make this image smaller.",
                               detail: "Lower the quality, reduce the dimensions or choose another format.")
        }
        return CompressResult(bytes: size, quality: quality)
    }

    static func compressOutputFormat(sourceFormat: FileFormat, settings: CompressSettings) -> FileFormat {
        if let id = settings.format.formatID, let f = FormatRegistry.shared.format(for: id) { return f }
        return ImageToolOutput.format(for: sourceFormat, hasAlpha: true)
    }

    /// Encodes in memory to report the exact resulting size.
    static func estimateSize(image: CGImage, format: FileFormat, quality: Double) -> Int64? {
        guard format.id != "webp", let data = ImageEngine.encodeData(image, format: format, quality: quality) else { return nil }
        return Int64(data.count)
    }

    // MARK: - Geometry

    /// Crops with a normalised rect (top-left origin) in displayed coordinates.
    static func crop(_ image: CGImage, normalized rect: CGRect) throws -> CGImage {
        let r = rect.standardized
        let px = CGRect(
            x: (r.minX * CGFloat(image.width)).rounded(),
            y: (r.minY * CGFloat(image.height)).rounded(),
            width: (r.width * CGFloat(image.width)).rounded(),
            height: (r.height * CGFloat(image.height)).rounded()
        ).intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard px.width >= 1, px.height >= 1, let cropped = image.cropping(to: px) else {
            throw MacFlowError("The crop area is empty.")
        }
        return cropped
    }

    static func rotate(_ image: CGImage, _ settings: RotateSettings) throws -> CGImage {
        try ImageEngine.applyOrientation(image, Int32(Orientation.exif(settings.transform)))
    }

    /// Lossless rotation for formats whose viewers honour EXIF orientation:
    /// only the orientation tag changes, compressed image data is copied.
    static func rotateLosslessly(source url: URL, settings: RotateSettings, destination: URL, format: FileFormat) throws {
        let source = try ImageEngine.makeSource(url)
        let current = Orientation.element(exif: Int(ImageEngine.orientation(of: source, index: 0)))
        let combined = Orientation.exif(Orientation.compose(settings.transform, after: current))
        guard let type = CGImageSourceGetType(source),
              let dest = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else {
            throw MacFlowError.encode(format.label)
        }
        let options: [CFString: Any] = [
            kCGImageDestinationOrientation: combined,
            kCGImageDestinationMergeMetadata: true,
        ]
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) else {
            throw MacFlowError.encode(format.label, error?.takeRetainedValue().localizedDescription)
        }
    }

    // MARK: - Adjust

    static func adjust(_ image: CGImage, _ settings: AdjustSettings) throws -> CGImage {
        let ci = CIImage(cgImage: image)
        let auto = settings.auto ? ci.autoAdjustmentFilters(options: [.redEye: false]) : []
        let output = settings.apply(to: ci, autoFilters: auto)
        let space = image.colorSpace?.supportsOutput == true ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let result = ImageEngine.ciContext.createCGImage(output, from: ci.extent, format: image.bitsPerComponent > 8 ? .RGBA16 : .RGBA8, colorSpace: space) else {
            throw MacFlowError("The edit could not be rendered.")
        }
        return result
    }

    // MARK: - Background

    static func addBackground(_ image: CGImage, _ s: BackgroundSettings) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let pad = (max(w, h) * s.padding).rounded()
        var canvasW = w + pad * 2, canvasH = h + pad * 2
        if let ratio = s.aspect.ratio {
            if canvasW / canvasH > ratio { canvasH = (canvasW / ratio).rounded() } else { canvasW = (canvasH * ratio).rounded() }
        }
        guard canvasW * canvasH < 400_000_000,
              let ctx = ImageEngine.makeContext(width: Int(canvasW), height: Int(canvasH), like: image, opaque: true) else {
            throw MacFlowError("The canvas would be too large.")
        }
        let canvas = CGRect(x: 0, y: 0, width: canvasW, height: canvasH)
        switch s.style {
        case .solid:
            ctx.setFillColor(s.color1.cgColor)
            ctx.fill(canvas)
        case .gradient:
            let space = CGColorSpace(name: CGColorSpace.sRGB)!
            let gradient = CGGradient(colorsSpace: space, colors: [s.color1.cgColor, s.color2.cgColor] as CFArray, locations: [0, 1])!
            let radians = s.angle * .pi / 180
            let center = CGPoint(x: canvasW / 2, y: canvasH / 2)
            let half = (abs(canvasW * cos(radians)) + abs(canvasH * sin(radians))) / 2
            let dx = cos(radians) * half, dy = sin(radians) * half
            ctx.drawLinearGradient(gradient, start: CGPoint(x: center.x - dx, y: center.y + dy), end: CGPoint(x: center.x + dx, y: center.y - dy),
                                   options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        let imageRect = CGRect(x: ((canvasW - w) / 2).rounded(), y: ((canvasH - h) / 2).rounded(), width: w, height: h)
        let radius = min(w, h) * s.cornerRadius
        let path = CGPath(roundedRect: imageRect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if s.shadow {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -max(w, h) * 0.012), blur: max(w, h) * 0.04,
                          color: CGColor(gray: 0, alpha: 0.35))
            ctx.addPath(path)
            ctx.setFillColor(CGColor(gray: 1, alpha: 1))
            ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.interpolationQuality = .high
        ctx.draw(image, in: imageRect)
        ctx.restoreGState()
        guard let result = ctx.makeImage() else { throw MacFlowError("The background could not be rendered.") }
        return result
    }

    // MARK: - Redact

    static func redact(_ image: CGImage, _ s: RedactSettings) throws -> CGImage {
        let regions = s.regions.filter(\.enabled)
        guard !regions.isEmpty else { throw MacFlowError("No areas are selected for redaction.") }
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = ImageEngine.makeContext(width: image.width, height: image.height, like: image) else {
            throw MacFlowError("Could not allocate memory for the image.")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let ci = CIImage(cgImage: image)
        for region in regions {
            // Normalised top-left → Core Graphics bottom-left pixels, padded slightly.
            var rect = CGRect(x: region.rect.minX * w, y: (1 - region.rect.maxY) * h, width: region.rect.width * w, height: region.rect.height * h)
            rect = rect.insetBy(dx: -rect.width * 0.04, dy: -rect.height * 0.08).integral.intersection(CGRect(x: 0, y: 0, width: w, height: h))
            guard !rect.isEmpty else { continue }
            switch s.style {
            case .black:
                ctx.setFillColor(CGColor(gray: 0, alpha: 1))
                ctx.fill(rect)
            case .pixelate, .blur:
                // Heavy pixelation first so the result cannot be reversed by
                // de-blurring; the blur style softens the blocks afterwards.
                let block = max(8, max(rect.width, rect.height) / 7)
                var filtered = ci.cropped(to: rect).clampedToExtent()
                    .applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: block, kCIInputCenterKey: CIVector(x: rect.minX, y: rect.minY)])
                if s.style == .blur {
                    filtered = filtered.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: block * 0.6])
                }
                filtered = filtered.cropped(to: rect)
                guard let patch = ImageEngine.ciContext.createCGImage(filtered, from: rect) else { continue }
                ctx.draw(patch, in: rect)
            }
        }
        guard let result = ctx.makeImage() else { throw MacFlowError("The redaction could not be rendered.") }
        return result
    }

    /// Finds faces and text lines with Vision. Detection can miss items; the
    /// panel always lets the user review and add areas manually.
    static func detectSensitiveRegions(_ image: CGImage) throws -> [RedactRegion] {
        let faces = VNDetectFaceRectanglesRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([faces, text])
        var regions: [RedactRegion] = []
        for face in faces.results ?? [] {
            regions.append(RedactRegion(rect: topLeft(face.boundingBox), kind: .face))
        }
        for line in text.results ?? [] {
            regions.append(RedactRegion(rect: topLeft(line.boundingBox), kind: .text))
        }
        return regions
    }

    /// Vision's normalised bottom-left rect → normalised top-left rect.
    static func topLeft(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    // MARK: - Remove background

    static func removeBackground(_ image: CGImage) throws -> CGImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw MacFlowError("No subject was found in this image.")
        }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let output = ImageEngine.ciContext.createCGImage(ci, from: ci.extent, format: .RGBA8,
                                                               colorSpace: image.colorSpace?.supportsOutput == true ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw MacFlowError("The cut-out could not be rendered.")
        }
        return output
    }

    // MARK: - QR / barcodes

    struct DetectedCode: Identifiable, Hashable {
        let id = UUID()
        let payload: String
        let symbology: String
    }

    static func readCodes(_ image: CGImage) throws -> [DetectedCode] {
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        var seen = Set<String>()
        return (request.results ?? []).compactMap { observation in
            guard let payload = observation.payloadStringValue, !seen.contains(payload) else { return nil }
            seen.insert(payload)
            let name = observation.symbology.rawValue.replacingOccurrences(of: "VNBarcodeSymbology", with: "")
            return DetectedCode(payload: payload, symbology: name)
        }
    }

    // MARK: - Annotate

    static func annotate(_ image: CGImage, _ items: [Annotation]) throws -> CGImage {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = ImageEngine.makeContext(width: image.width, height: image.height, like: image) else {
            throw MacFlowError("Could not allocate memory for the image.")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Draw in a top-left coordinate space to match the editor.
        ctx.translateBy(x: 0, y: h)
        ctx.scaleBy(x: 1, y: -1)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ns
        AnnotationRenderer.draw(items, in: ctx, size: CGSize(width: w, height: h))
        NSGraphicsContext.restoreGraphicsState()
        guard let result = ctx.makeImage() else { throw MacFlowError("The annotations could not be rendered.") }
        return result
    }

    // MARK: - Metadata

    struct MetadataEntry: Identifiable, Hashable {
        var id: String { path }
        let group: String
        let name: String
        let value: String
        let path: String
        var removable = true
    }

    /// Tags that describe the pixels themselves; removing them is meaningless.
    static let structuralTags: Set<String> = ["PixelXDimension", "PixelYDimension", "ColorSpace", "Orientation", "ImageWidth", "ImageLength",
                                              "BitsPerSample", "SamplesPerPixel", "PhotometricInterpretation", "ComponentsConfiguration"]

    static func friendlyName(_ name: String) -> String {
        let known: [String: String] = [
            "GPSLatitude": "Latitude", "GPSLongitude": "Longitude", "GPSAltitude": "Altitude", "GPSAltitudeRef": "Altitude Reference",
            "GPSTimeStamp": "GPS Time", "GPSDateStamp": "GPS Date", "GPSSpeed": "Speed", "GPSImgDirection": "Direction",
            "GPSHPositioningError": "Position Accuracy", "GPSVersionID": "GPS Version", "GPSLatitudeRef": "Latitude Ref", "GPSLongitudeRef": "Longitude Ref",
            "PixelXDimension": "Width (px)", "PixelYDimension": "Height (px)", "creator": "Creator", "title": "Title",
            "description": "Description", "rights": "Copyright", "subject": "Keywords", "DateTimeOriginal": "Date Taken",
            "DateTimeDigitized": "Date Digitized", "CreateDate": "Created", "ModifyDate": "Modified", "MetadataDate": "Metadata Date",
            "FNumber": "Aperture (f/)", "ExposureTime": "Exposure Time", "ISOSpeedRatings": "ISO", "FocalLength": "Focal Length",
            "FocalLenIn35mmFilm": "Focal Length (35 mm)", "LensModel": "Lens", "LensMake": "Lens Maker", "Make": "Camera Maker",
            "Model": "Camera Model", "Software": "Software", "Artist": "Artist", "Copyright": "Copyright", "ImageDescription": "Description",
            "CreatorTool": "Created With", "Headline": "Headline", "City": "City", "Country": "Country",
        ]
        if let k = known[name] { return k }
        let spaced = humanize(name)
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }

    static func readMetadata(_ url: URL) throws -> [MetadataEntry] {
        let source = try ImageEngine.makeSource(url)
        guard let metadata = CGImageSourceCopyMetadataAtIndex(source, ImageEngine.primaryIndex(source), nil),
              let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return [] }
        var entries: [MetadataEntry] = []
        for tag in tags {
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String? else { continue }
            let value = describe(tag)
            guard !value.isEmpty else { continue }
            let group = name.hasPrefix("GPS") ? "Location (GPS)" : groupName(prefix)
            entries.append(MetadataEntry(group: group, name: friendlyName(name), value: value, path: "\(prefix):\(name)",
                                         removable: !structuralTags.contains(name)))
        }
        return entries.sorted { ($0.group, $0.name) < ($1.group, $1.name) }
    }

    private static func describe(_ tag: CGImageMetadataTag) -> String {
        guard let value = CGImageMetadataTagCopyValue(tag) else { return "" }
        if let s = value as? String { return s }
        if let n = value as? NSNumber { return n.stringValue }
        if let array = value as? [CGImageMetadataTag] { return array.map(describe).filter { !$0.isEmpty }.joined(separator: ", ") }
        if let dict = value as? [String: CGImageMetadataTag] {
            return dict.keys.sorted().map { "\(humanize($0)): \(describe(dict[$0]!))" }.joined(separator: "; ")
        }
        return String(describing: value)
    }

    private static func groupName(_ prefix: String) -> String {
        switch prefix {
        case "exif", "exifEX": return "Camera (EXIF)"
        case "tiff": return "Image (TIFF)"
        case "aux": return "Lens"
        case "dc", "photoshop", "Iptc4xmpCore", "xmpRights": return "Description (IPTC)"
        case "xmp", "xmpMM": return "XMP"
        default: return prefix.uppercased()
        }
    }

    private static func humanize(_ name: String) -> String {
        var out = ""
        for (i, ch) in name.enumerated() {
            let prev = out.last
            let nextIsLower = i + 1 < name.count && name[name.index(name.startIndex, offsetBy: i + 1)].isLowercase
            if i > 0, ch.isUppercase, let prev, prev.isLowercase || (prev.isUppercase && nextIsLower) { out.append(" ") }
            out.append(ch)
        }
        return out
    }

    /// Current values of the editable fields. Read through the XMP view of
    /// ImageIO, which unifies EXIF, TIFF, IPTC and XMP for every format
    /// (PNG keeps text in XMP only).
    static func readFields(_ url: URL) -> [MetadataField: String] {
        guard let source = try? ImageEngine.makeSource(url) else { return [:] }
        let index = ImageEngine.primaryIndex(source)
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let meta = CGImageSourceCopyMetadataAtIndex(source, index, nil)
        func xmp(_ dict: CFString, _ key: CFString, joiner: String = ", ") -> String? {
            guard let meta, let tag = CGImageMetadataCopyTagMatchingImageProperty(meta, dict, key) else { return nil }
            let values = metadataStrings(CGImageMetadataTagCopyValue(tag))
            let joined = values.joined(separator: joiner)
            return joined.isEmpty ? nil : joined
        }
        var fields: [MetadataField: String] = [:]
        fields[.title] = xmp(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName)
        fields[.description] = xmp(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription)
        fields[.author] = xmp(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist)
        fields[.copyright] = xmp(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCopyrightNotice)
        fields[.keywords] = xmp(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords)
        if let date = xmp(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal) {
            fields[.dateTaken] = exifDate(date)
        }
        fields[.make] = xmp(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake)
        fields[.model] = xmp(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel)
        let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
        func coordinate(_ value: Any?, _ ref: Any?, negative: String) -> String? {
            let number = (value as? Double) ?? (value as? String).flatMap(Double.init)
            guard let number else { return nil }
            return String(format: "%.6f", (ref as? String) == negative ? -number : number)
        }
        fields[.latitude] = coordinate(gps[kCGImagePropertyGPSLatitude], gps[kCGImagePropertyGPSLatitudeRef], negative: "S")
            ?? xmp(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude).flatMap(xmpCoordinate)
        fields[.longitude] = coordinate(gps[kCGImagePropertyGPSLongitude], gps[kCGImagePropertyGPSLongitudeRef], negative: "W")
            ?? xmp(kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude).flatMap(xmpCoordinate)
        return fields.filter { !$0.value.isEmpty }
    }

    /// Flattens XMP values (strings, arrays, language alternatives).
    static func metadataStrings(_ value: CFTypeRef?) -> [String] {
        guard let value else { return [] }
        if let s = value as? String { return [s] }
        if let n = value as? NSNumber { return [n.stringValue] }
        if let tags = value as? [CGImageMetadataTag] { return tags.flatMap { metadataStrings(CGImageMetadataTagCopyValue($0)) } }
        if let dict = value as? [String: CGImageMetadataTag] {
            if let preferred = dict["x-default"] { return metadataStrings(CGImageMetadataTagCopyValue(preferred)) }
            return dict.keys.sorted().flatMap { metadataStrings(CGImageMetadataTagCopyValue(dict[$0]!)) }
        }
        if CFGetTypeID(value) == CGImageMetadataTagGetTypeID() { return metadataStrings(CGImageMetadataTagCopyValue(value as! CGImageMetadataTag)) }
        return []
    }

    /// XMP dates ("2024-05-31T14:30:00") shown in EXIF form ("2024:05:31 14:30:00").
    static func exifDate(_ value: String) -> String {
        guard value.count >= 19, value.contains("-") else { return value }
        let chars = Array(value.prefix(19))
        return String(chars[0..<4]) + ":" + String(chars[5..<7]) + ":" + String(chars[8..<10]) + " " + String(chars[11..<19])
    }

    /// XMP GPS coordinate "47,22.2N" → "47.370000".
    static func xmpCoordinate(_ value: String) -> String? {
        guard let ref = value.last, "NSEW".contains(ref) else { return nil }
        let parts = value.dropLast().split(separator: ",").compactMap { Double($0) }
        guard !parts.isEmpty else { return nil }
        var degrees = parts[0]
        if parts.count > 1 { degrees += parts[1] / 60 }
        if parts.count > 2 { degrees += parts[2] / 3600 }
        if ref == "S" || ref == "W" { degrees = -degrees }
        return String(format: "%.6f", degrees)
    }

    /// Writes edited metadata. JPEG, HEIC, PNG and TIFF are updated without
    /// re-encoding the image data (TIFF GPS uses a second lossless pass).
    static func writeMetadata(source url: URL, edit: MetadataEdit, destination: URL) throws {
        let source = try ImageEngine.makeSource(url)
        let index = ImageEngine.primaryIndex(source)
        guard let type = CGImageSourceGetType(source) else { throw MacFlowError.encode("image") }
        // PNG and TIFF keep EXIF/TIFF tags outside XMP, which a metadata copy
        // does not rewrite; they are lossless, so a property pass is used.
        if (type as String) == "public.png" || (type as String) == "public.tiff" {
            try writeMetadataByProperties(source: source, index: index, type: type, edit: edit, destination: destination)
            return
        }
        let isTIFF = (type as String) == "public.tiff"
        let orientation = Int(ImageEngine.orientation(of: source, index: index))
        let metadata: CGMutableImageMetadata
        if edit.removeAll, let existing = CGImageSourceCopyMetadataAtIndex(source, index, nil), let copy = CGImageMetadataCreateMutableCopy(existing) {
            // An empty replacement is ignored by the HEIC writer; removing every
            // tag explicitly works for all formats.
            metadata = copy
            for tag in (CGImageMetadataCopyTags(copy) as? [CGImageMetadataTag]) ?? [] {
                guard let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) else { continue }
                CGImageMetadataRemoveTagWithPath(copy, nil, "\(prefix):\(name)" as CFString)
            }
        } else if edit.removeAll {
            metadata = CGImageMetadataCreateMutable()
        } else if let existing = CGImageSourceCopyMetadataAtIndex(source, index, nil), let copy = CGImageMetadataCreateMutableCopy(existing) {
            metadata = copy
        } else {
            metadata = CGImageMetadataCreateMutable()
        }
        var gpsForTIFF: [CFString: Any] = [:]
        if !edit.removeAll {
            for path in edit.removedPaths {
                CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString)
            }
            // Coordinates are applied together so the reference letters match.
            var coordinates: [MetadataField: String] = [:]
            for (field, rawValue) in edit.fields {
                let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
                if field == .latitude || field == .longitude { coordinates[field] = value; continue }
                try apply(field, value: value, to: metadata)
            }
            if !coordinates.isEmpty {
                gpsForTIFF = try applyCoordinates(coordinates, to: metadata)
            }
            if edit.removeLocation {
                for name in gpsTagNames(metadata) { CGImageMetadataRemoveTagWithPath(metadata, nil, name as CFString) }
                gpsForTIFF = [:]
            }
        }
        // Keep the photo upright even when everything else is removed. With
        // "remove all" the tag is always written: the HEIC writer ignores a
        // completely empty replacement.
        if orientation != 1 || edit.removeAll {
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFOrientation, orientation as CFNumber)
        }
        if isTIFF {
            // The copy pass drops TIFF GPS: carry the existing location over
            // (with any edits) unless the user removes it.
            var location = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])?[kCGImagePropertyGPSDictionary] as? [CFString: Any] ?? [:]
            for (key, value) in gpsForTIFF { location[key] = value }
            for (field, keys) in [(MetadataField.latitude, [kCGImagePropertyGPSLatitude, kCGImagePropertyGPSLatitudeRef]),
                                  (.longitude, [kCGImagePropertyGPSLongitude, kCGImagePropertyGPSLongitudeRef])]
                where edit.fields[field]?.trimmingCharacters(in: .whitespaces).isEmpty == true {
                for key in keys { location.removeValue(forKey: key) }
            }
            gpsForTIFF = (edit.removeAll || edit.removeLocation) ? [:] : location
        }
        // Standard XMP edit stamp. It also guarantees the XMP block is
        // rewritten: ImageIO leaves XMP untouched when the replacement holds
        // no XMP-only tag, so cleared fields would otherwise survive in HEIC.
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        if let stamp = CGImageMetadataTagCreate(kCGImageMetadataNamespaceXMPBasic, kCGImageMetadataPrefixXMPBasic, "MetadataDate" as CFString,
                                                .string, formatter.string(from: Date()) as CFString) {
            CGImageMetadataSetTagWithPath(metadata, nil, "xmp:MetadataDate" as CFString, stamp)
        }
        var options: [CFString: Any] = [
            kCGImageDestinationMetadata: metadata,
            kCGImageDestinationMergeMetadata: false,
        ]
        if edit.removeAll || edit.removeLocation { options[kCGImageMetadataShouldExcludeGPS] = true }
        let firstPass = isTIFF && !gpsForTIFF.isEmpty
            ? destination.deletingLastPathComponent().appendingPathComponent("metadata-pass-\(UUID().uuidString).tiff")
            : destination
        defer { if firstPass != destination { try? FileManager.default.removeItem(at: firstPass) } }
        guard let dest = CGImageDestinationCreateWithURL(firstPass as CFURL, type, 1, nil) else { throw MacFlowError.encode("image") }
        var error: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, source, options as CFDictionary, &error) else {
            throw MacFlowError("The metadata could not be written.", detail: error?.takeRetainedValue().localizedDescription)
        }
        if firstPass != destination {
            // TIFF: ImageIO drops GPS when copying; add it in a lossless pass.
            let pass = try ImageEngine.makeSource(firstPass)
            guard let final = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else { throw MacFlowError.encode("TIFF") }
            CGImageDestinationAddImageFromSource(final, pass, 0, [kCGImagePropertyGPSDictionary: gpsForTIFF] as CFDictionary)
            guard CGImageDestinationFinalize(final) else { throw MacFlowError.encode("TIFF") }
        }
    }

    /// PNG/TIFF: rewrites the image from its source with an explicit set of
    /// property dictionaries. Removed keys are set to kCFNull, XMP is dropped
    /// so no stale copy can shadow the new values.
    private static func writeMetadataByProperties(source: CGImageSource, index: Int, type: CFString, edit: MetadataEdit, destination: URL) throws {
        let original = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
        let groups = [kCGImagePropertyTIFFDictionary, kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary]
        var dicts: [CFString: [CFString: Any]] = [:]
        for group in groups { dicts[group] = original[group] as? [CFString: Any] ?? [:] }
        let orientation = (original[kCGImagePropertyOrientation] as? Int) ?? 1
        let structural: Set<String> = [kCGImagePropertyTIFFOrientation as String, kCGImagePropertyExifPixelXDimension as String,
                                       kCGImagePropertyExifPixelYDimension as String, kCGImagePropertyExifColorSpace as String]
        func clear(_ group: CFString, _ key: CFString) { dicts[group]?[key] = nil }
        func put(_ group: CFString, _ key: CFString, _ value: Any?) { if let value { dicts[group]?[key] = value } else { clear(group, key) } }

        if edit.removeAll {
            for group in groups {
                dicts[group] = dicts[group]?.filter { structural.contains($0.key as String) } ?? [:]
            }
        } else {
            // Single tags chosen in the list: map their XMP path back to properties.
            if !edit.removedPaths.isEmpty, let meta = CGImageSourceCopyMetadataAtIndex(source, index, nil) {
                for group in groups {
                    for key in dicts[group]?.keys.map({ $0 }) ?? [] {
                        guard let tag = CGImageMetadataCopyTagMatchingImageProperty(meta, group, key),
                              let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag),
                              edit.removedPaths.contains("\(prefix):\(name)") else { continue }
                        clear(group, key)
                        if group == kCGImagePropertyGPSDictionary { dicts[group] = [:] }
                    }
                }
            }
            for (field, raw) in edit.fields {
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let text: String? = value.isEmpty ? nil : value
                switch field {
                case .title: put(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName, text)
                case .description:
                    put(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, text)
                    put(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCaptionAbstract, text)
                case .author:
                    let names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    put(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist, names.isEmpty ? nil : names.joined(separator: ", "))
                    put(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCByline, names.isEmpty ? nil : names)
                case .copyright:
                    put(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright, text)
                    put(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCCopyrightNotice, text)
                case .keywords:
                    let words = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    put(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords, words.isEmpty ? nil : words)
                case .dateTaken:
                    if let text, text.range(of: #"^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) == nil {
                        throw MacFlowError("“Date Taken” must look like 2024:05:31 14:30:00.")
                    }
                    put(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, text)
                case .make: put(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake, text)
                case .model: put(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel, text)
                case .latitude, .longitude:
                    let isLat = field == .latitude
                    let key = isLat ? kCGImagePropertyGPSLatitude : kCGImagePropertyGPSLongitude
                    let refKey = isLat ? kCGImagePropertyGPSLatitudeRef : kCGImagePropertyGPSLongitudeRef
                    guard let text else { clear(kCGImagePropertyGPSDictionary, key); clear(kCGImagePropertyGPSDictionary, refKey); continue }
                    guard let number = Double(text.replacingOccurrences(of: ",", with: ".")), abs(number) <= (isLat ? 90 : 180) else {
                        throw MacFlowError("\(field.label) must be a number between \(isLat ? "-90 and 90" : "-180 and 180").")
                    }
                    put(kCGImagePropertyGPSDictionary, key, abs(number))
                    put(kCGImagePropertyGPSDictionary, refKey, isLat ? (number < 0 ? "S" : "N") : (number < 0 ? "W" : "E"))
                }
            }
            if edit.removeLocation { dicts[kCGImagePropertyGPSDictionary] = [:] }
        }
        // Explicit nulls remove whatever the source carried for a key.
        var properties: [CFString: Any] = [kCGImagePropertyOrientation: orientation]
        for group in groups {
            var merged: [CFString: Any] = [:]
            for key in (original[group] as? [CFString: Any])?.keys.map({ $0 }) ?? [] { merged[key] = kCFNull }
            for (key, value) in dicts[group] ?? [:] { merged[key] = value }
            if dicts[group]?.isEmpty ?? true, group != kCGImagePropertyTIFFDictionary {
                properties[group] = kCFNull
            } else {
                properties[group] = merged
            }
        }
        if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = orientation
            properties[kCGImagePropertyTIFFDictionary] = tiff
        }
        // PNG mirrors author, title, description and copyright in its own
        // text chunks; keep them in step with the edited values.
        if (type as String) == "public.png" {
            var png = (original[kCGImagePropertyPNGDictionary] as? [CFString: Any]) ?? [:]
            let textKeys: [CFString] = [kCGImagePropertyPNGAuthor, kCGImagePropertyPNGTitle, kCGImagePropertyPNGDescription, kCGImagePropertyPNGCopyright,
                                        kCGImagePropertyPNGComment, kCGImagePropertyPNGDisclaimer, kCGImagePropertyPNGSource, kCGImagePropertyPNGWarning,
                                        kCGImagePropertyPNGSoftware, kCGImagePropertyPNGCreationTime, kCGImagePropertyPNGModificationTime]
            func text(_ group: CFString, _ key: CFString) -> Any { (dicts[group]?[key] as? String).map { $0 as Any } ?? kCFNull! }
            if edit.removeAll {
                for key in textKeys { png[key] = kCFNull }
            } else {
                png[kCGImagePropertyPNGAuthor] = text(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist)
                png[kCGImagePropertyPNGTitle] = text(kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCObjectName)
                png[kCGImagePropertyPNGDescription] = text(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription)
                png[kCGImagePropertyPNGCopyright] = text(kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright)
            }
            properties[kCGImagePropertyPNGDictionary] = png
        }
        properties[kCGImageMetadataShouldExcludeXMP] = true
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, type, 1, nil) else { throw MacFlowError.encode("image") }
        CGImageDestinationAddImageFromSource(dest, source, index, properties as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw MacFlowError("The metadata could not be written.") }
    }

    private static func gpsTagNames(_ metadata: CGImageMetadata) -> [String] {
        guard let tags = CGImageMetadataCopyTags(metadata) as? [CGImageMetadataTag] else { return [] }
        return tags.compactMap { tag in
            guard let prefix = CGImageMetadataTagCopyPrefix(tag) as String?, let name = CGImageMetadataTagCopyName(tag) as String? else { return nil }
            return name.hasPrefix("GPS") || prefix.lowercased().contains("gps") ? "\(prefix):\(name)" : nil
        }
    }

    /// Builds a well-formed XMP tag (Seq, Bag or language Alt) through
    /// ImageIO's own XMP parser. Setting plain strings on these array types
    /// produces malformed metadata that ImageIO's HEIC writer cannot handle.
    private static func parsedTag(_ name: String, container: String, values: [String]) -> CGImageMetadataTag? {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let lang = container == "Alt" ? " xml:lang=\"x-default\"" : ""
        let items = values.map { "<rdf:li\(lang)>\(escape($0))</rdf:li>" }.joined()
        let packet = "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\"><rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">"
            + "<rdf:Description rdf:about=\"\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
            + "<dc:\(name)><rdf:\(container)>\(items)</rdf:\(container)></dc:\(name)></rdf:Description></rdf:RDF></x:xmpmeta>"
        guard let parsed = CGImageMetadataCreateFromXMPData(Data(packet.utf8) as CFData) else { return nil }
        return CGImageMetadataCopyTagWithPath(parsed, nil, "dc:\(name)" as CFString)
    }

    private static func removeTwins(_ paths: [String], from metadata: CGMutableImageMetadata) {
        for path in paths { CGImageMetadataRemoveTagWithPath(metadata, nil, path as CFString) }
    }

    private static func setDublinCore(_ name: String, container: String, values: [String], in metadata: CGMutableImageMetadata) throws {
        guard !values.isEmpty else { return }
        guard let tag = parsedTag(name, container: container, values: values),
              CGImageMetadataSetTagWithPath(metadata, nil, "dc:\(name)" as CFString, tag) else {
            throw MacFlowError("The \(name) field could not be written.")
        }
    }

    private static func removeMatching(_ dict: CFString, _ key: CFString, from metadata: CGMutableImageMetadata) {
        // Several XMP tags can map to one property; remove until none is left.
        for _ in 0..<4 {
            guard let tag = CGImageMetadataCopyTagMatchingImageProperty(metadata, dict, key),
                  let prefix = CGImageMetadataTagCopyPrefix(tag), let name = CGImageMetadataTagCopyName(tag) else { return }
            CGImageMetadataRemoveTagWithPath(metadata, nil, "\(prefix):\(name)" as CFString)
        }
    }

    private static func apply(_ field: MetadataField, value: String, to metadata: CGMutableImageMetadata) throws {
        switch field {
        case .title:
            removeTwins(["dc:title"], from: metadata)
            try setDublinCore("title", container: "Alt", values: value.isEmpty ? [] : [value], in: metadata)
        case .description:
            removeTwins(["dc:description", "tiff:ImageDescription"], from: metadata)
            try setDublinCore("description", container: "Alt", values: value.isEmpty ? [] : [value], in: metadata)
        case .author:
            removeTwins(["dc:creator", "tiff:Artist"], from: metadata)
            let names = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            try setDublinCore("creator", container: "Seq", values: names, in: metadata)
        case .copyright:
            removeTwins(["dc:rights", "tiff:Copyright"], from: metadata)
            try setDublinCore("rights", container: "Alt", values: value.isEmpty ? [] : [value], in: metadata)
        case .keywords:
            removeTwins(["dc:subject"], from: metadata)
            let words = value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            try setDublinCore("subject", container: "Bag", values: words, in: metadata)
        case .dateTaken:
            if !value.isEmpty, value.range(of: #"^\d{4}:\d{2}:\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) == nil {
                throw MacFlowError("“Date Taken” must look like 2024:05:31 14:30:00.")
            }
            removeMatching(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, from: metadata)
            removeTwins(["photoshop:DateCreated"], from: metadata)
            if !value.isEmpty {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, value as CFString)
            }
        case .make, .model:
            let key = field == .make ? kCGImagePropertyTIFFMake : kCGImagePropertyTIFFModel
            removeMatching(kCGImagePropertyTIFFDictionary, key, from: metadata)
            if !value.isEmpty {
                CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyTIFFDictionary, key, value as CFString)
            }
        case .latitude, .longitude:
            break // handled by applyCoordinates
        }
    }

    /// Sets or clears latitude/longitude. Returns the GPS dictionary for the
    /// TIFF second pass.
    private static func applyCoordinates(_ values: [MetadataField: String], to metadata: CGMutableImageMetadata) throws -> [CFString: Any] {
        var gps: [CFString: Any] = [:]
        for field in [MetadataField.latitude, .longitude] {
            guard let value = values[field] else { continue }
            let isLat = field == .latitude
            let key = isLat ? kCGImagePropertyGPSLatitude : kCGImagePropertyGPSLongitude
            let refKey = isLat ? kCGImagePropertyGPSLatitudeRef : kCGImagePropertyGPSLongitudeRef
            removeMatching(kCGImagePropertyGPSDictionary, key, from: metadata)
            removeMatching(kCGImagePropertyGPSDictionary, refKey, from: metadata)
            guard !value.isEmpty else { continue }
            guard let number = Double(value.replacingOccurrences(of: ",", with: ".")), abs(number) <= (isLat ? 90 : 180) else {
                throw MacFlowError("\(field.label) must be a number between \(isLat ? "-90 and 90" : "-180 and 180").")
            }
            let ref = isLat ? (number < 0 ? "S" : "N") : (number < 0 ? "W" : "E")
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary, key, abs(number) as CFNumber)
            CGImageMetadataSetValueMatchingImageProperty(metadata, kCGImagePropertyGPSDictionary, refKey, ref as CFString)
            gps[key] = abs(number)
            gps[refKey] = ref
        }
        return gps
    }

    /// True when both files decode to identical pixels (used to prove that a
    /// metadata edit did not touch the image).
    static func pixelsIdentical(_ a: URL, _ b: URL) -> Bool {
        guard let sa = CGImageSourceCreateWithURL(a as CFURL, nil), let sb = CGImageSourceCreateWithURL(b as CFURL, nil),
              let ia = CGImageSourceCreateImageAtIndex(sa, ImageEngine.primaryIndex(sa), nil),
              let ib = CGImageSourceCreateImageAtIndex(sb, ImageEngine.primaryIndex(sb), nil),
              ia.width == ib.width, ia.height == ib.height,
              let da = ia.dataProvider?.data, let db = ib.dataProvider?.data else { return false }
        return (da as Data) == (db as Data)
    }

    // MARK: - Make PDF

    static func makePDF(_ settings: MakePDFSettings, destination: URL) async throws {
        guard !settings.order.isEmpty else { throw MacFlowError("No images were selected.") }
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(destination as CFURL, mediaBox: &box, [kCGPDFContextCreator: "MacFlow"] as CFDictionary) else {
            throw MacFlowError.encode("PDF")
        }
        let jpeg = FormatRegistry.shared["jpg"]
        for url in settings.order {
            try Task.checkCancellation()
            let loaded = try ImageEngine.load(url)
            var image = loaded.image
            // Opaque photos are embedded as JPEG to keep the PDF compact.
            if !ImageEngine.hasAlpha(image), let data = ImageEngine.encodeData(image, format: jpeg, quality: settings.jpegQuality),
               let provider = CGDataProvider(data: data as CFData),
               let embedded = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                image = embedded
            }
            let natural = ImageEngine.pageSize(for: loaded.image, properties: loaded.properties)
            var page: CGSize
            switch settings.pageSize {
            case .fit: page = CGSize(width: natural.width + settings.margin * 2, height: natural.height + settings.margin * 2)
            case .a4: page = CGSize(width: 595.28, height: 841.89)
            case .letter: page = CGSize(width: 612, height: 792)
            }
            if settings.pageSize != .fit && natural.width > natural.height { page = CGSize(width: page.height, height: page.width) }
            var pageBox = CGRect(origin: .zero, size: page)
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            let available = pageBox.insetBy(dx: settings.margin, dy: settings.margin)
            let scale = min(available.width / natural.width, available.height / natural.height, settings.pageSize == .fit ? 1 : .greatestFiniteMagnitude)
            let drawSize = CGSize(width: natural.width * scale, height: natural.height * scale)
            let rect = CGRect(x: available.midX - drawSize.width / 2, y: available.midY - drawSize.height / 2, width: drawSize.width, height: drawSize.height)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: rect)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

/// Shared drawing code for the annotation editor and the final render.
enum AnnotationRenderer {
    static func draw(_ items: [Annotation], in ctx: CGContext, size: CGSize) {
        let scale = max(size.width, size.height)
        for item in items {
            let a = CGPoint(x: item.start.x * size.width, y: item.start.y * size.height)
            let b = CGPoint(x: item.end.x * size.width, y: item.end.y * size.height)
            let lw = max(1, item.lineWidth * scale)
            ctx.saveGState()
            ctx.setStrokeColor(item.color.cgColor)
            ctx.setFillColor(item.color.cgColor)
            ctx.setLineWidth(lw)
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            switch item.kind {
            case .line:
                ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
            case .arrow:
                ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath()
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = lw * 4.5
                let p1 = CGPoint(x: b.x - head * cos(angle - .pi / 7), y: b.y - head * sin(angle - .pi / 7))
                let p2 = CGPoint(x: b.x - head * cos(angle + .pi / 7), y: b.y - head * sin(angle + .pi / 7))
                ctx.move(to: b); ctx.addLine(to: p1); ctx.addLine(to: p2); ctx.closePath(); ctx.fillPath()
            case .rectangle:
                ctx.stroke(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
            case .ellipse:
                ctx.strokeEllipse(in: CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
            case .highlight:
                ctx.setFillColor(item.color.cgColor.copy(alpha: 0.35) ?? item.color.cgColor)
                ctx.fill(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
            case .text:
                let font = NSFont.systemFont(ofSize: max(8, lw * 6), weight: .semibold)
                let attributed = NSAttributedString(string: item.text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: item.color.cgColor) ?? .red])
                attributed.draw(at: a)
            case .number:
                let radius = max(8, lw * 3.5)
                let circle = CGRect(x: a.x - radius, y: a.y - radius, width: radius * 2, height: radius * 2)
                ctx.fillEllipse(in: circle)
                let font = NSFont.systemFont(ofSize: radius * 1.1, weight: .bold)
                let text = NSAttributedString(string: "\(item.number)", attributes: [.font: font, .foregroundColor: NSColor.white])
                let ts = text.size()
                text.draw(at: CGPoint(x: a.x - ts.width / 2, y: a.y - ts.height / 2))
            }
            ctx.restoreGState()
        }
    }
}
