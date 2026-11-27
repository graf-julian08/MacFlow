import AVFoundation
import AVKit
import SwiftUI

// MARK: - Player

struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .minimal
        v.showsFullScreenToggleButton = false
        v.videoGravity = .resizeAspect
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

@MainActor
final class MediaModel: ObservableObject {
    let player: AVPlayer
    @Published var duration: Double = 0
    @Published var current: Double = 0
    @Published var info: MediaEngine.MediaInfo?
    private var observer: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.current = time.seconds }
        }
        Task {
            let i = try? await MediaEngine.info(url)
            info = i
            duration = i?.duration ?? 0
        }
    }

    func seek(_ seconds: Double) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

/// Two-handle range slider.
struct RangeSlider: View {
    @Binding var lower: Double
    @Binding var upper: Double
    let bounds: ClosedRange<Double>
    var minimumSpan: Double = 0.1
    var onScrub: ((Double) -> Void)?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let span = max(bounds.upperBound - bounds.lowerBound, 0.0001)
            let x1 = CGFloat((lower - bounds.lowerBound) / span) * w
            let x2 = CGFloat((upper - bounds.lowerBound) / span) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12)).frame(height: 6)
                Capsule().fill(AppSettings.shared.accentColor).frame(width: max(0, x2 - x1), height: 6).offset(x: x1)
                handle.offset(x: x1 - 8).gesture(DragGesture().onChanged { g in
                    let v = bounds.lowerBound + Double(min(max(0, g.location.x), w) / w) * span
                    lower = min(max(bounds.lowerBound, v), upper - minimumSpan)
                    onScrub?(lower)
                })
                handle.offset(x: x2 - 8).gesture(DragGesture().onChanged { g in
                    let v = bounds.lowerBound + Double(min(max(0, g.location.x), w) / w) * span
                    upper = max(min(bounds.upperBound, v), lower + minimumSpan)
                    onScrub?(upper)
                })
            }
            .frame(height: geo.size.height)
        }
        .frame(height: 22)
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.white).frame(width: 16, height: 22)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
    }
}

// MARK: - Video compress

struct VideoCompressToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var model: MediaModel
    @State private var settings = VideoCompressSettings()

    init(context: ToolContext) {
        self.context = context
        _model = StateObject(wrappedValue: MediaModel(url: context.primary))
    }

    private var resolutions: [Int?] {
        let short = Int(min(model.info?.size.width ?? 0, model.info?.size.height ?? 0))
        return [nil] + [2160, 1440, 1080, 720, 480].filter { short == 0 || $0 < short }
    }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Compress", footnote: estimate, width: 560) {
            model.stop()
            context.submit(.videoCompress(settings))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                PlayerView(player: model.player).frame(height: 240).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Picker("Codec", selection: $settings.codec) {
                    ForEach(VideoCodecChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Quality", selection: $settings.quality) {
                    ForEach(VideoQualityChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Resolution", selection: $settings.maxShortSide) {
                    ForEach(resolutions, id: \.self) { r in Text(r.map { "\($0)p" } ?? "Original").tag(r) }
                }
                .pickerStyle(.menu)
                Toggle("Limit to 30 fps", isOn: $settings.limitTo30fps)
                    .disabled((model.info?.frameRate ?? 0) <= 30.5)
            }
        }
        .onDisappear { model.stop() }
    }

    private var estimate: String {
        let original = context.files.reduce(Int64(0)) { $0 + fileSize(of: $1) }
        guard let info = model.info, context.files.count == 1 else { return "Original \(original.fileSize)" }
        let est = VideoTools.estimatedBytes(duration: info.duration, display: info.size, fps: info.frameRate, settings: settings, hasAudio: info.hasAudio)
        let target = VideoTools.targetSize(display: info.size, maxShortSide: settings.maxShortSide)
        return "\(Int(info.size.width))×\(Int(info.size.height)) → \(Int(target.width))×\(Int(target.height)) · \(original.fileSize) → about \(est.fileSize)"
    }
}

// MARK: - Trim

struct VideoTrimToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var model: MediaModel
    @State private var start: Double = 0
    @State private var end: Double = 0

    init(context: ToolContext) {
        self.context = context
        _model = StateObject(wrappedValue: MediaModel(url: context.primary))
    }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Trim", canSubmit: end > start && (start > 0.01 || end < model.duration - 0.01),
                   footnote: "\(timeString(start)) – \(timeString(end)) · \(timeString(end - start)) · no re-encoding", width: 620) {
            model.stop()
            context.submit(.trim(start: start, end: end))
        } content: {
            VStack(spacing: 12) {
                PlayerView(player: model.player).frame(height: 300).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                RangeSlider(lower: $start, upper: $end, bounds: 0...max(model.duration, 0.1), minimumSpan: 0.1) { model.seek($0) }
                HStack {
                    Button("Set Start") { start = min(model.current, end - 0.1) }
                    Button("Set End") { end = max(model.current, start + 0.1) }
                    Spacer()
                    Button { model.seek(start); model.player.play() } label: { Label("Play Selection", systemImage: "play.fill") }
                }
                .buttonStyle(.bordered)
            }
        }
        .onChange(of: model.duration) { _, d in if end == 0 { end = d } }
        .onChange(of: model.current) { _, t in if t >= end && model.player.rate > 0 { model.player.pause() } }
        .onDisappear { model.stop() }
    }
}

