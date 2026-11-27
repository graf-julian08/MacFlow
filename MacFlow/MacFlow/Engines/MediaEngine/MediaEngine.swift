import AVFoundation
import CoreMedia
import Foundation
import ImageIO

typealias ProgressHandler = @Sendable (Double) -> Void

/// Audio/video conversions. AVFoundation (hardware accelerated on Apple
/// Silicon) is used whenever it can read the source; an FFmpeg found on the
/// system is used for containers and codecs AVFoundation cannot handle.
enum MediaEngine {

    static func fileType(for formatID: String) -> AVFileType? {
        switch formatID {
        case "mp4": return .mp4
        case "mov": return .mov
        case "m4v": return .m4v
        case "m4a": return .m4a
        case "wav": return .wav
        case "aiff": return .aiff
        case "caf": return .caf
        case "3gp": return .mobile3GPP
        default: return nil
        }
    }

    // MARK: - Entry point

    static func convert(source: URL, sourceFormat: FileFormat, target: FileFormat, destination: URL, progress: @escaping ProgressHandler) async throws -> String? {
        let avVideo = ConversionCatalog.avVideoSources.contains(sourceFormat.id)
        let avAudio = ConversionCatalog.avAudioSources.contains(sourceFormat.id)

        switch target.category {
        case .image where target.id == "gif":
            if avVideo, let note = try? await videoToGIF(source: source, destination: destination, progress: progress) { return note }
            try await FFmpegEngine.videoToGIF(source: source, destination: destination, progress: progress)
            return nil
        case .video:
            if avVideo {
                do {
                    try await exportVideo(source: source, target: target, destination: destination, progress: progress)
                    return nil
                } catch let error where !error.isCancellation && EngineCapabilities.shared.ffmpeg != nil {
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            try await FFmpegEngine.convertVideo(source: source, target: target, destination: destination, progress: progress)
            return nil
        case .audio:
            if sourceFormat.category == .video {
                if avVideo && target.id == "m4a" {
                    try await extractAudioM4A(source: source, destination: destination, progress: progress)
                    return nil
                }
                try await FFmpegEngine.convertAudio(source: source, target: target, destination: destination, progress: progress)
                return nil
            }
            if target.id == "ogg", let oggenc = EngineCapabilities.shared.oggenc {
                try await encodeOggVorbis(source: source, sourceFormat: sourceFormat, oggenc: oggenc.path, destination: destination, progress: progress)
                return nil
            }
            let ffmpegOnlyTarget = ["mp3", "opus", "ogg"].contains(target.id)
            if avAudio && !ffmpegOnlyTarget {
                do {
                    if target.id == "m4a" {
                        try await exportAudioM4A(source: source, destination: destination, progress: progress)
                    } else {
                        try await transcodeAudio(source: source, target: target, destination: destination, progress: progress)
                    }
                    return nil
                } catch let error where !error.isCancellation && EngineCapabilities.shared.ffmpeg != nil {
                    try? FileManager.default.removeItem(at: destination)
                }
            }
            try await FFmpegEngine.convertAudio(source: source, target: target, destination: destination, progress: progress)
            return nil
        default:
            throw MacFlowError.unsupported("Converting to \(target.label)")
        }
    }

    // MARK: - Export sessions

    /// Runs an export session with progress and cancellation.
    static func run(_ session: AVAssetExportSession, to url: URL, as type: AVFileType, progress: @escaping ProgressHandler) async throws {
        let monitor = Task {
            for await state in session.states(updateInterval: 0.25) {
                if case .exporting(let p) = state { progress(p.fractionCompleted) }
            }
        }
        defer { monitor.cancel() }
        do {
            try await session.export(to: url, as: type)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw MacFlowError("The media export failed.", detail: (error as NSError).localizedFailureReason ?? error.localizedDescription)
        }
        progress(1)
    }

    static func exportVideo(source: URL, target: FileFormat, destination: URL, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: source)
        guard try await asset.load(.isReadable) else { throw MacFlowError.decode(source.lastPathComponent, "AVFoundation cannot read this video.") }
        guard let type = fileType(for: target.id) else { throw MacFlowError.unsupported("Writing \(target.label)") }
        // Container change without re-encoding when the codecs fit the target.
        var preset = AVAssetExportPresetPassthrough
        if !(await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: type)) {
            preset = AVAssetExportPresetHighestQuality
            guard await AVAssetExportSession.compatibility(ofExportPreset: preset, with: asset, outputFileType: type) else {
                throw MacFlowError("This video cannot be written as \(target.label).")
            }
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MacFlowError("Could not prepare the video export.")
        }
        session.shouldOptimizeForNetworkUse = target.id != "mov"
        try await run(session, to: destination, as: type, progress: progress)
    }

