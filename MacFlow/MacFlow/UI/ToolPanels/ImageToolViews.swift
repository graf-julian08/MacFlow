import AppKit
import CoreImage
import SwiftUI

// MARK: - Compress

@MainActor
final class CompressEstimator: ObservableObject {
    @Published var estimate: Int64?
    @Published var estimating = false
    @Published var fullSize: CGSize = .zero
    private var image: CGImage?
    private var task: Task<Void, Never>?

    func prepare(_ url: URL) {
        Task.detached(priority: .userInitiated) {
            let loaded = try? ImageEngine.load(url)
            await MainActor.run {
                self.image = loaded?.image
                if let img = loaded?.image { self.fullSize = CGSize(width: img.width, height: img.height) }
            }
        }
    }

    func update(settings: CompressSettings, format: FileFormat) {
        task?.cancel()
        guard let image, format.id != "webp", settings.targetBytes == nil else { estimate = nil; return }
        estimating = true
        task = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            if Task.isCancelled { return }
            var img = image
            if let maxSide = settings.maxDimension, max(img.width, img.height) > maxSide {
                let s = Double(maxSide) / Double(max(img.width, img.height))
                img = (try? ImageEngine.resize(img, width: max(1, Int(Double(img.width) * s)), height: max(1, Int(Double(img.height) * s)))) ?? img
            }
            let bytes = ImageTools.estimateSize(image: img, format: format, quality: settings.quality)
            if Task.isCancelled { return }
            await MainActor.run { self?.estimate = bytes; self?.estimating = false }
        }
    }
}

struct CompressToolView: View {
    @ObservedObject var context: ToolContext
    @State private var settings = CompressSettings()
    @State private var useTarget = false
    @State private var targetText = "500"
    @State private var targetUnitMB = false
    @StateObject private var estimator = CompressEstimator()
    @StateObject private var preview = PreviewLoader()

    private var sourceFormat: FileFormat { context.primaryFormat ?? FormatRegistry.shared["jpg"] }
    private var output: FileFormat { ImageTools.compressOutputFormat(sourceFormat: sourceFormat, settings: settings) }
    private var originalBytes: Int64 { context.files.reduce(0) { $0 + fileSize(of: $1) } }
    private var formatChoices: [CompressFormatChoice] {
        CompressFormatChoice.allCases.filter { choice in
            guard let id = choice.formatID, let f = FormatRegistry.shared.format(for: id) else { return true }
            return EngineCapabilities.shared.canEncodeImage(f)
        }
    }
    private var sizeChoices: [Int?] {
        let longest = Int(max(estimator.fullSize.width, estimator.fullSize.height))
        return [nil] + [3840, 2560, 1920, 1280, 800].filter { longest == 0 || $0 < longest }
    }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Compress", canSubmit: !useTarget || targetBytes != nil, footnote: footnote) {
            submit()
        } content: {
            HStack(alignment: .top, spacing: 16) {
                PreviewSurface(image: preview.image, height: 220)
                    .frame(minWidth: 200, maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 12) {
                    Picker("Format", selection: $settings.format) {
                        ForEach(formatChoices) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    SliderRow(title: "Quality", value: $settings.quality, range: 0.1...1.0, format: { "\(Int(($0 * 100).rounded()))%" })
                        .disabled(output.isLossless || useTarget)
                    if output.isLossless {
                        Text("\(output.label) is lossless — choose a smaller size or another format.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Picker("Max Size", selection: $settings.maxDimension) {
                        ForEach(sizeChoices, id: \.self) { value in
                            Text(value.map { "\($0) px" } ?? "Original").tag(value)
                        }
                    }
                    .pickerStyle(.menu)
                    Toggle("Target file size", isOn: $useTarget)
                    if useTarget {
                        HStack {
                            TextField("Size", text: $targetText).frame(width: 80).textFieldStyle(.roundedBorder)
                            Picker("", selection: $targetUnitMB) {
                                Text("KB").tag(false); Text("MB").tag(true)
                            }
                            .pickerStyle(.segmented).frame(width: 90)
                        }
                    }
                    Toggle("Remove metadata", isOn: $settings.stripMetadata)
                }
                .frame(width: 300)
            }
        }
        .onAppear {
            preview.load(context.primary, maxPixel: 600)
            estimator.prepare(context.primary)
            if sourceFormat.isLossless || !EngineCapabilities.shared.canEncodeImage(sourceFormat) {
                settings.format = EngineCapabilities.shared.canEncodeImage(FormatRegistry.shared["heic"]) ? .heic : .jpeg
            }
        }
        .onChange(of: settings) { _, new in estimator.update(settings: new, format: output) }
        .onChange(of: estimator.fullSize) { _, _ in estimator.update(settings: settings, format: output) }
    }

    private var targetBytes: Int64? {
        guard let value = Double(targetText.replacingOccurrences(of: ",", with: ".")), value > 0 else { return nil }
        return Int64(value * (targetUnitMB ? 1_000_000 : 1_000))
    }

    private var footnote: String {
        let original = "Original \(originalBytes.fileSize)"
        if context.files.count > 1 { return "\(context.files.count) images · \(original)" }
        if useTarget { return "\(original) · quality is chosen to fit the target" }
        if estimator.estimating { return "\(original) · estimating…" }
        guard let estimate = estimator.estimate else { return original }
        let change = originalBytes > 0 ? Int((1 - Double(estimate) / Double(originalBytes)) * 100) : 0
        return "\(original) → \(estimate.fileSize)" + (change > 0 ? "  (−\(change)%)" : "  (not smaller)")
    }

    private func submit() {
        var s = settings
        s.targetBytes = useTarget ? targetBytes : nil
        context.submit(.compress(s))
    }
}