// MARK: - Rotate video

struct VideoRotateToolView: View {
    @ObservedObject var context: ToolContext
    @State private var turns = 1
    @State private var frame: CGImage?

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Rotate", canSubmit: turns % 4 != 0, footnote: "Rotation is stored in the file — no quality loss.", width: 480) {
            context.submit(.videoRotate(((turns % 4) + 4) % 4))
        } content: {
            VStack(spacing: 14) {
                PreviewSurface(image: frame, height: 260, checkerboard: false)
                    .rotationEffect(.degrees(Double(turns) * 90))
                    .animation(.spring(response: 0.35, dampingFraction: 0.8), value: turns)
                HStack {
                    Button { turns -= 1 } label: { Label("Left", systemImage: "rotate.left").frame(maxWidth: .infinity) }
                    Button { turns += 1 } label: { Label("Right", systemImage: "rotate.right").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .task {
            let url = context.primary
            frame = try? await VideoTools.snapshot(source: url, at: 0)
        }
    }
}

// MARK: - Snapshot

struct SnapshotToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var model: MediaModel
    @State private var format = "png"

    init(context: ToolContext) {
        self.context = context
        _model = StateObject(wrappedValue: MediaModel(url: context.primary))
    }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Save Frame", footnote: "Frame at \(timeString(model.current))", width: 600) {
            model.player.pause()
            context.submit(.snapshot(seconds: model.current, formatID: format))
        } content: {
            VStack(spacing: 12) {
                PlayerView(player: model.player).frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                HStack {
                    Button { step(-1) } label: { Image(systemName: "backward.frame.fill") }.help("Previous frame")
                    Button { step(1) } label: { Image(systemName: "forward.frame.fill") }.help("Next frame")
                    Spacer()
                    Picker("Format", selection: $format) {
                        Text("PNG").tag("png"); Text("JPEG").tag("jpg"); Text("HEIC").tag("heic")
                    }
                    .pickerStyle(.segmented).frame(width: 200)
                }
                .buttonStyle(.bordered)
            }
        }
        .onDisappear { model.stop() }
    }

    private func step(_ frames: Int) {
        model.player.pause()
        model.player.currentItem?.step(byCount: frames)
    }
}

// MARK: - Speed

struct SpeedToolView: View {
    @ObservedObject var context: ToolContext
    @State private var factor = 2.0
    @State private var keepPitch = true
    @StateObject private var model: MediaModel

    init(context: ToolContext) {
        self.context = context
        _model = StateObject(wrappedValue: MediaModel(url: context.primary))
    }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Apply", footnote: "New length \(timeString(model.duration / factor))", width: 460) {
            context.submit(.speed(factor, keepPitch: keepPitch))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                Picker("Speed", selection: $factor) {
                    ForEach([0.25, 0.5, 0.75, 1.25, 1.5, 2.0, 4.0], id: \.self) { f in
                        Text(f == f.rounded() ? "\(Int(f))×" : String(format: "%.2g×", f)).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                Toggle("Keep audio pitch", isOn: $keepPitch)
            }
        }
        .onDisappear { model.stop() }
    }
}

// MARK: - Audio

@MainActor
final class WaveformModel: ObservableObject {
    @Published var peaks: [Float] = []
    @Published var duration: Double = 0
    var player: AVAudioPlayer?
    private var stopWork: DispatchWorkItem?

    func load(_ url: URL) {
        player = try? AVAudioPlayer(contentsOf: url)
        player?.prepareToPlay()
        Task.detached(priority: .userInitiated) {
            let result = AudioTools.waveform(url)
            await MainActor.run { self.peaks = result.peaks; self.duration = result.duration }
        }
    }

    func play(from: Double, to: Double) {
        guard let player else { return }
        stopWork?.cancel()
        player.currentTime = from
        player.play()
        let work = DispatchWorkItem { [weak player] in player?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, to - from), execute: work)
    }

    func stop() { stopWork?.cancel(); player?.stop() }
}

struct WaveformView: View {
    let peaks: [Float]
    var selection: ClosedRange<Double>? = nil
    var duration: Double = 1
    var envelope: ((Double) -> Double)? = nil

    var body: some View {
        Canvas { ctx, size in
            guard !peaks.isEmpty else { return }
            let barWidth = size.width / CGFloat(peaks.count)
            for (i, p) in peaks.enumerated() {
                let t = Double(i) / Double(peaks.count) * duration
                var amp = CGFloat(p)
                if let envelope { amp = min(1, amp * CGFloat(envelope(t))) }
                let h = max(1, amp * size.height)
                let inside = selection.map { $0.contains(t) } ?? true
                let rect = CGRect(x: CGFloat(i) * barWidth, y: (size.height - h) / 2, width: max(1, barWidth - 1), height: h)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(inside ? AppSettings.shared.accentColor : Color.primary.opacity(0.25)))
            }
        }
        .frame(height: 90)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
    }
}

