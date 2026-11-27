import Foundation

/// Optional FFmpeg integration. Only used when an FFmpeg executable was
/// found (bundled or installed) and only with encoders it reported.
enum FFmpegEngine {

    private static func require() throws -> String {
        guard let tool = EngineCapabilities.shared.ffmpeg else {
            throw MacFlowError("This conversion needs FFmpeg, which is not available on this Mac.")
        }
        return tool.path
    }

    private static func has(_ encoder: String) -> Bool { EngineCapabilities.shared.ffmpegHasEncoder(encoder) }

    /// Runs FFmpeg, mapping its progress output to 0…1.
    static func run(_ arguments: [String], progress: ProgressHandler?) async throws {
        let path = try require()
        let tracker = DurationTracker()
        let base = ["-nostdin", "-hide_banner", "-y"]
        let result = try await ProcessRunner.run(path, base + arguments, timeout: 6 * 3600) { line in
            tracker.consume(line, progress: progress)
        }
        guard result.status == 0 else {
            throw MacFlowError("FFmpeg could not convert the file.", detail: result.errorSummary)
        }
        progress?(1)
    }

    static func videoCodecArguments() -> [String] {
        if has("libx264") { return ["-c:v", "libx264", "-preset", "medium", "-crf", "20", "-pix_fmt", "yuv420p"] }
        if has("h264_videotoolbox") { return ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p"] }
        return []
    }

    static func aacArguments() -> [String] {
        if has("aac_at") { return ["-c:a", "aac_at", "-b:a", "192k"] }
        return ["-c:a", "aac", "-b:a", "192k"]
    }

    static func convertVideo(source: URL, target: FileFormat, destination: URL, progress: @escaping ProgressHandler) async throws {
        var args = ["-i", source.path]
        switch target.id {
        case "mp4", "mov", "m4v":
            let video = videoCodecArguments()
            guard !video.isEmpty else { throw MacFlowError("No H.264 encoder is available in FFmpeg.") }
            args += ["-map", "0:v:0", "-map", "0:a?", "-sn", "-dn"] + video + aacArguments()
            if target.id != "mov" { args += ["-movflags", "+faststart"] }
            args += ["-map_metadata", "0", "-f", target.id == "m4v" ? "ipod" : target.id, destination.path]
        case "mkv":
            // Remux first: lossless and fast whenever the streams allow it.
            do {
                try await run(["-i", source.path, "-map", "0", "-c", "copy", "-map_metadata", "0", "-f", "matroska", destination.path], progress: progress)
                return
            } catch let error where !error.isCancellation {
                try? FileManager.default.removeItem(at: destination)
            }
            args += ["-map", "0:v:0", "-map", "0:a?", "-map", "0:s?"] + videoCodecArguments() + aacArguments() + ["-c:s", "copy", "-map_metadata", "0", "-f", "matroska", destination.path]
        case "webm":
            guard has("libvpx-vp9") else { throw MacFlowError("FFmpeg has no VP9 encoder.") }
            let opus = has("libopus") ? "libopus" : "opus"
            args += ["-map", "0:v:0", "-map", "0:a?", "-sn", "-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1",
                     "-c:a", opus, "-b:a", "128k", "-strict", "-2", "-f", "webm", destination.path]
        default:
            throw MacFlowError.unsupported("Writing \(target.label) with FFmpeg")
        }
        try await run(args, progress: progress)
    }

    static func convertAudio(source: URL, target: FileFormat, destination: URL, progress: @escaping ProgressHandler) async throws {
        var args = ["-i", source.path, "-map", "0:a:0", "-vn", "-sn", "-map_metadata", "0"]
        switch target.id {
        case "mp3":
            guard has("libmp3lame") else { throw MacFlowError("FFmpeg has no MP3 encoder.") }
            args += ["-c:a", "libmp3lame", "-q:a", "2", "-id3v2_version", "3", "-f", "mp3"]
        case "m4a": args += aacArguments() + ["-f", "ipod"]
        case "wav": args += ["-c:a", "pcm_s24le", "-f", "wav"]
        case "aiff": args += ["-c:a", "pcm_s24be", "-f", "aiff"]
        case "flac": args += ["-c:a", "flac", "-f", "flac"]
        case "caf": args += ["-c:a", "alac", "-f", "caf"]
        case "opus":
            guard has("libopus") else { throw MacFlowError("FFmpeg has no Opus encoder.") }
            args += ["-c:a", "libopus", "-b:a", "160k", "-f", "opus"]
        case "ogg":
            guard has("libvorbis") else { throw MacFlowError("FFmpeg has no Vorbis encoder.") }
            args += ["-c:a", "libvorbis", "-q:a", "6", "-f", "ogg"]
        default:
            throw MacFlowError.unsupported("Writing \(target.label) with FFmpeg")
        }
        args.append(destination.path)
        try await run(args, progress: progress)
    }

    static func videoToGIF(source: URL, destination: URL, progress: @escaping ProgressHandler) async throws {
        let filter = "fps=12,scale='min(480,iw)':-2:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=sierra2_4a"
        try await run(["-t", "50", "-i", source.path, "-filter_complex", filter, "-loop", "0", "-f", "gif", destination.path], progress: progress)
    }
}

/// Parses FFmpeg's "Duration:" and "time=" output into a fraction.
private final class DurationTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var duration: Double = 0

    func consume(_ line: String, progress: ProgressHandler?) {
        if let range = line.range(of: "Duration: ") {
            let value = line[range.upperBound...].prefix(11)
            if let seconds = Self.seconds(String(value)), seconds > 0 {
                lock.lock(); if duration == 0 { duration = seconds }; lock.unlock()
            }
        }
        if let range = line.range(of: "time=") {
            let value = line[range.upperBound...].prefix(11)
            lock.lock(); let total = duration; lock.unlock()
            if let seconds = Self.seconds(String(value)), total > 0 {
                progress?(min(0.99, seconds / total))
            }
        }
    }

    static func seconds(_ s: String) -> Double? {
        let parts = s.split(separator: ":")
        guard parts.count == 3, let h = Double(parts[0]), let m = Double(parts[1]), let sec = Double(parts[2]) else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
