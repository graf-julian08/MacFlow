import PDFKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - PDF compress

struct PDFCompressToolView: View {
    @ObservedObject var context: ToolContext
    @State private var level: PDFCompressLevel = .balanced

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Compress",
                   footnote: "Original \(context.files.reduce(Int64(0)) { $0 + fileSize(of: $1) }.fileSize) · text and vectors stay sharp", width: 460) {
            context.submit(.pdfCompress(level))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(PDFCompressLevel.allCases) { l in
                    Button { level = l } label: {
                        HStack {
                            Image(systemName: level == l ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(level == l ? AppSettings.shared.accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(l.title).font(.system(size: 13, weight: .medium))
                                Text(l.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(level == l ? 0.08 : 0.04)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

// MARK: - Pages

@MainActor
final class PDFThumbs: ObservableObject {
    @Published var images: [Int: NSImage] = [:]
    var document: PDFDocument?

    func load(_ url: URL) {
        document = PDFDocument(url: url)
        guard let doc = document else { return }
        for i in 0..<min(doc.pageCount, 500) {
            guard let page = doc.page(at: i) else { continue }
            images[i] = page.thumbnail(of: CGSize(width: 150, height: 200), for: .cropBox)
        }
    }
}

struct PagesToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var thumbs = PDFThumbs()
    @State private var items: [PageItem] = []
    @State private var selection: Set<UUID> = []
    @State private var original: [PageItem] = []
    @State private var dragging: PageItem?

    private var changed: Bool {
        items.map(\.sourceIndex) != original.map(\.sourceIndex) || items.contains { $0.rotation % 360 != 0 }
    }

    var body: some View {
        ToolChrome(context: context, primaryTitle: selection.isEmpty ? "Save Copy" : "Save Copy",
                   canSubmit: changed && !items.isEmpty, footnote: "\(items.count) page\(items.count == 1 ? "" : "s") · drag to reorder · ⌘-click to select several", width: 720) {
            context.submit(.pages(items))
        } content: {
            VStack(spacing: 10) {
                HStack {
                    Button { rotate(-90) } label: { Label("Rotate Left", systemImage: "rotate.left") }
                    Button { rotate(90) } label: { Label("Rotate Right", systemImage: "rotate.right") }
                    Button { duplicate() } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                    Button(role: .destructive) { delete() } label: { Label("Delete", systemImage: "trash") }
                    Spacer()
                    Button("Keep Selected Only") { keepSelected() }
                }
                .buttonStyle(.bordered)
                .disabled(selection.isEmpty)
                ScrollView {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(118), spacing: 12), count: 5), spacing: 14) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            pageCell(item, number: index + 1)
                                .onDrag { dragging = item; return NSItemProvider(object: item.id.uuidString as NSString) }
                                .onDrop(of: [.text], delegate: PageDropDelegate(target: item, items: $items, dragging: $dragging))
                        }
                    }
                    .padding(10)
                }
                .frame(height: 420)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
            }
        }
        .onAppear {
            thumbs.load(context.primary)
            let count = thumbs.document?.pageCount ?? 0
            items = (0..<count).map { PageItem(sourceIndex: $0) }
            original = items
        }
    }

    private func pageCell(_ item: PageItem, number: Int) -> some View {
        let selected = selection.contains(item.id)
        return VStack(spacing: 4) {
            Group {
                if let image = thumbs.images[item.sourceIndex] {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    Rectangle().fill(Color.white)
                }
            }
            .frame(width: 100, height: 130)
            .rotationEffect(.degrees(Double(item.rotation)))
            .shadow(color: .black.opacity(0.2), radius: 3, y: 1)
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 8).stroke(selected ? AppSettings.shared.accentColor : .clear, lineWidth: 3))
            Text("\(number)").font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) {
                if selected { selection.remove(item.id) } else { selection.insert(item.id) }
            } else {
                selection = selected && selection.count == 1 ? [] : [item.id]
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: item.rotation)
    }

    private func rotate(_ degrees: Int) {
        for i in items.indices where selection.contains(items[i].id) { items[i].rotation = (items[i].rotation + degrees) % 360 }
    }
    private func duplicate() {
        var result: [PageItem] = []
        for item in items {
            result.append(item)
            if selection.contains(item.id) { var copy = PageItem(sourceIndex: item.sourceIndex); copy.rotation = item.rotation; result.append(copy) }
        }
        withAnimation { items = result }
    }
    private func delete() {
        guard items.count > selection.count else { context.error = "A PDF needs at least one page."; return }
        withAnimation { items.removeAll { selection.contains($0.id) } }
        selection.removeAll()
    }
    private func keepSelected() {
        withAnimation { items.removeAll { !selection.contains($0.id) } }
        selection.removeAll()
    }
}