// MARK: - Metadata

struct MetadataToolView: View {
    @ObservedObject var context: ToolContext
    @State private var fields: [MetadataField: String] = [:]
    @State private var original: [MetadataField: String] = [:]
    @State private var entries: [ImageTools.MetadataEntry] = []
    @State private var removed: Set<String> = []
    @State private var removeLocation = false
    @State private var removeAll = false
    @State private var loaded = false

    private var single: Bool { context.files.count == 1 }
    private var changed: Bool {
        removeAll || removeLocation || !removed.isEmpty || MetadataField.allCases.contains { (fields[$0] ?? "") != (original[$0] ?? "") }
    }
    private var hasLocation: Bool { original[.latitude] != nil || entries.contains { $0.path.lowercased().contains("gps") } }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Save Copy", canSubmit: changed, footnote: "The image itself is not re-compressed.", width: 640) {
            var edit = MetadataEdit()
            for field in MetadataField.allCases where (fields[field] ?? "") != (original[field] ?? "") {
                edit.fields[field] = fields[field] ?? ""
            }
            edit.removedPaths = removed
            edit.removeLocation = removeLocation
            edit.removeAll = removeAll
            context.submit(.metadata(edit))
        } content: {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(MetadataField.allCases) { field in
                        HStack(spacing: 8) {
                            Text(field.label).font(.system(size: 12)).frame(width: 96, alignment: .leading)
                            TextField(placeholder(field), text: binding(field))
                                .textFieldStyle(.roundedBorder)
                                .disabled(removeAll || (removeLocation && (field == .latitude || field == .longitude)))
                        }
                    }
                    Divider().padding(.vertical, 2)
                    Toggle("Remove location", isOn: $removeLocation).disabled(removeAll || !hasLocation)
                    Toggle("Remove all metadata", isOn: $removeAll)
                    if removeAll {
                        Text("Orientation is kept so the photo still displays upright.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 300)
                VStack(alignment: .leading, spacing: 6) {
                    Text(single ? "All Metadata" : "Applies to \(context.files.count) images")
                        .font(.system(size: 12, weight: .semibold))
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(groups, id: \.0) { group, items in
                                Text(group).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.top, 8).padding(.bottom, 3)
                                ForEach(items) { entry in row(entry) }
                            }
                            if loaded && entries.isEmpty {
                                Text("No metadata found.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 20)
                            }
                        }
                        .padding(.horizontal, 10)
                    }
                    .frame(minHeight: 360, maxHeight: .infinity)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                    .opacity(removeAll ? 0.4 : 1)
                }
            }
        }
        .onAppear(perform: load)
    }

    private var groups: [(String, [ImageTools.MetadataEntry])] {
        Dictionary(grouping: entries, by: \.group).sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    private func row(_ entry: ImageTools.MetadataEntry) -> some View {
        let isRemoved = removed.contains(entry.path) || removeAll || (removeLocation && entry.path.lowercased().contains("gps"))
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(entry.name).font(.system(size: 11.5, weight: .medium)).frame(width: 120, alignment: .leading).lineLimit(1)
            Text(entry.value).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
            Spacer(minLength: 4)
            if single && !removeAll && entry.removable {
                Button {
                    if removed.contains(entry.path) { removed.remove(entry.path) } else { removed.insert(entry.path) }
                } label: {
                    Image(systemName: removed.contains(entry.path) ? "arrow.uturn.backward.circle" : "minus.circle")
                        .foregroundStyle(removed.contains(entry.path) ? Color.secondary : Color(nsColor: .systemRed))
                }
                .buttonStyle(.plain)
                .help(removed.contains(entry.path) ? "Keep this tag" : "Remove this tag")
            }
        }
        .strikethrough(isRemoved)
        .opacity(isRemoved ? 0.45 : 1)
        .padding(.vertical, 3)
    }

    private func placeholder(_ field: MetadataField) -> String {
        switch field {
        case .dateTaken: return "2024:05:31 14:30:00"
        case .keywords: return "comma, separated"
        case .latitude: return "47.3769"
        case .longitude: return "8.5417"
        default: return single ? "—" : "unchanged"
        }
    }

    private func binding(_ field: MetadataField) -> Binding<String> {
        Binding(get: { fields[field] ?? "" }, set: { fields[field] = $0 })
    }

    private func load() {
        guard single else { loaded = true; return }
        let url = context.primary
        Task.detached {
            let f = ImageTools.readFields(url)
            let e = (try? ImageTools.readMetadata(url)) ?? []
            await MainActor.run { fields = f; original = f; entries = e; loaded = true }
        }
    }
}

// MARK: - Edit (adjust)