@MainActor
private func audioOutputNote(_ context: ToolContext) -> String {
    guard let format = context.primaryFormat else { return "" }
    let out = AudioTools.outputFormat(for: format)
    return out == format ? "Saved as \(out.label)" : "Saved as \(out.label) (\(format.label) cannot be written here)"
}

struct AudioTrimToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var wave = WaveformModel()
    @State private var start: Double = 0
    @State private var end: Double = 0

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Trim", canSubmit: end > start && (start > 0.001 || end < wave.duration - 0.001),
                   footnote: "\(timeString(start)) – \(timeString(end)) · \(audioOutputNote(context))", width: 600) {
            wave.stop()
            context.submit(.audioTrim(start: start, end: end))
        } content: {
            VStack(spacing: 12) {
                WaveformView(peaks: wave.peaks, selection: start...max(start, end), duration: max(wave.duration, 0.001))
                RangeSlider(lower: $start, upper: $end, bounds: 0...max(wave.duration, 0.01), minimumSpan: 0.05)
                HStack {
                    Button { wave.play(from: start, to: end) } label: { Label("Play Selection", systemImage: "play.fill") }
                    Button { wave.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    Spacer()
                }
                .buttonStyle(.bordered)
            }
        }
        .onAppear { wave.load(context.primary) }
        .onChange(of: wave.duration) { _, d in if end == 0 { end = d } }
        .onDisappear { wave.stop() }
    }
}

struct VolumeToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var wave = WaveformModel()
    @State private var gain: Double = 3
    @State private var normalize = false

    private var peak: Float { wave.peaks.max() ?? 0 }
    private var clips: Bool { !normalize && Double(peak) * pow(10, gain / 20) > 1.0 }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Apply", canSubmit: normalize || abs(gain) > 0.05,
                   footnote: clips ? "⚠︎ Peaks will be clipped at this level." : audioOutputNote(context), width: 520) {
            context.submit(.volume(gainDB: gain, normalize: normalize))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                WaveformView(peaks: wave.peaks, duration: max(wave.duration, 0.001),
                             envelope: { _ in normalize ? (peak > 0 ? 0.891 / Double(peak) : 1) : pow(10, gain / 20) })
                Toggle("Normalize to −1 dBFS", isOn: $normalize)
                SliderRow(title: "Gain", value: $gain, range: -20...20, step: 0.5, format: { String(format: "%+.1f dB", $0) }, neutral: 0)
                    .disabled(normalize)
            }
        }
        .onAppear { wave.load(context.primary) }
    }
}

struct FadeToolView: View {
    @ObservedObject var context: ToolContext
    @StateObject private var wave = WaveformModel()
    @State private var fadeIn: Double = 2
    @State private var fadeOut: Double = 3

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Apply", canSubmit: fadeIn > 0 || fadeOut > 0, footnote: audioOutputNote(context), width: 520) {
            context.submit(.fade(fadeIn: fadeIn, fadeOut: fadeOut))
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                WaveformView(peaks: wave.peaks, duration: max(wave.duration, 0.001), envelope: { t in
                    var g = 1.0
                    if fadeIn > 0, t < fadeIn { g = min(g, pow(t / fadeIn, 2)) }
                    if fadeOut > 0, t > wave.duration - fadeOut { g = min(g, pow(max(0, wave.duration - t) / fadeOut, 2)) }
                    return g
                })
                SliderRow(title: "Fade In", value: $fadeIn, range: 0...max(0.5, min(30, wave.duration / 2)), step: 0.1, format: { String(format: "%.1f s", $0) })
                SliderRow(title: "Fade Out", value: $fadeOut, range: 0...max(0.5, min(30, wave.duration / 2)), step: 0.1, format: { String(format: "%.1f s", $0) })
            }
        }
        .onAppear { wave.load(context.primary) }
    }
}

struct ChannelsToolView: View {
    @ObservedObject var context: ToolContext
    @State private var mode: ChannelMode = .mono
    @State private var channels = 0

    private var available: [ChannelMode] {
        channels == 1 ? [.stereo] : [.mono, .swap, .leftOnly, .rightOnly]
    }

    var body: some View {
        ToolChrome(context: context, primaryTitle: "Apply", canSubmit: available.contains(mode), footnote: audioOutputNote(context), width: 460) {
            context.submit(.channels(mode))
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text(channels == 0 ? " " : "Source: \(channels == 1 ? "Mono" : channels == 2 ? "Stereo" : "\(channels) channels")")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Picker("Output", selection: $mode) {
                    ForEach(available) { Text($0.title).tag($0) }
                }
                .pickerStyle(.radioGroup)
            }
        }
        .onAppear {
            channels = Int((try? AVAudioFile(forReading: context.primary))?.processingFormat.channelCount ?? 2)
            mode = available.first ?? .mono
        }
    }
}