private struct PageDropDelegate: DropDelegate {
    let target: PageItem
    @Binding var items: [PageItem]
    @Binding var dragging: PageItem?

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging.id != target.id,
              let from = items.firstIndex(where: { $0.id == dragging.id }),
              let to = items.firstIndex(where: { $0.id == target.id }) else { return }
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            items.move(fromOffsets: IndexSet(integer: from), toOffset: to > from ? to + 1 : to)
        }
    }
    func performDrop(info: DropInfo) -> Bool { dragging = nil; return true }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
}

// MARK: - PDF metadata

struct PDFMetadataToolView: View {
    @ObservedObject var context: ToolContext
    @State private var edit = PDFMetadataEdit()
    @State private var original = PDFMetadataEdit()
    @State private var info = ""

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Save Copy", canSubmit: edit != original, footnote: info, width: 480) {
            context.submit(.pdfMetadata(edit))
        } content: {
            VStack(spacing: 8) {
                FieldRow(title: "Title") { TextField("", text: $edit.title).textFieldStyle(.roundedBorder) }
                FieldRow(title: "Author") { TextField("", text: $edit.author).textFieldStyle(.roundedBorder) }
                FieldRow(title: "Subject") { TextField("", text: $edit.subject).textFieldStyle(.roundedBorder) }
                FieldRow(title: "Keywords") { TextField("comma, separated", text: $edit.keywords).textFieldStyle(.roundedBorder) }
                FieldRow(title: "Creator") { TextField("", text: $edit.creator).textFieldStyle(.roundedBorder) }
                HStack {
                    Spacer()
                    Button("Clear All") { edit = PDFMetadataEdit() }.disabled(edit == PDFMetadataEdit())
                }
            }
        }
        .onAppear {
            edit = PDFTools.readMetadata(context.primary)
            original = edit
            if let doc = PDFDocument(url: context.primary) {
                let producer = doc.documentAttributes?[PDFDocumentAttribute.producerAttribute] as? String
                info = "\(doc.pageCount) page\(doc.pageCount == 1 ? "" : "s")" + (producer.map { " · made with \($0)" } ?? "")
            }
        }
    }
}

// MARK: - Protect

struct ProtectToolView: View {
    @ObservedObject var context: ToolContext
    @State private var settings = ProtectSettings()
    @State private var confirm = ""
    @State private var encrypted = false

    var body: some View {
        ToolChrome(context: context, primaryTitle: encrypted ? "Remove Password" : "Protect", canSubmit: valid,
                   footnote: encrypted ? "Enter the current password to save an unprotected copy." : "AES-encrypted. Without the password the PDF cannot be opened.", width: 460) {
            context.submit(.protect(settings))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if encrypted {
                    FieldRow(title: "Current password") { SecureField("", text: $settings.removeWithPassword).textFieldStyle(.roundedBorder) }
                } else {
                    FieldRow(title: "Password") { SecureField("At least 4 characters", text: $settings.password).textFieldStyle(.roundedBorder) }
                    FieldRow(title: "Confirm") { SecureField("", text: $confirm).textFieldStyle(.roundedBorder) }
                    if !confirm.isEmpty && confirm != settings.password {
                        Text("The passwords do not match.").font(.system(size: 11)).foregroundStyle(Color(nsColor: .systemRed))
                    }
                    Toggle("Allow printing", isOn: $settings.allowPrinting)
                    Toggle("Allow copying text and images", isOn: $settings.allowCopying)
                }
            }
        }
        .onAppear { encrypted = PDFDocument(url: context.primary)?.isEncrypted ?? false }
    }

    private var valid: Bool {
        encrypted ? !settings.removeWithPassword.isEmpty : (settings.password.count >= 4 && settings.password == confirm)
    }
}

// MARK: - Watermark & page numbers

@MainActor
final class PDFFirstPage: ObservableObject {
    @Published var image: CGImage?
    func load(_ url: URL) {
        Task.detached {
            let img = PDFDocument(url: url)?.page(at: 0).flatMap { try? PDFEngine.render($0, dpi: 72) }
            await MainActor.run { self.image = img }
        }
    }
}