struct AdjustToolView: View {
    @ObservedObject var context: ToolContext
    @State private var settings = AdjustSettings()
    @State private var rendered: CGImage?
    @State private var comparing = false
    @StateObject private var preview = PreviewLoader()
    @State private var renderTask: Task<Void, Never>?
    @State private var autoFilters: [CIFilter] = []

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Save Copy", canSubmit: !settings.isNeutral, footnote: "Press and hold the preview to compare with the original.", width: 720) {
            context.submit(.adjust(settings))
        } content: {
            HStack(alignment: .top, spacing: 16) {
                PreviewSurface(image: comparing ? preview.image : (rendered ?? preview.image), height: 380)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { _ in comparing = true }.onEnded { _ in comparing = false })
                    .frame(minWidth: 380, maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Toggle("Auto Enhance", isOn: $settings.auto)
                        Spacer()
                        Button("Reset") { settings = AdjustSettings() }.disabled(settings.isNeutral)
                    }
                    SliderRow(title: "Exposure", value: $settings.exposure, range: -2...2, format: { String(format: "%+.1f", $0) }, neutral: 0)
                    SliderRow(title: "Brightness", value: $settings.brightness, range: -0.4...0.4, format: { String(format: "%+.0f", $0 * 250) }, neutral: 0)
                    SliderRow(title: "Contrast", value: $settings.contrast, range: 0.6...1.4, format: { String(format: "%+.0f", ($0 - 1) * 250) }, neutral: 1)
                    SliderRow(title: "Saturation", value: $settings.saturation, range: 0...2, format: { String(format: "%+.0f", ($0 - 1) * 100) }, neutral: 1)
                    SliderRow(title: "Vibrance", value: $settings.vibrance, range: -1...1, format: { String(format: "%+.0f", $0 * 100) }, neutral: 0)
                    SliderRow(title: "Warmth", value: $settings.warmth, range: -1...1, format: { String(format: "%+.0f", $0 * 100) }, neutral: 0)
                    SliderRow(title: "Highlights", value: $settings.highlights, range: -1...0, format: { String(format: "%.0f", $0 * 100) }, neutral: 0)
                    SliderRow(title: "Shadows", value: $settings.shadows, range: 0...1, format: { String(format: "%+.0f", $0 * 100) }, neutral: 0)
                    SliderRow(title: "Sharpness", value: $settings.sharpness, range: 0...1, format: { String(format: "%.0f", $0 * 100) }, neutral: 0)
                    SliderRow(title: "Blur", value: $settings.blur, range: 0...1, format: { String(format: "%.0f", $0 * 100) }, neutral: 0)
                    SliderRow(title: "Vignette", value: $settings.vignette, range: 0...1, format: { String(format: "%.0f", $0 * 100) }, neutral: 0)
                }
                .frame(width: 280)
            }
        }
        .onAppear { preview.load(context.primary, maxPixel: 1200) }
        .onChange(of: preview.image) { _, image in
            if let image { autoFilters = CIImage(cgImage: image).autoAdjustmentFilters(options: [.redEye: false]) }
            render()
        }
        .onChange(of: settings) { _, _ in render() }
    }

    private func render() {
        renderTask?.cancel()
        guard let base = preview.image else { return }
        let s = settings
        let filters = autoFilters
        renderTask = Task.detached(priority: .userInitiated) {
            let ci = CIImage(cgImage: base)
            let out = s.apply(to: ci, autoFilters: s.auto ? filters : [])
            let image = ImageEngine.ciContext.createCGImage(out, from: ci.extent)
            if Task.isCancelled { return }
            await MainActor.run { rendered = image }
        }
    }
}

// MARK: - Crop

enum CropAspectChoice: String, CaseIterable, Identifiable {
    case free, original, square, fourThree, threeTwo, sixteenNine, fourFive, nineSixteen
    var id: String { rawValue }
    var title: String {
        switch self {
        case .free: return "Free"
        case .original: return "Original"
        case .square: return "1:1"
        case .fourThree: return "4:3"
        case .threeTwo: return "3:2"
        case .sixteenNine: return "16:9"
        case .fourFive: return "4:5"
        case .nineSixteen: return "9:16"
        }
    }
    func ratio(original: CGSize) -> CGFloat? {
        switch self {
        case .free: return nil
        case .original: return original.width / max(original.height, 1)
        case .square: return 1
        case .fourThree: return 4 / 3
        case .threeTwo: return 3 / 2
        case .sixteenNine: return 16 / 9
        case .fourFive: return 4 / 5
        case .nineSixteen: return 9 / 16
        }
    }
}

struct CropToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var preview = PreviewLoader()
    @State private var rect = CGRect(x: 0, y: 0, width: 1, height: 1)
    @State private var aspect: CropAspectChoice = .free
    @State private var dragStart: CGRect?

    private var pixelSize: CGSize { preview.originalSize }
    private var isFull: Bool { rect.width > 0.999 && rect.height > 0.999 }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Crop", canSubmit: !isFull, footnote: footnote, width: 680) {
            context.submit(.crop(rect))
        } content: {
            VStack(spacing: 12) {
                PreviewSurface(image: preview.image, height: 420, checkerboard: true) { imageRect in
                    CropOverlay(rect: $rect, imageRect: imageRect, aspectRatio: aspectRatioNormalized)
                }
                HStack {
                    Picker("Aspect", selection: $aspect) {
                        ForEach(CropAspectChoice.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    Button("Reset") { aspect = .free; rect = CGRect(x: 0, y: 0, width: 1, height: 1) }
                }
            }
        }
        .onAppear { preview.load(context.primary, maxPixel: 1400) }
        .onChange(of: aspect) { _, _ in applyAspect() }
    }

    /// Aspect expressed in normalised coordinates (image aspect divided out).
    private var aspectRatioNormalized: CGFloat? {
        guard let r = aspect.ratio(original: pixelSize), pixelSize.width > 0 else { return nil }
        return r * pixelSize.height / pixelSize.width
    }

    private func applyAspect() {
        guard let r = aspectRatioNormalized else { return }
        var w = rect.width, h = rect.height
        if w / h > r { w = h * r } else { h = w / r }
        if w > 1 { w = 1; h = w / r }
        if h > 1 { h = 1; w = h * r }
        let cx = rect.midX, cy = rect.midY
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            rect = CGRect(x: min(max(0, cx - w / 2), 1 - w), y: min(max(0, cy - h / 2), 1 - h), width: w, height: h)
        }
    }

    private var footnote: String {
        guard pixelSize.width > 0 else { return "" }
        let w = Int((rect.width * pixelSize.width).rounded()), h = Int((rect.height * pixelSize.height).rounded())
        return "\(w) × \(h) px of \(Int(pixelSize.width)) × \(Int(pixelSize.height))"
    }
}

