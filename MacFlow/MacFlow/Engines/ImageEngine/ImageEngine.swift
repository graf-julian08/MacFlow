import AppKit
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Native image pipeline built on ImageIO and Core Graphics.
///
/// Invariants every path upholds:
/// * EXIF orientation is applied to the pixels and the written orientation
///   is reset to "up", so results look right in every viewer.
/// * Colour profiles travel with the pixels (no silent sRGB conversion).
/// * Transparency is kept when the target supports it and composited on
///   white otherwise.
/// * Animated and multi-page sources keep all frames when the target can
///   hold them.
enum ImageEngine {

    static let ciContext = CIContext(options: [.cacheIntermediates: false, .useSoftwareRenderer: false])

    // MARK: - Loading

    struct LoadedImage {
        let image: CGImage           // orientation applied
        let properties: [CFString: Any]
        let source: CGImageSource?
        let frameCount: Int
    }

    static func makeSource(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0 else {
            throw MacFlowError.decode(url.lastPathComponent, "The image data is not readable.")
        }
        return source
    }

    /// Decodes frame `index` with its EXIF orientation applied.
    static func load(_ url: URL, index: Int = 0) throws -> LoadedImage {
        if FileClassifier.shared.format(of: url)?.id == "svg" {
            let image = try renderSVG(url, scale: 2)
            return LoadedImage(image: image, properties: [:], source: nil, frameCount: 1)
        }
        let source = try makeSource(url)
        let image = try orientedImage(source, index: index)
        let props = (CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]) ?? [:]
        return LoadedImage(image: image, properties: props, source: source, frameCount: CGImageSourceGetCount(source))
    }

    static func orientation(of source: CGImageSource, index: Int) -> Int32 {
        let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        if let value = props?[kCGImagePropertyOrientation] as? Int { return Int32(value) }
        if let value = props?[kCGImagePropertyOrientation] as? NSNumber { return value.int32Value }
        return 1
    }

    static func orientedImage(_ source: CGImageSource, index: Int) throws -> CGImage {
        let options: [CFString: Any] = [kCGImageSourceShouldCacheImmediately: true]
        guard let raw = CGImageSourceCreateImageAtIndex(source, index, options as CFDictionary) else {
            throw MacFlowError.decode("image", "Frame \(index + 1) could not be decoded.")
        }
        let orientation = orientation(of: source, index: index)
        guard orientation != 1 else { return raw }
        return try applyOrientation(raw, orientation)
    }

    static func applyOrientation(_ image: CGImage, _ orientation: Int32) throws -> CGImage {
        guard (2...8).contains(orientation) else { return image }
        let width = image.width, height = image.height
        let swaps = orientation >= 5
        let outW = swaps ? height : width
        let outH = swaps ? width : height
        guard let ctx = makeContext(width: outW, height: outH, like: image) else {
            throw MacFlowError("Could not allocate memory for the image.")
        }
        var t = CGAffineTransform.identity
        let w = CGFloat(width), h = CGFloat(height)
        // EXIF orientation → drawing transform (Core Graphics, origin bottom-left).
        switch orientation {
        case 2: t = CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: w, ty: 0)
        case 3: t = CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 4: t = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h)
        case 5: t = CGAffineTransform(a: 0, b: -1, c: -1, d: 0, tx: h, ty: w)
        case 6: t = CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        case 7: t = CGAffineTransform(a: 0, b: 1, c: 1, d: 0, tx: 0, ty: 0)
        case 8: t = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        default: break
        }
        ctx.concatenate(t)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let result = ctx.makeImage() else { throw MacFlowError("Could not rotate the image.") }
        return result
    }

    /// Bitmap context matching the source's colour space and depth where possible.
    static func makeContext(width: Int, height: Int, like image: CGImage?, opaque: Bool = false) -> CGContext? {
        let space: CGColorSpace = {
            if let cs = image?.colorSpace, cs.model == .rgb, cs.supportsOutput { return cs }
            if let cs = image?.colorSpace, cs.model == .monochrome { return CGColorSpace(name: CGColorSpace.sRGB)! }
            return CGColorSpace(name: CGColorSpace.sRGB)!
        }()
        let sixteen = (image?.bitsPerComponent ?? 8) > 8
        let bpc = sixteen ? 16 : 8
        var info: UInt32 = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
        if sixteen { info |= CGBitmapInfo.byteOrder16Little.rawValue }
        return CGContext(data: nil, width: width, height: height, bitsPerComponent: bpc, bytesPerRow: 0, space: space, bitmapInfo: info)
            ?? CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Composites onto a solid colour (used for formats without alpha).
    static func flatten(_ image: CGImage, on color: CGColor = CGColor(gray: 1, alpha: 1)) throws -> CGImage {
        guard let ctx = makeContext(width: image.width, height: image.height, like: image, opaque: true) else {
            throw MacFlowError("Could not allocate memory for the image.")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(color)
        ctx.fill(rect)
        ctx.draw(image, in: rect)
        guard let result = ctx.makeImage() else { throw MacFlowError("Could not flatten the image.") }
        return result
    }

    /// High-quality resample to an exact size.
    static func resize(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard width > 0, height > 0 else { throw MacFlowError("The target size is invalid.") }
        if width == image.width && height == image.height { return image }
        let ci = CIImage(cgImage: image)
        let scaleY = CGFloat(height) / CGFloat(image.height)
        let aspect = (CGFloat(width) / CGFloat(image.width)) / scaleY
        let filter = CIFilter(name: "CILanczosScaleTransform")!
        filter.setValue(ci, forKey: kCIInputImageKey)
        filter.setValue(scaleY, forKey: kCIInputScaleKey)
        filter.setValue(aspect, forKey: kCIInputAspectRatioKey)
        if let output = filter.outputImage,
           let rendered = ciContext.createCGImage(output, from: CGRect(x: 0, y: 0, width: width, height: height),
                                                  format: (image.bitsPerComponent > 8) ? .RGBA16 : .RGBA8,
                                                  colorSpace: image.colorSpace?.supportsOutput == true ? image.colorSpace : CGColorSpace(name: CGColorSpace.sRGB)) {
            return rendered
        }
        guard let ctx = makeContext(width: width, height: height, like: image) else {
            throw MacFlowError("Could not allocate memory for the image.")
        }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let result = ctx.makeImage() else { throw MacFlowError("Could not resize the image.") }
        return result
    }

    /// Fast, orientation-correct downsample for previews.
    static func thumbnail(_ url: URL, maxPixel: Int) -> CGImage? {
        if FileClassifier.shared.format(of: url)?.id == "svg" {
            return try? renderSVG(url, maxPixel: maxPixel)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: - SVG

    static func renderSVG(_ url: URL, scale: CGFloat = 2, maxPixel: Int? = nil) throws -> CGImage {
        guard let image = NSImage(contentsOf: url), image.size.width > 0, image.size.height > 0 else {
            throw MacFlowError.decode(url.lastPathComponent, "The SVG could not be rendered.")
        }
        var s = scale
        if let maxPixel {
            s = CGFloat(maxPixel) / max(image.size.width, image.size.height)
        }
        let width = max(1, min(16384, Int((image.size.width * s).rounded())))
        let height = max(1, min(16384, Int((image.size.height * s).rounded())))
        guard let ctx = makeContext(width: width, height: height, like: nil) else {
            throw MacFlowError("Could not allocate memory for the image.")
        }
        let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsctx
        image.draw(in: NSRect(x: 0, y: 0, width: width, height: height), from: .zero, operation: .sourceOver, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        guard let result = ctx.makeImage() else { throw MacFlowError("The SVG could not be rendered.") }
        return result
    }

    // MARK: - Conversion

    static func convert(
        source url: URL,
        sourceFormat: FileFormat,
        target: FileFormat,
        destination: URL,
        quality: Double,
        preserveMetadata: Bool
    ) async throws {
        try Task.checkCancellation()
        if target.id == "pdf" {
            try writePDF(from: url, sourceFormat: sourceFormat, to: destination)
            return
        }
        if target.id == "webp" {
            try await WebPEncoder.encode(source: url, sourceFormat: sourceFormat, destination: destination, quality: quality)
            return
        }
        if sourceFormat.id == "svg" {
            let image = try renderSVG(url, scale: 2)
            try write([Frame(image: image, properties: [:])], to: destination, format: target, quality: quality)
            return
        }

        let source = try makeSource(url)
        let count = CGImageSourceGetCount(source)
        let keepAllFrames = count > 1 && (target.id == "gif" || target.id == "png" || target.id == "tiff")
            && (sourceFormat.supportsAnimation || sourceFormat.supportsMultipage)
        let indices = keepAllFrames ? Array(0..<count) : [primaryIndex(source)]

        var frames: [Frame] = []
        for index in indices {
            try Task.checkCancellation()
            let image = try orientedImage(source, index: index)
            var props = preserveMetadata ? metadataForWriting(source, index: index) : [:]
            if keepAllFrames, let delay = frameDelay(source, index: index) {
                props.merge(animationProperties(for: target, delay: delay)) { _, new in new }
            }
            frames.append(Frame(image: image, properties: props))
        }
        var containerProps: [CFString: Any] = [:]
        if keepAllFrames && (target.id == "gif" || target.id == "png") {
            containerProps = loopProperties(for: target)
        }
        try write(frames, to: destination, format: target, quality: quality, containerProperties: containerProps)
    }

    /// HEIC files can contain several images; the primary one is what users see.
    static func primaryIndex(_ source: CGImageSource) -> Int {
        let props = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        if let primary = props?[kCGImagePropertyPrimaryImage] as? Int, primary < CGImageSourceGetCount(source) {
            return primary
        }
        return 0
    }

    struct Frame {
        var image: CGImage
        var properties: [CFString: Any]
    }

    /// Writes frames with ImageIO. Handles alpha, icon sizing and quality.
    static func write(
        _ frames: [Frame],
        to destination: URL,
        format: FileFormat,
        quality: Double,
        containerProperties: [CFString: Any] = [:]
    ) throws {
        guard let type = format.utTypeIdentifiers.first(where: { EngineCapabilities.shared.imageEncodeTypes.contains($0) }) else {
            throw MacFlowError.unsupported("Writing \(format.label)")
        }
        var prepared: [Frame] = []
        switch format.id {
        case "ico":
            guard let base = frames.first?.image else { return }
            let square = try squareCanvas(base)
            for size in [256, 128, 64, 48, 32, 16] where size <= max(square.width, 16) {
                prepared.append(Frame(image: try resize(square, width: size, height: size), properties: [:]))
            }
        case "icns":
            guard let base = frames.first?.image else { return }
            let square = try squareCanvas(base)
            for size in [1024, 512, 256, 128, 64, 32, 16] {
                prepared.append(Frame(image: try resize(square, width: size, height: size), properties: [:]))
            }
        default:
            for var frame in frames {
                if !format.supportsTransparency && hasAlpha(frame.image) {
                    frame.image = try flatten(frame.image)
                }
                if format.id == "jpg" || format.id == "bmp" || format.id == "gif" {
                    frame.image = try eightBit(frame.image)
                }
                prepared.append(frame)
            }
        }
        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, type as CFString, prepared.count, nil) else {
            throw MacFlowError.encode(format.label)
        }
        if !containerProperties.isEmpty {
            CGImageDestinationSetProperties(dest, containerProperties as CFDictionary)
        }
        for frame in prepared {
            var props = frame.properties
            props[kCGImagePropertyOrientation] = 1
            if !format.isLossless {
                props[kCGImageDestinationLossyCompressionQuality] = quality
            }
            CGImageDestinationAddImage(dest, frame.image, props as CFDictionary)
        }
        guard CGImageDestinationFinalize(dest) else {
            throw MacFlowError.encode(format.label, "ImageIO rejected the image data.")
        }
    }

    /// 8-bit sRGB-compatible copy for formats that cannot hold 16-bit data.
    static func eightBit(_ image: CGImage) throws -> CGImage {
        guard image.bitsPerComponent > 8 else { return image }
        let opaque = !hasAlpha(image)
        let space = (image.colorSpace?.model == .rgb && image.colorSpace?.supportsOutput == true) ? image.colorSpace! : CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw MacFlowError("Could not allocate memory for the image.")
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let result = ctx.makeImage() else { throw MacFlowError("Could not convert the bit depth.") }
        return result
    }

    /// Centres the image on a transparent square canvas (for icons).
    static func squareCanvas(_ image: CGImage) throws -> CGImage {
        let side = max(image.width, image.height)
        if image.width == image.height { return image }
        guard let ctx = makeContext(width: side, height: side, like: image) else {
            throw MacFlowError("Could not allocate memory for the image.")
        }
        ctx.clear(CGRect(x: 0, y: 0, width: side, height: side))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: (side - image.width) / 2, y: (side - image.height) / 2, width: image.width, height: image.height))
        guard let result = ctx.makeImage() else { throw MacFlowError("Could not build the icon canvas.") }
        return result
    }

    /// Source metadata safe to write into a new file: orientation reset,
    /// pixel-size fields dropped (they describe the old pixels).
    static func metadataForWriting(_ source: CGImageSource, index: Int) -> [CFString: Any] {
        guard var props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return [:] }
        for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                    kCGImagePropertyHasAlpha, kCGImagePropertyColorModel, kCGImagePropertyProfileName,
                    kCGImagePropertyGIFDictionary, kCGImagePropertyPNGDictionary, kCGImagePropertyWebPDictionary,
                    kCGImagePropertyHEICSDictionary, kCGImagePropertyFileContentsDictionary] {
            props.removeValue(forKey: key)
        }
        if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            tiff[kCGImagePropertyTIFFOrientation] = 1
            props[kCGImagePropertyTIFFDictionary] = tiff
        }
        if var exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
            exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
            props[kCGImagePropertyExifDictionary] = exif
        }
        props[kCGImagePropertyOrientation] = 1
        return props
    }

    static func frameDelay(_ source: CGImageSource, index: Int) -> Double? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] else { return nil }
        let candidates: [(CFString, CFString, CFString)] = [
            (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
            (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
            (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
            (kCGImagePropertyHEICSDictionary, kCGImagePropertyHEICSUnclampedDelayTime, kCGImagePropertyHEICSDelayTime),
        ]
        for (dict, unclamped, clamped) in candidates {
            if let d = props[dict] as? [CFString: Any] {
                if let v = d[unclamped] as? Double, v > 0 { return v }
                if let v = d[clamped] as? Double, v > 0 { return v }
            }
        }
        return nil
    }

    static func animationProperties(for format: FileFormat, delay: Double) -> [CFString: Any] {
        switch format.id {
        case "gif": return [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]]
        case "png": return [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGDelayTime: delay]]
        default: return [:]
        }
    }

    static func loopProperties(for format: FileFormat) -> [CFString: Any] {
        switch format.id {
        case "gif": return [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]]
        case "png": return [kCGImagePropertyPNGDictionary: [kCGImagePropertyAPNGLoopCount: 0]]
        default: return [:]
        }
    }

    // MARK: - PDF output

    /// Image → PDF. SVG stays vector; JPEG data is embedded without
    /// re-compression; multi-page TIFFs become multi-page PDFs.
    static func writePDF(from url: URL, sourceFormat: FileFormat, to destination: URL) throws {
        if sourceFormat.id == "svg" {
            guard let image = NSImage(contentsOf: url), image.size.width > 0 else {
                throw MacFlowError.decode(url.lastPathComponent)
            }
            var box = CGRect(origin: .zero, size: image.size)
            guard let ctx = CGContext(destination as CFURL, mediaBox: &box, nil) else { throw MacFlowError.encode("PDF") }
            ctx.beginPDFPage(nil)
            let ns = NSGraphicsContext(cgContext: ctx, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = ns
            image.draw(in: box)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPDFPage()
            ctx.closePDF()
            return
        }
        let source = try makeSource(url)
        let count = sourceFormat.supportsMultipage ? CGImageSourceGetCount(source) : 1
        var pages: [(CGImage, CGSize)] = []
        for index in (sourceFormat.supportsMultipage ? Array(0..<count) : [primaryIndex(source)]) {
            try Task.checkCancellation()
            var image = try orientedImage(source, index: index)
            if sourceFormat.id == "jpg", orientation(of: source, index: index) == 1,
               let provider = CGDataProvider(url: url as CFURL),
               let jpeg = CGImage(jpegDataProviderSource: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
                image = jpeg // Quartz embeds the original DCT stream: no quality loss
            }
            pages.append((image, pageSize(for: image, properties: CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])))
        }
        try writePDF(pages: pages, to: destination)
    }

    static func pageSize(for image: CGImage, properties: [CFString: Any]?) -> CGSize {
        let dpiX = (properties?[kCGImagePropertyDPIWidth] as? Double).flatMap { $0 > 1 ? $0 : nil } ?? 72
        let dpiY = (properties?[kCGImagePropertyDPIHeight] as? Double).flatMap { $0 > 1 ? $0 : nil } ?? 72
        var size = CGSize(width: CGFloat(image.width) * 72 / CGFloat(dpiX), height: CGFloat(image.height) * 72 / CGFloat(dpiY))
        // Keep pages within PDF's practical 200-inch limit.
        let maxSide: CGFloat = 14_400
        if max(size.width, size.height) > maxSide {
            let s = maxSide / max(size.width, size.height)
            size = CGSize(width: size.width * s, height: size.height * s)
        }
        return size
    }

    static func writePDF(pages: [(CGImage, CGSize)], to destination: URL) throws {
        guard let first = pages.first else { throw MacFlowError("There is nothing to put into the PDF.") }
        var box = CGRect(origin: .zero, size: first.1)
        guard let ctx = CGContext(destination as CFURL, mediaBox: &box, nil) else { throw MacFlowError.encode("PDF") }
        for (image, size) in pages {
            var pageBox = CGRect(origin: .zero, size: size)
            let boxData = Data(bytes: &pageBox, count: MemoryLayout<CGRect>.size) as CFData
            ctx.beginPDFPage([kCGPDFContextMediaBox: boxData] as CFDictionary)
            ctx.interpolationQuality = .high
            ctx.draw(image, in: pageBox)
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }

    // MARK: - Encoding helpers for tools

    /// Encodes into memory (used for size estimates and target-size search).
    static func encodeData(_ image: CGImage, format: FileFormat, quality: Double, properties: [CFString: Any] = [:]) -> Data? {
        guard let type = format.utTypeIdentifiers.first(where: { EngineCapabilities.shared.imageEncodeTypes.contains($0) }) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, type as CFString, 1, nil) else { return nil }
        var props = properties
        props[kCGImagePropertyOrientation] = 1
        if !format.isLossless { props[kCGImageDestinationLossyCompressionQuality] = quality }
        var img = image
        if !format.supportsTransparency && hasAlpha(image), let flat = try? flatten(image) { img = flat }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