struct WatermarkToolView: View {
    @ObservedObject var context: ToolContext
    @State private var settings = WatermarkSettings()
    @StateObject private var page = PDFFirstPage()

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Add Watermark", canSubmit: !settings.text.trimmingCharacters(in: .whitespaces).isEmpty,
                   footnote: "Added to every page. Text, links and form fields are kept.", width: 640) {
            context.submit(.watermark(settings))
        } content: {
            HStack(alignment: .top, spacing: 16) {
                PreviewSurface(image: page.image, height: 320, checkerboard: false) { rect in
                    Text(settings.text)
                        .font(.system(size: settings.fontSize * rect.width / 595, weight: .bold))
                        .foregroundStyle(settings.color.color.opacity(settings.opacity))
                        .rotationEffect(.degrees(settings.diagonal ? -Double(atan2(rect.height, rect.width) * 180 / .pi) : 0))
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }
                .frame(width: 250)
                VStack(alignment: .leading, spacing: 10) {
                    TextField("Watermark text", text: $settings.text).textFieldStyle(.roundedBorder)
                    SliderRow(title: "Size", value: $settings.fontSize, range: 12...140, format: { "\(Int($0)) pt" })
                    SliderRow(title: "Opacity", value: $settings.opacity, range: 0.05...0.8, format: { "\(Int($0 * 100))%" })
                    HStack {
                        Text("Colour").font(.system(size: 12)).frame(width: 92, alignment: .leading)
                        ColorPicker("", selection: Binding(get: { settings.color.color }, set: { settings.color = RGBAColor($0) }), supportsOpacity: false).labelsHidden()
                    }
                    Toggle("Diagonal", isOn: $settings.diagonal)
                    Toggle("Repeat across the page", isOn: $settings.tiled)
                }
            }
        }
        .onAppear { page.load(context.primary) }
    }
}

struct PageNumbersToolView: View {
    @ObservedObject var context: ToolContext
    @State private var settings = PageNumberSettings()
    @StateObject private var page = PDFFirstPage()

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Add Numbers", footnote: "Numbers are drawn on every page.", width: 600) {
            context.submit(.pageNumbers(settings))
        } content: {
            HStack(alignment: .top, spacing: 16) {
                PreviewSurface(image: page.image, height: 300, checkerboard: false) { rect in
                    let top = [.topLeft, .topCenter, .topRight].contains(settings.position)
                    let x: CGFloat = {
                        switch settings.position {
                        case .bottomLeft, .topLeft: return rect.minX + 24
                        case .bottomRight, .topRight: return rect.maxX - 24
                        default: return rect.midX
                        }
                    }()
                    Text(sample)
                        .font(.system(size: max(6, settings.fontSize * rect.width / 595), weight: .bold))
                        .foregroundStyle(Color.black.opacity(0.85))
                        .position(x: x, y: top ? rect.minY + 14 : rect.maxY - 14)
                        .allowsHitTesting(false)
                }
                .frame(width: 230)
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Position", selection: $settings.position) {
                        ForEach(OverlayPosition.allCases) { Text($0.title).tag($0) }
                    }
                    Picker("Style", selection: $settings.style) {
                        ForEach(PageNumberStyle.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper("Start at \(settings.startAt)", value: $settings.startAt, in: 0...9999)
                    SliderRow(title: "Size", value: $settings.fontSize, range: 7...24, format: { "\(Int($0)) pt" })
                    Toggle("Skip first page", isOn: $settings.skipFirstPage)
                }
            }
        }
        .onAppear { page.load(context.primary) }
    }

    private var sample: String {
        switch settings.style {
        case .plain: return "\(settings.startAt)"
        case .pageN: return "Page \(settings.startAt)"
        case .nOfTotal: return "\(settings.startAt) / \(max(1, PDFTools.pageCount(context.primary)))"
        }
    }
}

// MARK: - OCR

struct OCRToolView: View {
    @ObservedObject var context: ToolContext
    @State private var output: OCROutput = .searchablePDF

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Recognise Text", footnote: "Runs on-device with Apple Vision. Pages that already contain text are kept as they are.", width: 480) {
            context.submit(.ocr(output))
        } content: {
            Picker("Output", selection: $output) {
                ForEach(OCROutput.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.radioGroup)
        }
    }
}

// MARK: - Split & merge

struct SplitToolView: View {
    @ObservedObject var context: ToolContext
    @State private var mode = 0
    @State private var every = 2
    @State private var ranges = "1-3, 4-"