/// Draggable crop rectangle with handles, dimmed outside and a thirds grid.
struct CropOverlay: View {
    @Binding var rect: CGRect      // normalised, top-left
    let imageRect: CGRect          // view coordinates of the image
    let aspectRatio: CGFloat?      // normalised width / height
    @State private var start: CGRect?

    private func viewRect(_ r: CGRect) -> CGRect {
        CGRect(x: imageRect.minX + r.minX * imageRect.width, y: imageRect.minY + r.minY * imageRect.height,
               width: r.width * imageRect.width, height: r.height * imageRect.height)
    }

    var body: some View {
        let v = viewRect(rect)
        ZStack(alignment: .topLeading) {
            // Dim outside
            Path { p in
                p.addRect(imageRect)
                p.addRect(v)
            }
            .fill(Color.black.opacity(0.45), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)
            // Grid
            Path { p in
                for i in 1...2 {
                    let x = v.minX + v.width * CGFloat(i) / 3
                    let y = v.minY + v.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: v.minY)); p.addLine(to: CGPoint(x: x, y: v.maxY))
                    p.move(to: CGPoint(x: v.minX, y: y)); p.addLine(to: CGPoint(x: v.maxX, y: y))
                }
            }
            .stroke(Color.white.opacity(0.45), lineWidth: 0.5)
            .allowsHitTesting(false)
            Rectangle()
                .stroke(Color.white, lineWidth: 1.5)
                .frame(width: v.width, height: v.height)
                .contentShape(Rectangle())
                .offset(x: v.minX, y: v.minY)
                .gesture(DragGesture().onChanged { g in move(by: g.translation) }.onEnded { _ in start = nil })
            ForEach(Corner.allCases, id: \.self) { corner in
                handle(corner, in: v)
            }
        }
    }

    enum Corner: CaseIterable { case topLeft, topRight, bottomLeft, bottomRight }

    private func handle(_ corner: Corner, in v: CGRect) -> some View {
        let point: CGPoint = {
            switch corner {
            case .topLeft: return CGPoint(x: v.minX, y: v.minY)
            case .topRight: return CGPoint(x: v.maxX, y: v.minY)
            case .bottomLeft: return CGPoint(x: v.minX, y: v.maxY)
            case .bottomRight: return CGPoint(x: v.maxX, y: v.maxY)
            }
        }()
        return RoundedRectangle(cornerRadius: 3)
            .fill(Color.white)
            .frame(width: 14, height: 14)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .position(point)
            .gesture(DragGesture().onChanged { g in resize(corner, by: g.translation) }.onEnded { _ in start = nil })
    }

    private func move(by t: CGSize) {
        if start == nil { start = rect }
        guard let s = start, imageRect.width > 0 else { return }
        let dx = t.width / imageRect.width, dy = t.height / imageRect.height
        rect.origin = CGPoint(x: min(max(0, s.minX + dx), 1 - s.width), y: min(max(0, s.minY + dy), 1 - s.height))
    }

    private func resize(_ corner: Corner, by t: CGSize) {
        if start == nil { start = rect }
        guard let s = start, imageRect.width > 0 else { return }
        let dx = t.width / imageRect.width, dy = t.height / imageRect.height
        var minX = s.minX, minY = s.minY, maxX = s.maxX, maxY = s.maxY
        switch corner {
        case .topLeft: minX += dx; minY += dy
        case .topRight: maxX += dx; minY += dy
        case .bottomLeft: minX += dx; maxY += dy
        case .bottomRight: maxX += dx; maxY += dy
        }
        minX = max(0, minX); minY = max(0, minY); maxX = min(1, maxX); maxY = min(1, maxY)
        let minimum: CGFloat = 0.02
        if maxX - minX < minimum { if corner == .topLeft || corner == .bottomLeft { minX = maxX - minimum } else { maxX = minX + minimum } }
        if maxY - minY < minimum { if corner == .topLeft || corner == .topRight { minY = maxY - minimum } else { maxY = minY + minimum } }
        var r = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        if let aspect = aspectRatio {
            // Keep the anchored corner fixed and fit the ratio.
            var w = r.width, h = r.height
            if w / h > aspect { w = h * aspect } else { h = w / aspect }
            let anchorX = (corner == .topLeft || corner == .bottomLeft) ? s.maxX : s.minX
            let anchorY = (corner == .topLeft || corner == .topRight) ? s.maxY : s.minY
            let x = (corner == .topLeft || corner == .bottomLeft) ? anchorX - w : anchorX
            let y = (corner == .topLeft || corner == .topRight) ? anchorY - h : anchorY
            r = CGRect(x: x, y: y, width: w, height: h)
            if r.minX < 0 || r.minY < 0 || r.maxX > 1 || r.maxY > 1 { return }
        }
        rect = r
    }
}

