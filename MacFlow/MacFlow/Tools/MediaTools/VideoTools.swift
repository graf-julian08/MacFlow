import AVFoundation
import CoreMedia
import Foundation
import ImageIO

enum VideoCodecChoice: String, CaseIterable, Sendable, Identifiable {
    case hevc, h264
    var id: String { rawValue }
    var title: String { self == .hevc ? "HEVC (smaller)" : "H.264 (compatible)" }
}

enum VideoQualityChoice: String, CaseIterable, Sendable, Identifiable {
    case high, medium, low
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    /// Bits per pixel per frame.
    func bitsPerPixel(_ codec: VideoCodecChoice) -> Double {
        switch (self, codec) {
        case (.high, .h264): return 0.11
        case (.medium, .h264): return 0.075
        case (.low, .h264): return 0.045
        case (.high, .hevc): return 0.075
        case (.medium, .hevc): return 0.05
        case (.low, .hevc): return 0.03
        }
    }
}

struct VideoCompressSettings: Sendable, Equatable {
    var codec: VideoCodecChoice = .hevc
    var quality: VideoQualityChoice = .medium
    /// Shorter side limit (1080 = "1080p"); nil keeps the resolution.
    var maxShortSide: Int?
    var limitTo30fps = false
}

/// Video tools. Trim, rotate and mute never re-encode.
enum VideoTools {

    static func outputType(for source: FileFormat) -> (AVFileType, FileFormat) {
        let registry = FormatRegistry.shared
        switch source.id {
        case "mov": return (.mov, registry["mov"])
        case "m4v": return (.m4v, registry["m4v"])
        default: return (.mp4, registry["mp4"])
        }
    }

    // MARK: - Compress (AVAssetReader → AVAssetWriter)

    static func targetSize(display: CGSize, maxShortSide: Int?) -> CGSize {
        var w = display.width, h = display.height
        if let limit = maxShortSide, min(w, h) > CGFloat(limit) {
            let s = CGFloat(limit) / min(w, h)
            w *= s; h *= s
        }
        // Encoders need even dimensions.
        return CGSize(width: max(2, (w / 2).rounded() * 2), height: max(2, (h / 2).rounded() * 2))
    }

    static func estimatedBytes(duration: Double, display: CGSize, fps: Float, settings: VideoCompressSettings, hasAudio: Bool) -> Int64 {
        let size = targetSize(display: display, maxShortSide: settings.maxShortSide)
        let rate = Double(settings.limitTo30fps ? min(fps, 30) : (fps > 0 ? fps : 30))
        let videoBits = settings.quality.bitsPerPixel(settings.codec) * Double(size.width * size.height) * rate
        let audioBits = hasAudio ? 160_000.0 : 0
        return Int64((videoBits + audioBits) * duration / 8)
    }

    static func compress(source url: URL, settings: VideoCompressSettings, destination: URL, fileType: AVFileType, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        guard let video = try await asset.loadTracks(withMediaType: .video).first else { throw MacFlowError("This file has no video track.") }
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration)
        let natural = try await video.load(.naturalSize)
        let transform = try await video.load(.preferredTransform)
        let nominalFPS = try await video.load(.nominalFrameRate)
        let displayed = natural.applying(transform)
        let display = CGSize(width: abs(displayed.width), height: abs(displayed.height))
        let size = targetSize(display: display, maxShortSide: settings.maxShortSide)
        let fps = settings.limitTo30fps ? min(nominalFPS > 0 ? nominalFPS : 30, 30) : (nominalFPS > 0 ? nominalFPS : 30)