    static func extractAudioM4A(source: URL, destination: URL, progress: @escaping ProgressHandler) async throws {
        let asset = AVURLAsset(url: source)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        guard !audio.isEmpty else { throw MacFlowError("This video has no audio track.") }
        try await exportAudioM4A(asset: asset, destination: destination, progress: progress)
    }

    static func exportAudioM4A(source: URL, destination: URL, progress: @escaping ProgressHandler) async throws {
        try await exportAudioM4A(asset: AVURLAsset(url: source), destination: destination, progress: progress)
    }

    private static func exportAudioM4A(asset: AVAsset, destination: URL, progress: @escaping ProgressHandler) async throws {
        // Keeps tags and artwork; AAC sources are passed through untouched.
        var preset = AVAssetExportPresetAppleM4A
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let track = audioTracks.first, let desc = try await track.load(.formatDescriptions).first,
           CMFormatDescriptionGetMediaSubType(desc) == kAudioFormatMPEG4AAC,
           await AVAssetExportSession.compatibility(ofExportPreset: AVAssetExportPresetPassthrough, with: asset, outputFileType: .m4a) {
            preset = AVAssetExportPresetPassthrough
        }
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw MacFlowError("Could not prepare the audio export.")
        }
        if preset == AVAssetExportPresetPassthrough {
            // Passthrough of a movie would also copy video; restrict to audio.
            let composition = AVMutableComposition()
            let duration = try await asset.load(.duration)
            for track in audioTracks {
                let t = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
                try t?.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: track, at: .zero)
            }
            guard let audioOnly = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
                throw MacFlowError("Could not prepare the audio export.")
            }
            audioOnly.metadata = try await asset.load(.metadata)
            try await run(audioOnly, to: destination, as: .m4a, progress: progress)
            return
        }
        try await run(session, to: destination, as: .m4a, progress: progress)
    }

    // MARK: - Ogg Vorbis (oggenc)

    /// Decodes to a lossless 24-bit WAV, then encodes with oggenc (-q 6 ≈ 192 kbit/s).
    static func encodeOggVorbis(source: URL, sourceFormat: FileFormat, oggenc: String, destination: URL, progress: @escaping ProgressHandler) async throws {
        let wav = destination.deletingLastPathComponent().appendingPathComponent("oggenc-input-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wav) }
        let wavFormat = FormatRegistry.shared["wav"]
        if ConversionCatalog.avAudioSources.contains(sourceFormat.id) {
            try await transcodeAudio(source: source, target: wavFormat, destination: wav, progress: { progress($0 * 0.5) })
        } else {
            try await FFmpegEngine.convertAudio(source: source, target: wavFormat, destination: wav, progress: { progress($0 * 0.5) })
        }
        try await encodeOggVorbis(wav: wav, oggenc: oggenc, destination: destination)
        progress(1)
    }

    static func encodeOggVorbis(wav: URL, oggenc: String, destination: URL) async throws {
        try await ProcessRunner.runChecked(oggenc, ["--quiet", "--quality", "6", "--output", destination.path, wav.path], tool: "oggenc", timeout: 6 * 3600)
    }

    // MARK: - Audio transcoding (AVAudioFile)

    /// Bit depth of a PCM/lossless source; 16 for lossy sources.
    static func sourceBitDepth(_ file: AVAudioFile) -> Int {
        let asbd = file.fileFormat.streamDescription.pointee
        switch asbd.mFormatID {
        case kAudioFormatLinearPCM:
            return Int(asbd.mBitsPerChannel)
        case kAudioFormatAppleLossless, kAudioFormatFLAC:
            switch asbd.mFormatFlags {
            case 1: return 16
            case 2: return 20
            case 3: return 24
            case 4: return 32
            default: return 16
            }
        default:
            return 16
        }
    }

    static func audioSettings(for target: String, sampleRate: Double, channels: AVAudioChannelCount, bitDepth: Int, isFloat: Bool, layout: AVAudioChannelLayout?) throws -> [String: Any] {
        var settings: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        if channels > 2, let layout {
            settings[AVChannelLayoutKey] = Data(bytes: layout.layout, count: MemoryLayout<AudioChannelLayout>.size)
        }
        let depth = bitDepth <= 16 ? 16 : (bitDepth <= 24 ? 24 : 32)
        switch target {
        case "wav", "aiff":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = depth
            settings[AVLinearPCMIsFloatKey] = isFloat && depth == 32 && target == "wav"
            settings[AVLinearPCMIsBigEndianKey] = target == "aiff"
            settings[AVLinearPCMIsNonInterleaved] = false
        case "flac":
            settings[AVFormatIDKey] = kAudioFormatFLAC
            settings[AVEncoderBitDepthHintKey] = min(depth, 24)
        case "caf":
            settings[AVFormatIDKey] = kAudioFormatAppleLossless
            settings[AVEncoderBitDepthHintKey] = min(depth, 24) == 24 ? 24 : 16
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
            settings[AVSampleRateKey] = min(sampleRate, 48_000)
            settings[AVEncoderBitRateKey] = channels == 1 ? 128_000 : 256_000
        default:
            throw MacFlowError.unsupported("Writing \(target.uppercased()) audio")
        }
        return settings
    }

    static func transcodeAudio(source: URL, target: FileFormat, destination: URL, progress: @escaping ProgressHandler,
                               transform: ((AVAudioPCMBuffer, AVAudioFramePosition) -> Void)? = nil) async throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch {
            throw MacFlowError.decode(source.lastPathComponent, "Core Audio cannot read this file.")
        }
        guard input.length > 0 else { throw MacFlowError.decode(source.lastPathComponent, "The audio is empty.") }
        let format = input.processingFormat
        let depth = sourceBitDepth(input)
        let isFloat = input.fileFormat.streamDescription.pointee.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let settings = try audioSettings(for: target.id, sampleRate: format.sampleRate, channels: format.channelCount,
                                         bitDepth: depth, isFloat: isFloat, layout: format.channelLayout)
        try await writeAudio(from: input, settings: settings, to: destination, progress: progress, transform: transform)
    }

    /// Streams `input` through an optional transform into a new file,
    /// resampling when the target sample rate differs.
    static func writeAudio(from input: AVAudioFile, settings: [String: Any], to destination: URL, progress: @escaping ProgressHandler,
                           range: Range<AVAudioFramePosition>? = nil,
                           transform: ((AVAudioPCMBuffer, AVAudioFramePosition) -> Void)? = nil) async throws {
        let format = input.processingFormat
        let outRate = (settings[AVSampleRateKey] as? Double) ?? format.sampleRate
        let output: AVAudioFile
        do {
            output = try AVAudioFile(forWriting: destination, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw MacFlowError.encode("audio", error.localizedDescription)
        }
        let span = range ?? 0..<input.length
        input.framePosition = span.lowerBound
        let chunk: AVAudioFrameCount = 65_536
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunk) else { throw MacFlowError("Out of memory.") }
        let converter: AVAudioConverter? = outRate != format.sampleRate ? AVAudioConverter(from: format, to: output.processingFormat) : nil
        var position = span.lowerBound
        let total = Double(span.count)
        while position < span.upperBound {
            try Task.checkCancellation()
            let frames = AVAudioFrameCount(min(Int64(chunk), span.upperBound - position))
            try input.read(into: buffer, frameCount: frames)
            if buffer.frameLength == 0 { break }
            transform?(buffer, position - span.lowerBound)
            if let converter {
                let ratio = outRate / format.sampleRate
                let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
                guard let converted = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: capacity) else { throw MacFlowError("Out of memory.") }
                var supplied = false
                var error: NSError?
                converter.convert(to: converted, error: &error) { _, status in
                    if supplied { status.pointee = .noDataNow; return nil }
                    supplied = true
                    status.pointee = .haveData
                    return buffer
                }
                if let error { throw MacFlowError.encode("audio", error.localizedDescription) }
                try output.write(from: converted)
            } else {
                try output.write(from: buffer)
            }
            position += AVAudioFramePosition(buffer.frameLength)
            progress(Double(position - span.lowerBound) / max(1, total))
        }
        if let converter {
            // Flush the resampler.
            let flush = AVAudioPCMBuffer(pcmFormat: output.processingFormat, frameCapacity: 8192)!
            var error: NSError?
            converter.convert(to: flush, error: &error) { _, status in status.pointee = .endOfStream; return nil }
            if flush.frameLength > 0 { try output.write(from: flush) }
        }
    }

    // MARK: - Video → GIF (native)

    /// Returns a note when the GIF covers only part of the video.
    static func videoToGIF(source: URL, destination: URL, progress: @escaping ProgressHandler) async throws -> String? {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw MacFlowError("This file has no video track.")
        }
        let duration = try await asset.load(.duration).seconds
        guard duration.isFinite, duration > 0 else { throw MacFlowError.decode(source.lastPathComponent, "The video has no duration.") }
        let maxFrames = 600.0
        var fps = 12.0
        if duration * fps > maxFrames { fps = max(4, maxFrames / duration) }
        let covered = min(duration, maxFrames / fps)
        let count = max(1, Int((covered * fps).rounded(.down)))

        let natural = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let displayed = natural.applying(transform)
        let width = abs(displayed.width), height = abs(displayed.height)
        let scale = min(1, 480 / max(width, 1))

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let tolerance = CMTime(seconds: 0.5 / fps, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        guard let dest = CGImageDestinationCreateWithURL(destination as CFURL, "com.compuserve.gif" as CFString, count, nil) else {
            throw MacFlowError.encode("GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1.0 / fps]] as CFDictionary
        let times = (0..<count).map { CMTime(seconds: Double($0) / fps, preferredTimescale: 600) }
        var written = 0
        for await result in generator.images(for: times) {
            try Task.checkCancellation()
            guard let image = try? result.image else { continue }
            CGImageDestinationAddImage(dest, image, frameProps)
            written += 1
            progress(Double(written) / Double(count))
        }
        guard written > 0 else { throw MacFlowError("No frames could be read from the video.") }
        guard CGImageDestinationFinalize(dest) else { throw MacFlowError.encode("GIF") }
        if covered < duration - 0.5 {
            return "GIF covers the first \(Int(covered)) s of \(Int(duration)) s."
        }
        return nil
    }

    // MARK: - Inspection

    struct MediaInfo {
        var duration: Double
        var hasVideo: Bool
        var hasAudio: Bool
        var size: CGSize
        var frameRate: Float
    }

    static func info(_ url: URL) async throws -> MediaInfo {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration).seconds
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        var size = CGSize.zero
        var fps: Float = 0
        if let v = video.first {
            let natural = try await v.load(.naturalSize)
            let transform = try await v.load(.preferredTransform)
            let s = natural.applying(transform)
            size = CGSize(width: abs(s.width), height: abs(s.height))
            fps = try await v.load(.nominalFrameRate)
        }
        return MediaInfo(duration: duration.isFinite ? duration : 0, hasVideo: !video.isEmpty, hasAudio: !audio.isEmpty, size: size, frameRate: fps)
    }
}