// MARK: - Rotate

struct RotateToolView: View {
    @ObservedObject var context: ToolContext
    @State private var settings = RotateSettings(quarterTurns: 0)
    @StateObject private var preview = PreviewLoader()

    private var lossless: Bool {
        guard let f = context.primaryFormat else { return false }
        return f.id == "jpg" || f.id == "heic"
    }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Save Copy", canSubmit: !settings.isIdentity,
                   footnote: lossless ? "Lossless: only the orientation tag changes." : description, width: 520) {
            context.submit(.rotate(settings))
        } content: {
            VStack(spacing: 14) {
                PreviewSurface(image: preview.image, height: 320)
                    .rotationEffect(.degrees(Double(settings.quarterTurns * 90)))
                    .scaleEffect(x: settings.flipHorizontal ? -1 : 1, y: settings.flipVertical ? -1 : 1)
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: settings)
                    .frame(minHeight: 320, maxHeight: .infinity)
                HStack(spacing: 10) {
                    rotateButton("Left", "rotate.left") { settings.quarterTurns -= 1 }
                    rotateButton("Right", "rotate.right") { settings.quarterTurns += 1 }
                    rotateButton("Flip Horizontal", "arrow.left.and.right.righttriangle.left.righttriangle.right") { settings.flipHorizontal.toggle() }
                    rotateButton("Flip Vertical", "arrow.up.and.down.righttriangle.up.righttriangle.down") { settings.flipVertical.toggle() }
                }
            }
        }
        .onAppear { preview.load(context.primary, maxPixel: 900) }
    }

    private var description: String {
        let turns = ((settings.quarterTurns % 4) + 4) % 4
        var parts: [String] = []
        if turns == 1 { parts.append("90° right") } else if turns == 2 { parts.append("180°") } else if turns == 3 { parts.append("90° left") }
        if settings.flipHorizontal { parts.append("flipped horizontally") }
        if settings.flipVertical { parts.append("flipped vertically") }
        return parts.isEmpty ? "No change" : parts.joined(separator: ", ")
    }

    private func rotateButton(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                Text(title).font(.system(size: 10.5))
            }
            .frame(maxWidth: .infinity, minHeight: 50)
        }
        .buttonStyle(.bordered)
    }
}

// MARK: - Redact