        // Composition renders the upright, scaled frame.
        let composition = AVMutableVideoComposition()
        composition.renderSize = size
        composition.frameDuration = CMTime(value: 1000, timescale: CMTimeScale((fps * 1000).rounded()))
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: video)
        let scale = size.width / display.width
        layer.setTransform(transform.concatenating(CGAffineTransform(scaleX: scale, y: size.height / display.height)), at: .zero)
        _ = scale
        instruction.layerInstructions = [layer]
        composition.instructions = [instruction]

        let reader = try AVAssetReader(asset: asset)
        let videoOut = AVAssetReaderVideoCompositionOutput(videoTracks: [video], videoSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        videoOut.videoComposition = composition
        videoOut.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOut) else { throw MacFlowError("The video cannot be decoded.") }
        reader.add(videoOut)

        let writer = try AVAssetWriter(outputURL: destination, fileType: fileType)
        writer.shouldOptimizeForNetworkUse = fileType != .mov
        let bitrate = settings.quality.bitsPerPixel(settings.codec) * Double(size.width * size.height) * Double(fps)
        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(bitrate),
            AVVideoExpectedSourceFrameRateKey: Int(fps.rounded()),
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
        ]
        if settings.codec == .h264 { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        let videoIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: Int(size.width),
            AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
        ])
        videoIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(videoIn) else { throw MacFlowError("The encoder rejected these settings.") }
        writer.add(videoIn)
        if settings.codec == .hevc && fileType != .mov {
            // 'hvc1' tagging is applied by AVAssetWriter automatically.
        }

        // Audio: AAC is passed through untouched, anything else becomes AAC.
        var audioPairs: [(AVAssetReaderTrackOutput, AVAssetWriterInput)] = []
        for track in audioTracks {
            let desc = try await track.load(.formatDescriptions).first
            let isAAC = desc.map { CMFormatDescriptionGetMediaSubType($0) == kAudioFormatMPEG4AAC } ?? false
            let output: AVAssetReaderTrackOutput
            let input: AVAssetWriterInput
            if isAAC {
                output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: desc)
            } else {
                output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
                let asbd = desc.flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
                let channels = min(Int(asbd?.mChannelsPerFrame ?? 2), 2)
                input = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: min(asbd?.mSampleRate ?? 48_000, 48_000),
                    AVNumberOfChannelsKey: channels,
                    AVEncoderBitRateKey: channels == 1 ? 96_000 : 160_000,
                ])
            }
            input.expectsMediaDataInRealTime = false
            guard reader.canAdd(output), writer.canAdd(input) else { continue }
            reader.add(output)
            writer.add(input)
            audioPairs.append((output, input))
        }

        guard reader.startReading() else { throw MacFlowError("The video could not be read.", detail: reader.error?.localizedDescription) }
        guard writer.startWriting() else { throw MacFlowError("The video could not be written.", detail: writer.error?.localizedDescription) }
        writer.startSession(atSourceTime: .zero)

        let total = max(duration.seconds, 0.001)
        let cancelled = CancelFlag()
        try await withTaskCancellationHandler {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    try await pump(output: videoOut, input: videoIn, cancelled: cancelled) { time in
                        progress(min(0.99, time.seconds / total))
                    }
                }
                for (output, input) in audioPairs {
                    group.addTask { try await pump(output: output, input: input, cancelled: cancelled, onSample: nil) }
                }
                try await group.waitForAll()
            }
        } onCancel: {
            cancelled.set()
        }
        if cancelled.isSet || Task.isCancelled {
            reader.cancelReading()
            writer.cancelWriting()
            throw CancellationError()
        }
        if reader.status == .failed {
            writer.cancelWriting()
            throw MacFlowError("Reading the video failed.", detail: reader.error?.localizedDescription)
        }
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw MacFlowError("Writing the video failed.", detail: writer.error?.localizedDescription)
        }
        progress(1)
    }

    private final class CancelFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    private static func pump(output: AVAssetReaderOutput, input: AVAssetWriterInput, cancelled: CancelFlag,
                             onSample: ((CMTime) -> Void)?) async throws {
        let queue = DispatchQueue(label: "MacFlow.pump.\(UUID().uuidString)")
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            input.requestMediaDataWhenReady(on: queue) {
                guard !finished else { return }
                while input.isReadyForMoreMediaData {
                    if cancelled.isSet {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    guard let sample = output.copyNextSampleBuffer() else {
                        finished = true
                        input.markAsFinished()
                        continuation.resume()
                        return
                    }
                    onSample?(CMSampleBufferGetPresentationTimeStamp(sample))
                    if !input.append(sample) {
                        finished = true
                        input.markAsFinished()
                        continuation.resume(throwing: MacFlowError("The encoder stopped unexpectedly."))
                        return
                    }
                }
            }
        }
    }

    // MARK: - Passthrough edits

    /// Builds a composition containing the asset's tracks (optionally without audio).
    static func composition(of asset: AVAsset, range: CMTimeRange? = nil, includeAudio: Bool = true, extraTransform: CGAffineTransform? = nil) async throws -> AVMutableComposition {
        let composition = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let span = range ?? CMTimeRange(start: .zero, duration: duration)
        for track in try await asset.load(.tracks) {
            guard track.mediaType == .video || (includeAudio && track.mediaType == .audio) else { continue }
            guard let target = composition.addMutableTrack(withMediaType: track.mediaType, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
            try target.insertTimeRange(span, of: track, at: .zero)
            if track.mediaType == .video {
                var t = try await track.load(.preferredTransform)
                if let extra = extraTransform { t = t.concatenating(extra) }
                target.preferredTransform = t
            }
            target.languageCode = try? await track.load(.languageCode)
        }
        return composition
    }

    static func exportPassthrough(_ asset: AVAsset, metadataFrom original: AVAsset, to destination: URL, type: AVFileType, progress: @escaping ProgressHandler) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw MacFlowError("Could not prepare the export.")
        }
        session.metadata = (try? await original.load(.metadata)) ?? []
        try await MediaEngine.run(session, to: destination, as: type, progress: progress)
    }

    static func trim(source url: URL, start: Double, end: Double, destination: URL, type: AVFileType, progress: @escaping ProgressHandler) async throws {
        guard end > start else { throw MacFlowError("The end must come after the start.") }
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let range = CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600))
        let comp = try await composition(of: asset, range: range)
        try await exportPassthrough(comp, metadataFrom: asset, to: destination, type: type, progress: progress)
    }

    static func rotationTransform(quarterTurns: Int, display: CGSize) -> CGAffineTransform {
        let w = display.width, h = display.height
        switch ((quarterTurns % 4) + 4) % 4 {
        case 1: return CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: h, ty: 0)
        case 2: return CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: w, ty: h)
        case 3: return CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: w)
        default: return .identity
        }
    }

    static func rotate(source url: URL, quarterTurns: Int, destination: URL, type: AVFileType, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: url)
        let info = try await MediaEngine.info(url)
        let comp = try await composition(of: asset, extraTransform: rotationTransform(quarterTurns: quarterTurns, display: info.size))
        try await exportPassthrough(comp, metadataFrom: asset, to: destination, type: type, progress: progress)
    }

    static func mute(source url: URL, destination: URL, type: AVFileType, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: url)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else { throw MacFlowError("This video has no sound to remove.") }
        let comp = try await composition(of: asset, includeAudio: false)
        try await exportPassthrough(comp, metadataFrom: asset, to: destination, type: type, progress: progress)
    }

    static func speed(source url: URL, factor: Double, keepPitch: Bool, destination: URL, type: AVFileType, progress: @escaping ProgressHandler) async throws {
        guard factor > 0, factor != 1 else { throw MacFlowError("Choose a speed other than 1×.") }
        let asset = AVURLAsset(url: url)
        let comp = try await composition(of: asset)
        let duration = comp.duration
        comp.scaleTimeRange(CMTimeRange(start: .zero, duration: duration), toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / factor))
        guard let session = AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetHighestQuality) else {
            throw MacFlowError("Could not prepare the export.")
        }
        session.audioTimePitchAlgorithm = keepPitch ? .spectral : .varispeed
        try await MediaEngine.run(session, to: destination, as: type, progress: progress)
    }

    static func snapshot(source url: URL, at seconds: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let (image, _) = try await generator.image(at: CMTime(seconds: seconds, preferredTimescale: 600))
        return image
    }
}

