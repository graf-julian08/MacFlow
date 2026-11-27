import CoreGraphics
import CoreImage
import Foundation
import SwiftUI

/// Sendable RGBA colour for tool settings.
struct RGBAColor: Hashable, Sendable {
    var r: Double, g: Double, b: Double, a: Double = 1

    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let black = RGBAColor(r: 0, g: 0, b: 0)

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: ns.redComponent, g: ns.greenComponent, b: ns.blueComponent, a: ns.alphaComponent)
    }
}

enum CompressFormatChoice: String, CaseIterable, Sendable, Identifiable {
    case keep, jpeg, heic, webp, avif
    var id: String { rawValue }
    var title: String {
        switch self {
        case .keep: return "Same Format"
        case .jpeg: return "JPEG"
        case .heic: return "HEIC"
        case .webp: return "WebP"
        case .avif: return "AVIF"
        }
    }
    var formatID: String? {
        switch self {
        case .keep: return nil
        case .jpeg: return "jpg"
        case .heic: return "heic"
        case .webp: return "webp"
        case .avif: return "avif"
        }
    }
}

struct CompressSettings: Sendable, Equatable {
    var format: CompressFormatChoice = .keep
    var quality: Double = 0.75
    /// Longest side in pixels; nil keeps the original size.
    var maxDimension: Int?
    /// Optional size goal; the quality is searched to meet it.
    var targetBytes: Int64?
    var stripMetadata = false
}

struct ResizeSettings: Sendable, Equatable {
    var width: Int
    var height: Int
}

/// Rotation applied on top of what the viewer currently sees.
struct RotateSettings: Sendable, Equatable {
    var quarterTurns = 1 // clockwise
    var flipHorizontal = false
    var flipVertical = false

    var isIdentity: Bool { quarterTurns % 4 == 0 && flipHorizontal == flipVertical && !flipHorizontal }

    /// The user transform as a (rotation, mirror) pair; see `Orientation`.
    var transform: Orientation.Element {
        var e = Orientation.Element(k: 0, m: false)
        if flipHorizontal { e = Orientation.compose(Orientation.Element(k: 0, m: true), after: e) }
        if flipVertical { e = Orientation.compose(Orientation.Element(k: 2, m: true), after: e) }
        e = Orientation.compose(Orientation.Element(k: ((quarterTurns % 4) + 4) % 4, m: false), after: e)
        return e
    }
}

/// EXIF orientations as elements of the dihedral group D4:
/// display = rotate(k × 90° clockwise) ∘ mirrorHorizontal^m.
enum Orientation {
    struct Element: Equatable { var k: Int; var m: Bool }

    static func element(exif: Int) -> Element {
        switch exif {
        case 2: return Element(k: 0, m: true)
        case 3: return Element(k: 2, m: false)
        case 4: return Element(k: 2, m: true)
        case 5: return Element(k: 3, m: true)
        case 6: return Element(k: 1, m: false)
        case 7: return Element(k: 1, m: true)
        case 8: return Element(k: 3, m: false)
        default: return Element(k: 0, m: false)
        }
    }

    static func exif(_ e: Element) -> Int {
        switch (((e.k % 4) + 4) % 4, e.m) {
        case (0, false): return 1
        case (0, true): return 2
        case (2, false): return 3
        case (2, true): return 4
        case (3, true): return 5
        case (1, false): return 6
        case (1, true): return 7
        default: return 8
        }
    }

    /// Returns `r ∘ d` (apply `d` first, then `r`).
    static func compose(_ r: Element, after d: Element) -> Element {
        let k = r.m ? (r.k - d.k) : (r.k + d.k)
        return Element(k: ((k % 4) + 4) % 4, m: r.m != d.m)
    }
}

struct AdjustSettings: Sendable, Equatable {
    var auto = false
    var exposure = 0.0      // EV, -2…2
    var brightness = 0.0    // -0.5…0.5
    var contrast = 1.0      // 0.5…1.5
    var saturation = 1.0    // 0…2
    var vibrance = 0.0      // -1…1
    var warmth = 0.0        // -1…1
    var highlights = 0.0    // -1…0 (recover)
    var shadows = 0.0       // 0…1 (lift)
    var sharpness = 0.0     // 0…1
    var blur = 0.0          // 0…1
    var vignette = 0.0      // 0…1

    var isNeutral: Bool { self == AdjustSettings() }