struct RedactToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var preview = PreviewLoader()
    @State private var settings = RedactSettings()
    @State private var detecting = true
    @State private var drawStart: CGPoint?
    @State private var drawing: CGRect?

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Redact", canSubmit: settings.regions.contains(where: \.enabled), footnote: summary, width: 680) {
            context.submit(.redact(settings))
        } content: {
            VStack(spacing: 12) {
                PreviewSurface(image: preview.image, height: 400) { imageRect in
                    ZStack(alignment: .topLeading) {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(DragGesture(minimumDistance: 4).onChanged { g in
                                drawStart = drawStart ?? g.startLocation
                                drawing = normalized(from: drawStart!, to: g.location, in: imageRect)
                            }.onEnded { _ in
                                if let r = drawing, r.width > 0.005, r.height > 0.005 {
                                    settings.regions.append(RedactRegion(rect: r, kind: .manual))
                                }
                                drawStart = nil; drawing = nil
                            })
                        ForEach(settings.regions) { region in
                            regionBox(region, imageRect: imageRect)
                        }
                        if let drawing {
                            Rectangle().stroke(Color.white, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                                .frame(width: drawing.width * imageRect.width, height: drawing.height * imageRect.height)
                                .offset(x: imageRect.minX + drawing.minX * imageRect.width, y: imageRect.minY + drawing.minY * imageRect.height)
                                .allowsHitTesting(false)
                        }
                        if detecting {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Detecting faces and text…").font(.system(size: 11.5)) }
                                .padding(8).background(.regularMaterial, in: Capsule()).padding(10)
                        }
                    }
                }
                HStack {
                    Picker("Style", selection: $settings.style) {
                        ForEach(RedactStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).frame(width: 260)
                    Spacer()
                    Button("Clear Manual") { settings.regions.removeAll { $0.kind == .manual } }
                        .disabled(!settings.regions.contains { $0.kind == .manual })
                }
                Text("Drag on the image to add an area · click an area to include or exclude it. Automatic detection can miss things — check before saving.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .onAppear {
            preview.load(context.primary, maxPixel: 1600)
        }
        .onChange(of: preview.image) { _, image in detect(image) }
    }

    private func detect(_ image: CGImage?) {
        guard let image else { return }
        Task.detached(priority: .userInitiated) {
            let found = (try? ImageTools.detectSensitiveRegions(image)) ?? []
            await MainActor.run {
                settings.regions = found + settings.regions.filter { $0.kind == .manual }
                detecting = false
            }
        }
    }

    private func normalized(from a: CGPoint, to b: CGPoint, in r: CGRect) -> CGRect {
        let x1 = min(max((min(a.x, b.x) - r.minX) / r.width, 0), 1)
        let y1 = min(max((min(a.y, b.y) - r.minY) / r.height, 0), 1)
        let x2 = min(max((max(a.x, b.x) - r.minX) / r.width, 0), 1)
        let y2 = min(max((max(a.y, b.y) - r.minY) / r.height, 0), 1)
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    private func regionBox(_ region: RedactRegion, imageRect: CGRect) -> some View {
        let color: Color = region.kind == .face ? .orange : (region.kind == .text ? .blue : .white)
        return Rectangle()
            .fill(region.enabled ? (settings.style == .black ? Color.black.opacity(0.85) : color.opacity(0.3)) : Color.clear)
            .overlay(Rectangle().stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: region.enabled ? [] : [4, 3])))
            .frame(width: max(4, region.rect.width * imageRect.width), height: max(4, region.rect.height * imageRect.height))
            .offset(x: imageRect.minX + region.rect.minX * imageRect.width, y: imageRect.minY + region.rect.minY * imageRect.height)
            .onTapGesture {
                if let i = settings.regions.firstIndex(where: { $0.id == region.id }) { settings.regions[i].enabled.toggle() }
            }
    }

    private var summary: String {
        let faces = settings.regions.filter { $0.kind == .face }.count
        let text = settings.regions.filter { $0.kind == .text }.count
        let manual = settings.regions.filter { $0.kind == .manual }.count
        let active = settings.regions.filter(\.enabled).count
        return "\(faces) face\(faces == 1 ? "" : "s"), \(text) text line\(text == 1 ? "" : "s"), \(manual) manual · \(active) will be redacted"
    }
}

// MARK: - Background

struct BackgroundToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var preview = PreviewLoader()
    @State private var settings = BackgroundSettings()
    @State private var rendered: CGImage?
    @State private var task: Task<Void, Never>?

    private let swatches: [RGBAColor] = [.white, RGBAColor(r: 0.95, g: 0.95, b: 0.96), RGBAColor(r: 0.11, g: 0.11, b: 0.12),
                                         RGBAColor(r: 0.0, g: 0.48, b: 1.0), RGBAColor(r: 1.0, g: 0.42, b: 0.0), RGBAColor(r: 0.2, g: 0.78, b: 0.35)]

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Save Copy", footnote: "Image is centred on the new canvas.", width: 700) {
            context.submit(.background(settings))
        } content: {
            HStack(alignment: .top, spacing: 16) {
                PreviewSurface(image: rendered ?? preview.image, height: 340).frame(minWidth: 340, maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $settings.style) {
                        Text("Solid").tag(BackgroundStyle.solid); Text("Gradient").tag(BackgroundStyle.gradient)
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    HStack(spacing: 8) {
                        ForEach(swatches, id: \.self) { swatch in
                            Circle().fill(swatch.color)
                                .overlay(Circle().stroke(Color.primary.opacity(settings.color1 == swatch ? 0.9 : 0.15), lineWidth: settings.color1 == swatch ? 2 : 1))
                                .frame(width: 22, height: 22)
                                .onTapGesture { settings.color1 = swatch }
                        }
                        ColorPicker("", selection: Binding(get: { settings.color1.color }, set: { settings.color1 = RGBAColor($0) }), supportsOpacity: false)
                            .labelsHidden()
                    }
                    if settings.style == .gradient {
                        HStack {
                            Text("End colour").font(.system(size: 12))
                            ColorPicker("", selection: Binding(get: { settings.color2.color }, set: { settings.color2 = RGBAColor($0) }), supportsOpacity: false).labelsHidden()
                        }
                        SliderRow(title: "Angle", value: $settings.angle, range: 0...360, format: { "\(Int($0))°" })
                    }
                    SliderRow(title: "Padding", value: $settings.padding, range: 0...0.4, format: { "\(Int($0 * 100))%" })
                    SliderRow(title: "Corners", value: $settings.cornerRadius, range: 0...0.25, format: { "\(Int($0 * 100))%" })
                    Picker("Canvas", selection: $settings.aspect) {
                        ForEach(CanvasAspect.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Toggle("Drop shadow", isOn: $settings.shadow)
                }
                .frame(width: 300)
            }
        }
        .onAppear { preview.load(context.primary, maxPixel: 800) }
        .onChange(of: preview.image) { _, _ in render() }
        .onChange(of: settings) { _, _ in render() }
    }

    private func render() {
        task?.cancel()
        guard let base = preview.image else { return }
        let s = settings
        task = Task.detached(priority: .userInitiated) {
            let image = try? ImageTools.addBackground(base, s)
            if Task.isCancelled { return }
            await MainActor.run { rendered = image }
        }
    }
}

// MARK: - Resize