    private var pages: Int { PDFTools.pageCount(context.primary) }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Split", canSubmit: pages > 1, footnote: "\(pages) pages · results go into a new folder", width: 460) {
            switch mode {
            case 0: context.submit(.split(.everyPage))
            case 1: context.submit(.split(.everyN(every)))
            default: context.submit(.split(.ranges(ranges)))
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $mode) {
                    Text("Every page").tag(0); Text("Every N pages").tag(1); Text("Page ranges").tag(2)
                }
                .pickerStyle(.radioGroup).labelsHidden()
                if mode == 1 { Stepper("\(every) pages per file", value: $every, in: 1...max(1, pages - 1)) }
                if mode == 2 {
                    TextField("e.g. 1-3, 5, 8-", text: $ranges).textFieldStyle(.roundedBorder)
                    Text("Each range becomes one PDF.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct MergeToolView: View {
    @ObservedObject var context: ToolContext
    @State private var order: [URL] = []

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Merge", canSubmit: order.count >= 2,
                   footnote: "\(order.reduce(0) { $0 + PDFTools.pageCount($1) }) pages in total · drag to reorder", width: 480) {
            context.submit(.merge(order))
        } content: {
            List {
                ForEach(order, id: \.self) { url in
                    HStack {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 24, height: 24)
                        Text(url.lastPathComponent).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text("\(PDFTools.pageCount(url)) p.").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .onMove { order.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(height: 240)
            .scrollContentBackground(.hidden)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        }
        .onAppear { order = context.files }
    }
}

// MARK: - Archive contents

struct ArchiveContentsToolView: View {
    @ObservedObject var context: ToolContext
    @State private var entries: [ArchiveEngine.Entry] = []
    @State private var selected: Set<String> = []
    @State private var password = ""
    @State private var needsPassword = false
    @State private var loading = true
    @State private var loadError: String?

    private var files: [ArchiveEngine.Entry] { entries.filter { !$0.isDirectory } }

    var body: some View {
        ToolChrome(context: context, primaryTitle: selected.isEmpty || selected.count == files.count ? "Extract All" : "Extract \(selected.count)",
                   canSubmit: !loading && loadError == nil, footnote: summary, width: 560) {
            let selection = selected.isEmpty || selected.count == files.count ? nil : Array(selected)
            context.submit(.extract(password: password.isEmpty ? nil : password, selection: selection))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                if needsPassword {
                    HStack {
                        SecureField("Archive password", text: $password).textFieldStyle(.roundedBorder)
                        Button("Unlock") { load() }.disabled(password.isEmpty)
                    }
                }
                if let loadError {
                    Text(loadError).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                List(files, id: \.path) { entry in
                    HStack {
                        Toggle("", isOn: Binding(get: { selected.contains(entry.path) }, set: { on in
                            if on { selected.insert(entry.path) } else { selected.remove(entry.path) }
                        }))
                        .labelsHidden()
                        Image(systemName: entry.isSymlink ? "link" : "doc").foregroundStyle(.secondary)
                        Text(entry.path).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(entry.size.fileSize).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 300)
                .scrollContentBackground(.hidden)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                .overlay { if loading { ProgressView() } }
                HStack {
                    Button("Select All") { selected = Set(files.map(\.path)) }
                    Button("Select None") { selected.removeAll() }
                }
                .buttonStyle(.bordered)
                .disabled(files.isEmpty)
            }
        }
        .onAppear(perform: load)
    }

    private var summary: String {
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        return "\(files.count) files · \(total.fileSize) uncompressed"
    }

    private func load() {
        loading = true
        let url = context.primary
        let pw = password.isEmpty ? nil : password
        Task {
            do {
                entries = try await ArchiveEngine.list(url, passphrase: pw)
                loadError = nil
                needsPassword = false
            } catch {
                loadError = error.userMessage
                needsPassword = error.userMessage.contains("encrypted")
            }
            loading = false
        }
    }
}

// MARK: - Subtitles

struct ShiftTimingToolView: View {
    @ObservedObject var context: ToolContext
    @State private var milliseconds = 0
    @State private var cues: [SubtitleCue] = []

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Shift", canSubmit: milliseconds != 0, footnote: "All \(cues.count) subtitles move by the same amount.", width: 520) {
            context.submit(.shiftTiming(milliseconds: milliseconds))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Shift by").font(.system(size: 12))
                    TextField("ms", value: $milliseconds, format: .number).textFieldStyle(.roundedBorder).frame(width: 90)
                    Text("ms").foregroundStyle(.secondary)
                    Stepper("", value: $milliseconds, step: 100).labelsHidden()
                    Spacer()
                    ForEach([-1000, -100, 100, 1000], id: \.self) { d in
                        Button(d > 0 ? "+\(d)" : "\(d)") { milliseconds += d }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                PanelCard {
                    ForEach(Array(cues.prefix(4).enumerated()), id: \.offset) { _, cue in
                        HStack(alignment: .top) {
                            Text("\(SubtitleEngine.format(cue.start + milliseconds, separator: ",")) →")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(cue.start + milliseconds < 0 ? Color(nsColor: .systemRed) : .secondary)
                            Text(cue.text).font(.system(size: 12)).lineLimit(1)
                        }
                    }
                }
            }
        }
        .onAppear {
            if let text = try? DocumentEngine.readText(context.primary), let format = context.primaryFormat {
                cues = (try? SubtitleEngine.parse(text, format: format.id)) ?? []
            }
        }
    }
}