    func apply(to input: CIImage, autoFilters: [CIFilter] = []) -> CIImage {
        var image = input
        let extent = input.extent
        if auto {
            for filter in autoFilters {
                filter.setValue(image, forKey: kCIInputImageKey)
                if let out = filter.outputImage { image = out }
            }
        }
        if exposure != 0 { image = image.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: exposure]) }
        if brightness != 0 || contrast != 1 || saturation != 1 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: brightness, kCIInputContrastKey: contrast, kCIInputSaturationKey: saturation,
            ])
        }
        if vibrance != 0 { image = image.applyingFilter("CIVibrance", parameters: ["inputAmount": vibrance]) }
        if warmth != 0 {
            // Neutral 6500 K; positive warmth renders the image warmer.
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 0),
                "inputTargetNeutral": CIVector(x: 6500 + warmth * 3000, y: 0),
            ])
        }
        if highlights != 0 || shadows != 0 {
            image = image.applyingFilter("CIHighlightShadowAdjust", parameters: [
                "inputHighlightAmount": 1 + highlights, "inputShadowAmount": shadows,
            ])
        }
        if sharpness > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: sharpness * 2, kCIInputRadiusKey: 1.5])
        }
        if blur > 0 {
            let radius = blur * max(extent.width, extent.height) / 100
            image = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius]).cropped(to: extent)
        }
        if vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: vignette * 1.5, kCIInputRadiusKey: 1.5])
        }
        return image.cropped(to: extent)
    }
}

enum BackgroundStyle: String, CaseIterable, Sendable, Identifiable {
    case solid, gradient
    var id: String { rawValue }
}

enum CanvasAspect: String, CaseIterable, Sendable, Identifiable {
    case original, square, portrait45, landscape169, portrait916
    var id: String { rawValue }
    var title: String {
        switch self {
        case .original: return "Original"
        case .square: return "1:1"
        case .portrait45: return "4:5"
        case .landscape169: return "16:9"
        case .portrait916: return "9:16"
        }
    }
    var ratio: CGFloat? {
        switch self {
        case .original: return nil
        case .square: return 1
        case .portrait45: return 4.0 / 5.0
        case .landscape169: return 16.0 / 9.0
        case .portrait916: return 9.0 / 16.0
        }
    }
}

struct BackgroundSettings: Sendable, Equatable {
    var style: BackgroundStyle = .solid
    var color1 = RGBAColor.white
    var color2 = RGBAColor(r: 0.90, g: 0.92, b: 0.98)
    var angle = 135.0
    var padding = 0.08        // fraction of the longest image side
    var cornerRadius = 0.0    // fraction of the shorter image side
    var aspect: CanvasAspect = .original
    var shadow = false
}

enum RedactStyle: String, CaseIterable, Sendable, Identifiable {
    case black, pixelate, blur
    var id: String { rawValue }
    var title: String {
        switch self {
        case .black: return "Black Box"
        case .pixelate: return "Pixelate"
        case .blur: return "Blur"
        }
    }
}

struct RedactRegion: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case face, text, manual }
    let id: UUID
    var rect: CGRect      // normalised, top-left origin
    var kind: Kind
    var enabled = true

    init(rect: CGRect, kind: Kind, enabled: Bool = true) {
        self.id = UUID(); self.rect = rect; self.kind = kind; self.enabled = enabled
    }
}

struct RedactSettings: Sendable, Equatable {
    var regions: [RedactRegion] = []
    var style: RedactStyle = .black
}

enum AnnotationKind: String, CaseIterable, Sendable, Identifiable {
    case arrow, line, rectangle, ellipse, highlight, text, number
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .line: return "line.diagonal"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        case .number: return "1.circle"
        }
    }
    var title: String {
        switch self {
        case .arrow: return "Arrow"
        case .line: return "Line"
        case .rectangle: return "Rectangle"
        case .ellipse: return "Ellipse"
        case .highlight: return "Highlight"
        case .text: return "Text"
        case .number: return "Number"
        }
    }
}

struct Annotation: Identifiable, Hashable, Sendable {
    let id = UUID()
    var kind: AnnotationKind
    var start: CGPoint    // normalised, top-left origin
    var end: CGPoint
    var color: RGBAColor
    var lineWidth: Double // fraction of the longest side
    var text: String = ""
    var number: Int = 1
}

enum PDFPageSizeChoice: String, CaseIterable, Sendable, Identifiable {
    case fit, a4, letter
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fit: return "Fit Image"
        case .a4: return "A4"
        case .letter: return "US Letter"
        }
    }
}

struct MakePDFSettings: Sendable, Equatable {
    var order: [URL] = []
    var pageSize: PDFPageSizeChoice = .fit
    var margin = 0.0          // points
    var jpegQuality = 0.85
}

/// Editable metadata fields mapped to ImageIO properties.
enum MetadataField: String, CaseIterable, Sendable, Identifiable {
    case title, description, author, copyright, keywords, dateTaken, make, model, latitude, longitude
    var id: String { rawValue }
    var label: String {
        switch self {
        case .title: return "Title"
        case .description: return "Description"
        case .author: return "Author"
        case .copyright: return "Copyright"
        case .keywords: return "Keywords"
        case .dateTaken: return "Date Taken"
        case .make: return "Camera Make"
        case .model: return "Camera Model"
        case .latitude: return "Latitude"
        case .longitude: return "Longitude"
        }
    }
}

struct MetadataEdit: Sendable, Equatable {
    /// Field values to write; an empty string removes the field.
    var fields: [MetadataField: String] = [:]
    /// XMP paths (prefix:name) of tags to delete.
    var removedPaths: Set<String> = []
    var removeLocation = false
    var removeAll = false
}