struct ResizeToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var preview = PreviewLoader()
    @State private var width = ""
    @State private var height = ""
    @State private var lock = true
    @State private var percent: Double = 50
    @State private var usePercent = false

    private var original: CGSize { preview.originalSize }
    private var single: Bool { context.files.count == 1 }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Resize", canSubmit: valid, footnote: footnote, width: 460) {
            if usePercent || !single { context.submit(.resize(nil, percent: percent)) }
            else if let w = Int(width), let h = Int(height) { context.submit(.resize(ResizeSettings(width: w, height: h), percent: nil)) }
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                if single {
                    Picker("", selection: $usePercent) { Text("Pixels").tag(false); Text("Percent").tag(true) }
                        .pickerStyle(.segmented).labelsHidden()
                }
                if usePercent || !single {
                    SliderRow(title: "Scale", value: $percent, range: 5...400, step: 1, format: { "\(Int($0))%" })
                    HStack {
                        ForEach([25.0, 50, 75, 150, 200], id: \.self) { p in
                            Button("\(Int(p))%") { percent = p }.buttonStyle(.bordered)
                        }
                    }
                } else {
                    HStack(spacing: 10) {
                        TextField("Width", text: $width).textFieldStyle(.roundedBorder).frame(width: 100)
                            .onChange(of: width) { _, new in sync(fromWidth: new) }
                        Text("×").foregroundStyle(.secondary)
                        TextField("Height", text: $height).textFieldStyle(.roundedBorder).frame(width: 100)
                            .onChange(of: height) { _, new in sync(fromHeight: new) }
                        Text("px").foregroundStyle(.secondary)
                        Toggle(isOn: $lock) { Image(systemName: lock ? "lock.fill" : "lock.open") }.toggleStyle(.button)
                            .help("Keep aspect ratio")
                    }
                    HStack {
                        ForEach([3840, 2560, 1920, 1280, 640], id: \.self) { side in
                            Button("\(side)") { setLongest(side) }.buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .onAppear { preview.load(context.primary, maxPixel: 300) }
        .onChange(of: preview.originalSize) { _, size in
            if width.isEmpty { width = "\(Int(size.width))"; height = "\(Int(size.height))" }
        }
    }

    @State private var syncing = false
    private func sync(fromWidth text: String) {
        guard lock, !syncing, let w = Double(text), original.width > 0 else { return }
        syncing = true
        height = "\(max(1, Int((w * original.height / original.width).rounded())))"
        DispatchQueue.main.async { syncing = false }
    }
    private func sync(fromHeight text: String) {
        guard lock, !syncing, let h = Double(text), original.height > 0 else { return }
        syncing = true
        width = "\(max(1, Int((h * original.width / original.height).rounded())))"
        DispatchQueue.main.async { syncing = false }
    }
    private func setLongest(_ side: Int) {
        guard original.width > 0 else { return }
        let s = Double(side) / Double(max(original.width, original.height))
        syncing = true
        width = "\(max(1, Int((original.width * s).rounded())))"
        height = "\(max(1, Int((original.height * s).rounded())))"
        DispatchQueue.main.async { syncing = false }
    }
    private var valid: Bool {
        if usePercent || !single { return percent != 100 }
        guard let w = Int(width), let h = Int(height), w > 0, h > 0, w <= 30000, h <= 30000 else { return false }
        return w != Int(original.width) || h != Int(original.height)
    }
    private var footnote: String {
        guard single, original.width > 0 else { return "\(context.files.count) images" }
        if usePercent {
            return "\(Int(original.width)) × \(Int(original.height)) → \(Int(original.width * percent / 100)) × \(Int(original.height * percent / 100)) px"
        }
        return "Original \(Int(original.width)) × \(Int(original.height)) px"
    }
}

// MARK: - Remove background

struct RemoveBackgroundToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var preview = PreviewLoader()
    @State private var cutout: CGImage?
    @State private var failure: String?

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Save PNG", canSubmit: cutout != nil || context.files.count > 1,
                   footnote: failure ?? "The subject is cut out on-device with Vision.", width: 520) {
            context.submit(.removeBackground)
        } content: {
            PreviewSurface(image: cutout ?? preview.image, height: 360)
                .overlay {
                    if cutout == nil && failure == nil {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Finding the subject…").font(.system(size: 12)) }
                            .padding(8).background(.regularMaterial, in: Capsule())
                    }
                }
        }
        .onAppear { preview.load(context.primary, maxPixel: 1000) }
        .onChange(of: preview.image) { _, image in
            guard let image else { return }
            Task.detached(priority: .userInitiated) {
                do {
                    let out = try ImageTools.removeBackground(image)
                    await MainActor.run { cutout = out }
                } catch {
                    await MainActor.run { failure = error.userMessage }
                }
            }
        }
    }
}

// MARK: - Read QR

struct ReadQRToolView: View {
    @ObservedObject var context: ToolContext
    @State private var codes: [ImageTools.DetectedCode] = []
    @State private var done = false
    @State private var copied: UUID?

    var body: some View {
        ToolChrome(context: context, footnote: done ? "\(codes.count) code\(codes.count == 1 ? "" : "s") found · links are never opened automatically" : "Scanning…",
                   width: 520, showsPrimary: false, onSubmit: {}) {
            VStack(alignment: .leading, spacing: 8) {
                if done && codes.isEmpty {
                    Text("No QR code or barcode was found in this image.").font(.system(size: 13)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                }
                ForEach(codes) { code in
                    PanelCard {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(code.symbology).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                                Text(code.payload).font(.system(size: 12.5, design: .monospaced)).textSelection(.enabled).lineLimit(6)
                            }
                            Spacer()
                            VStack(spacing: 6) {
                                Button(copied == code.id ? "Copied" : "Copy") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(code.payload, forType: .string)
                                    copied = code.id
                                }
                                if let url = URL(string: code.payload), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                                    Button("Open Link") { NSWorkspace.shared.open(url) }
                                }
                            }
                            .buttonStyle(.bordered)
                        }
                    }
                }
            }
        }
        .onAppear {
            let url = context.primary
            Task.detached(priority: .userInitiated) {
                let image = ImageEngine.thumbnail(url, maxPixel: 3000)
                let found = image.flatMap { try? ImageTools.readCodes($0) } ?? []
                await MainActor.run { codes = found; done = true }
            }
        }
    }
}