// MARK: - Audio tools

enum ChannelMode: String, CaseIterable, Sendable, Identifiable {
    case mono, stereo, swap, leftOnly, rightOnly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mono: return "Mono"
        case .stereo: return "Stereo"
        case .swap: return "Swap L/R"
        case .leftOnly: return "Left Only"
        case .rightOnly: return "Right Only"
        }
    }
}

enum AudioTools {

    /// Format a processed file is written in: the source format when Core
    /// Audio can write it, otherwise M4A (AAC).
    static func outputFormat(for source: FileFormat) -> FileFormat {
        let registry = FormatRegistry.shared
        switch source.id {
        case "wav", "aiff", "flac", "caf", "m4a": return source
        case "mp3" where EngineCapabilities.shared.ffmpegHasEncoder("libmp3lame"): return source
        case "ogg" where EngineCapabilities.shared.canEncodeOggVorbis: return source
        default: return registry["m4a"]
        }
    }

    /// Processes `source` through `transform` and writes `output`. MP3 output
    /// goes through a lossless intermediate and FFmpeg's LAME encoder.
    static func process(source url: URL, output: FileFormat, destination: URL, progress: @escaping ProgressHandler,
                        range: Range<AVAudioFramePosition>? = nil,
                        transform: ((AVAudioPCMBuffer, AVAudioFramePosition) -> Void)? = nil) async throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: url) } catch { throw MacFlowError.decode(url.lastPathComponent, "Core Audio cannot read this file.") }
        let format = input.processingFormat
        let isFloat = input.fileFormat.streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        if output.id == "mp3" || output.id == "ogg" {
            // Lossy targets written by a helper: process into a lossless
            // intermediate first, then encode once.
            let intermediate = destination.deletingLastPathComponent().appendingPathComponent("intermediate-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: intermediate) }
            let settings = try MediaEngine.audioSettings(for: "wav", sampleRate: format.sampleRate, channels: format.channelCount, bitDepth: 24, isFloat: false, layout: format.channelLayout)
            try await MediaEngine.writeAudio(from: input, settings: settings, to: intermediate, progress: { progress($0 * 0.6) }, range: range, transform: transform)
            try await encodeLossy(intermediate, as: output, destination: destination)
            progress(1)
            return
        }
        let settings = try MediaEngine.audioSettings(for: output.id, sampleRate: format.sampleRate, channels: format.channelCount,
                                                     bitDepth: MediaEngine.sourceBitDepth(input), isFloat: isFloat, layout: format.channelLayout)
        try await MediaEngine.writeAudio(from: input, settings: settings, to: destination, progress: progress, range: range, transform: transform)
    }

    static func frameRange(_ url: URL, start: Double, end: Double) throws -> Range<AVAudioFramePosition> {
        let file = try AVAudioFile(forReading: url)
        let rate = file.processingFormat.sampleRate
        let a = max(0, AVAudioFramePosition((start * rate).rounded()))
        let b = min(file.length, AVAudioFramePosition((end * rate).rounded()))
        guard b > a else { throw MacFlowError("The selection is empty.") }
        return a..<b
    }

    static func peak(_ url: URL) throws -> Float {
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 65_536) else { return 0 }
        var peak: Float = 0
        while file.framePosition < file.length {
            try file.read(into: buffer)
            if buffer.frameLength == 0 { break }
            for c in 0..<Int(buffer.format.channelCount) {
                let data = buffer.floatChannelData![c]
                for i in 0..<Int(buffer.frameLength) { peak = max(peak, abs(data[i])) }
            }
        }
        return peak
    }

    /// Min/max envelope for the waveform view.
    static func waveform(_ url: URL, buckets: Int = 320) -> (peaks: [Float], duration: Double) {
        guard let file = try? AVAudioFile(forReading: url), file.length > 0 else { return ([], 0) }
        let per = max(1, Int(file.length) / buckets)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(per)) else { return ([], 0) }
        var peaks: [Float] = []
        while file.framePosition < file.length, peaks.count < buckets {
            do { try file.read(into: buffer, frameCount: AVAudioFrameCount(per)) } catch { break }
            if buffer.frameLength == 0 { break }
            var p: Float = 0
            for c in 0..<Int(buffer.format.channelCount) {
                let data = buffer.floatChannelData![c]
                var i = 0
                while i < Int(buffer.frameLength) { p = max(p, abs(data[i])); i += 4 }
            }
            peaks.append(min(1, p))
        }
        return (peaks, Double(file.length) / file.processingFormat.sampleRate)
    }

    static func gainTransform(_ gain: Float) -> (AVAudioPCMBuffer, AVAudioFramePosition) -> Void {
        { buffer, _ in
            for c in 0..<Int(buffer.format.channelCount) {
                let data = buffer.floatChannelData![c]
                for i in 0..<Int(buffer.frameLength) { data[i] = max(-1, min(1, data[i] * gain)) }
            }
        }
    }

    static func fadeTransform(fadeIn: Double, fadeOut: Double, totalFrames: AVAudioFramePosition, sampleRate: Double) -> (AVAudioPCMBuffer, AVAudioFramePosition) -> Void {
        let inFrames = Double(fadeIn * sampleRate)
        let outFrames = Double(fadeOut * sampleRate)
        let total = Double(totalFrames)
        return { buffer, offset in
            for i in 0..<Int(buffer.frameLength) {
                let pos = Double(offset) + Double(i)
                var g = 1.0
                if inFrames > 0, pos < inFrames { g = min(g, pos / inFrames) }
                if outFrames > 0, pos > total - outFrames { g = min(g, max(0, (total - pos) / outFrames)) }
                if g >= 1 { continue }
                let curve = Float(g * g) // perceptually smoother than linear
                for c in 0..<Int(buffer.format.channelCount) { buffer.floatChannelData![c][i] *= curve }
            }
        }
    }

    /// Re-maps channels; writes a file with the resulting channel count.
    static func channels(source url: URL, mode: ChannelMode, output: FileFormat, destination: URL, progress: @escaping ProgressHandler) async throws {
        let input = try AVAudioFile(forReading: url)
        let inFormat = input.processingFormat
        let inChannels = Int(inFormat.channelCount)
        if inChannels == 1 && mode != .stereo { throw MacFlowError("This audio is already mono.") }
        if inChannels >= 2 && mode == .stereo && inChannels == 2 { throw MacFlowError("This audio is already stereo.") }
        let outChannels: AVAudioChannelCount = (mode == .mono || mode == .leftOnly || mode == .rightOnly) ? 1 : 2
        guard let outFormat = AVAudioFormat(standardFormatWithSampleRate: inFormat.sampleRate, channels: outChannels) else {
            throw MacFlowError("Unsupported channel layout.")
        }
        let viaHelper = output.id == "mp3" || output.id == "ogg"
        let target = viaHelper ? FormatRegistry.shared["wav"] : output
        let workURL = viaHelper ? destination.deletingLastPathComponent().appendingPathComponent("channels-\(UUID().uuidString).wav") : destination
        defer { if viaHelper { try? FileManager.default.removeItem(at: workURL) } }
        let settings = try MediaEngine.audioSettings(for: target.id, sampleRate: inFormat.sampleRate, channels: outChannels,
                                                     bitDepth: viaHelper ? 24 : MediaEngine.sourceBitDepth(input), isFloat: false, layout: nil)
        // Scoped so the file is closed before FFmpeg reads it.
        do {
            let out = try AVAudioFile(forWriting: workURL, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let chunk: AVAudioFrameCount = 65_536
            guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: chunk),
                  let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: chunk) else { throw MacFlowError("Out of memory.") }
            while input.framePosition < input.length {
                try Task.checkCancellation()
                try input.read(into: inBuf)
                let n = Int(inBuf.frameLength)
                if n == 0 { break }
                outBuf.frameLength = AVAudioFrameCount(n)
                let src = inBuf.floatChannelData!
                let dst = outBuf.floatChannelData!
                for i in 0..<n {
                    let l = src[0][i]
                    let r = inChannels > 1 ? src[1][i] : l
                    switch mode {
                    case .mono:
                        var sum: Float = 0
                        for c in 0..<inChannels { sum += src[c][i] }
                        dst[0][i] = sum / Float(inChannels)
                    case .leftOnly: dst[0][i] = l
                    case .rightOnly: dst[0][i] = r
                    case .stereo: dst[0][i] = l; dst[1][i] = r
                    case .swap: dst[0][i] = r; dst[1][i] = l
                    }
                }
                try out.write(from: outBuf)
                progress(Double(input.framePosition) / Double(max(1, input.length)))
            }
        }
        if viaHelper {
            try await encodeLossy(workURL, as: output, destination: destination)
        }
    }

    /// Encodes a lossless WAV intermediate to MP3 (FFmpeg/LAME) or Ogg Vorbis (oggenc or FFmpeg).
    static func encodeLossy(_ wav: URL, as output: FileFormat, destination: URL) async throws {
        if output.id == "ogg", let oggenc = EngineCapabilities.shared.oggenc {
            try await MediaEngine.encodeOggVorbis(wav: wav, oggenc: oggenc.path, destination: destination)
        } else {
            try await FFmpegEngine.convertAudio(source: wav, target: output, destination: destination, progress: { _ in })
        }
    }
}