// MARK: - Annotate

struct AnnotateToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var preview = PreviewLoader()
    @State private var items: [Annotation] = []
    @State private var kind: AnnotationKind = .arrow
    @State private var color = RGBAColor(r: 1, g: 0.23, b: 0.19)
    @State private var width = 0.006
    @State private var text = "Text"
    @State private var current: Annotation?

    private let palette: [RGBAColor] = [RGBAColor(r: 1, g: 0.23, b: 0.19), RGBAColor(r: 1, g: 0.58, b: 0), RGBAColor(r: 1, g: 0.8, b: 0),
                                        RGBAColor(r: 0.2, g: 0.78, b: 0.35), RGBAColor(r: 0, g: 0.48, b: 1), .black, .white]

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Save Copy", canSubmit: !items.isEmpty, footnote: "\(items.count) annotation\(items.count == 1 ? "" : "s")", width: 760) {
            context.submit(.annotate(items))
        } content: {
            VStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach(AnnotationKind.allCases) { k in
                        Button { kind = k } label: { Image(systemName: k.symbol).frame(width: 22, height: 18) }
                            .buttonStyle(.bordered)
                            .tint(kind == k ? AppSettings.shared.accentColor : nil)
                            .help(k.title)
                    }
                    Divider().frame(height: 20)
                    ForEach(palette, id: \.self) { c in
                        Circle().fill(c.color).frame(width: 18, height: 18)
                            .overlay(Circle().stroke(Color.primary.opacity(color == c ? 0.9 : 0.2), lineWidth: color == c ? 2 : 1))
                            .onTapGesture { color = c }
                    }
                    Divider().frame(height: 20)
                    Slider(value: $width, in: 0.002...0.02).frame(width: 90).help("Line width")
                    if kind == .text {
                        TextField("Text", text: $text).textFieldStyle(.roundedBorder).frame(width: 120)
                    }
                    Spacer()
                    Button { if !items.isEmpty { items.removeLast() } } label: { Image(systemName: "arrow.uturn.backward") }
                        .keyboardShortcut("z", modifiers: .command).disabled(items.isEmpty).help("Undo")
                    Button("Clear") { items.removeAll() }.disabled(items.isEmpty)
                }
                PreviewSurface(image: preview.image, height: 440) { rect in
                    Canvas { ctx, size in
                        ctx.withCGContext { cg in
                            cg.saveGState()
                            cg.translateBy(x: rect.minX, y: rect.minY)
                            AnnotationRenderer.draw(items + (current.map { [$0] } ?? []), in: cg, size: rect.size)
                            cg.restoreGState()
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                        let a = norm(g.startLocation, rect), b = norm(g.location, rect)
                        current = Annotation(kind: kind, start: a, end: b, color: color, lineWidth: width, text: text,
                                             number: items.filter { $0.kind == .number }.count + 1)
                    }.onEnded { _ in
                        if let c = current { items.append(c) }
                        current = nil
                    })
                }
            }
        }
        .onAppear { preview.load(context.primary, maxPixel: 1600) }
    }

    private func norm(_ p: CGPoint, _ r: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - r.minX) / r.width, 0), 1), y: min(max((p.y - r.minY) / r.height, 0), 1))
    }
}

// MARK: - Make PDF

struct MakePDFToolView: View {
    @ObservedObject var context: ToolContext
    @State private var order: [URL] = []
    @State private var settings = MakePDFSettings()

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Create PDF", canSubmit: !order.isEmpty, footnote: "\(order.count) page\(order.count == 1 ? "" : "s") · drag to reorder", width: 520) {
            var s = settings
            s.order = order
            context.submit(.makePDF(s))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                List {
                    ForEach(order, id: \.self) { url in
                        HStack(spacing: 10) {
                            Thumbnail(url: url).frame(width: 36, height: 36)
                            Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        }
                    }
                    .onMove { order.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { order.remove(atOffsets: $0) }
                }
                .frame(minHeight: 220, maxHeight: .infinity)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                Picker("Page Size", selection: $settings.pageSize) {
                    ForEach(PDFPageSizeChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Margins", selection: $settings.margin) {
                    Text("None").tag(0.0); Text("Small").tag(18.0); Text("Medium").tag(36.0)
                }
                .pickerStyle(.segmented)
                SliderRow(title: "Image Quality", value: $settings.jpegQuality, range: 0.4...1, format: { "\(Int($0 * 100))%" })
            }
        }
        .onAppear { order = context.files }
    }
}

struct Thumbnail: View {
    let url: URL
    @State private var image: CGImage?
    var body: some View {
        Group {
            if let image { Image(decorative: image, scale: 1).resizable().scaledToFit() }
            else { Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().scaledToFit() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task {
            let u = url
            image = await Task.detached { ImageEngine.thumbnail(u, maxPixel: 120) }.value
        }
    }
}
