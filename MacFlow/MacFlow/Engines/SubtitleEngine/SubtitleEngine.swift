import Foundation

/// Subtitle cue with exact millisecond timing.
struct SubtitleCue: Equatable {
    var start: Int  // milliseconds
    var end: Int
    var text: String
}

/// Lossless-timing subtitle parsing and writing. Times are integers in
/// milliseconds; formats with coarser precision (ASS: centiseconds, LRC)
/// are converted exactly, never rounded on output.
enum SubtitleEngine {

    // MARK: - Parsing

    static func parse(_ text: String, format: String) throws -> [SubtitleCue] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{FEFF}", with: "")
        let cues: [SubtitleCue]
        switch format {
        case "srt": cues = try parseSRTLike(normalized, vtt: false)
        case "vtt": cues = try parseSRTLike(normalized, vtt: true)
        case "sbv": cues = try parseSBV(normalized)
        case "ass": cues = try parseASS(normalized)
        case "lrc": cues = try parseLRC(normalized)
        default: throw MacFlowError.unsupported("Reading \(format.uppercased()) subtitles")
        }
        guard !cues.isEmpty else { throw MacFlowError("No subtitles were found in the file.") }
        return cues
    }

    /// Parses "HH:MM:SS,mmm", "MM:SS.mmm", "H:MM:SS.mmm".
    static func parseTime(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        let secondsPart = parts.last!.replacingOccurrences(of: ",", with: ".")
        let secComps = secondsPart.split(separator: ".", omittingEmptySubsequences: false)
        guard let secs = Int(secComps[0]), secs < 60 else { return nil }
        var millis = 0
        if secComps.count == 2 {
            let frac = String(secComps[1])
            guard !frac.isEmpty, frac.allSatisfy(\.isNumber) else { return nil }
            let padded = (frac + "000").prefix(3)
            millis = Int(padded) ?? 0
        }
        guard let minutes = Int(parts[parts.count - 2]) else { return nil }
        let hours = parts.count == 3 ? Int(parts[0]) : 0
        guard let hours, hours >= 0, minutes >= 0 else { return nil }
        if parts.count == 3 && minutes >= 60 { return nil }
        return ((hours * 60 + minutes) * 60 + secs) * 1000 + millis
    }

    private static func parseSRTLike(_ text: String, vtt: Bool) throws -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        let blocks = text.components(separatedBy: "\n\n")
        for (index, block) in blocks.enumerated() {
            var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty { lines.removeFirst() }
            guard !lines.isEmpty else { continue }
            if vtt {
                let head = lines[0].trimmingCharacters(in: .whitespaces)
                if index == 0 && head.hasPrefix("WEBVTT") { continue }
                if head.hasPrefix("NOTE") || head == "STYLE" || head == "REGION" { continue }
            }
            guard let timingIndex = lines.prefix(2).firstIndex(where: { $0.contains("-->") }) else { continue }
            let timing = lines[timingIndex].components(separatedBy: "-->")
            guard timing.count == 2 else { continue }
            let endField = timing[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first.map(String.init) ?? ""
            guard let start = parseTime(timing[0]), let end = parseTime(endField) else {
                throw MacFlowError("Invalid subtitle timing: “\(lines[timingIndex])”.")
            }
            var body = lines[(timingIndex + 1)...].joined(separator: "\n")
            while body.hasSuffix("\n") { body.removeLast() }
            if vtt { body = cleanVTTText(body) }
            cues.append(SubtitleCue(start: start, end: end, text: body))
        }
        return cues
    }

    /// Keeps <b>, <i>, <u>; removes voice/class spans and inline timestamps.
    static func cleanVTTText(_ s: String) -> String {
        var out = s.replacingOccurrences(of: "<\\d{1,2}:[\\d:.]+>", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "</?(c|v|lang|ruby|rt)(\\.[^ >]*)?( [^>]*)?>", with: "", options: .regularExpression)
        return out.replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
    }

    private static func parseSBV(_ text: String) throws -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n").map(String.init)
            guard let timing = lines.first, timing.contains(",") else { continue }
            let times = timing.split(separator: ",")
            guard times.count == 2, let start = parseTime(String(times[0])), let end = parseTime(String(times[1])) else {
                throw MacFlowError("Invalid SBV timing: “\(timing)”.")
            }
            cues.append(SubtitleCue(start: start, end: end, text: lines.dropFirst().joined(separator: "\n")))
        }
        return cues
    }

    private static func parseASS(_ text: String) throws -> [SubtitleCue] {
        var format: [String] = []
        var inEvents = false
        var cues: [SubtitleCue] = []
        for line in text.split(separator: "\n").map(String.init) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inEvents = t.lowercased() == "[events]"; continue }
            guard inEvents else { continue }
            if t.lowercased().hasPrefix("format:") {
                format = t.dropFirst(7).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                continue
            }
            guard t.lowercased().hasPrefix("dialogue:") else { continue }
            if format.isEmpty { format = ["layer", "start", "end", "style", "name", "marginl", "marginr", "marginv", "effect", "text"] }
            let body = String(t.dropFirst(9)).trimmingCharacters(in: .whitespaces)
            let fields = body.split(separator: ",", maxSplits: format.count - 1, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == format.count,
                  let si = format.firstIndex(of: "start"), let ei = format.firstIndex(of: "end"), let ti = format.firstIndex(of: "text"),
                  let start = parseTime(fields[si]), let end = parseTime(fields[ei]) else { continue }
            var content = fields[ti].replacingOccurrences(of: "\\{[^}]*\\}", with: "", options: .regularExpression)
            content = content.replacingOccurrences(of: "\\N", with: "\n").replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\h", with: "\u{00A0}")
            cues.append(SubtitleCue(start: start, end: end, text: content))
        }
        return cues.sorted { $0.start < $1.start }
    }

    private static func parseLRC(_ text: String) throws -> [SubtitleCue] {
        var stamped: [(Int, String)] = []
        let pattern = try NSRegularExpression(pattern: #"\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]"#)
        for line in text.split(separator: "\n").map(String.init) {
            let ns = line as NSString
            let matches = pattern.matches(in: line, range: NSRange(location: 0, length: ns.length))
            guard !matches.isEmpty else { continue }
            let lyric = ns.substring(from: NSMaxRange(matches.last!.range)).trimmingCharacters(in: .whitespaces)
            for m in matches {
                let minutes = Int(ns.substring(with: m.range(at: 1))) ?? 0
                let seconds = Int(ns.substring(with: m.range(at: 2))) ?? 0
                var millis = 0
                if m.range(at: 3).location != NSNotFound {
                    let frac = ns.substring(with: m.range(at: 3))
                    millis = Int((frac + "000").prefix(3)) ?? 0
                }
                stamped.append(((minutes * 60 + seconds) * 1000 + millis, lyric))
            }
        }
        stamped.sort { $0.0 < $1.0 }
        var cues: [SubtitleCue] = []
        for (i, entry) in stamped.enumerated() where !entry.1.isEmpty {
            let end = i + 1 < stamped.count ? stamped[i + 1].0 : entry.0 + 5000
            cues.append(SubtitleCue(start: entry.0, end: max(end, entry.0 + 1), text: entry.1))
        }
        return cues
    }

    // MARK: - Writing

    static func format(_ ms: Int, separator: Character, hourDigits: Int = 2) -> String {
        let total = max(0, ms)
        let h = total / 3_600_000
        let m = (total / 60_000) % 60
        let s = (total / 1000) % 60
        let f = total % 1000
        let hours = hourDigits == 1 ? String(h) : String(format: "%02d", h)
        return "\(hours):" + String(format: "%02d:%02d", m, s) + String(separator) + String(format: "%03d", f)
    }

    static func serialize(_ cues: [SubtitleCue], as target: String) throws -> String {
        switch target {
        case "srt":
            return cues.enumerated().map { i, c in
                "\(i + 1)\n\(format(c.start, separator: ",")) --> \(format(c.end, separator: ","))\n\(c.text)\n"
            }.joined(separator: "\n")
        case "vtt":
            let body = cues.map { c in
                let text = c.text.replacingOccurrences(of: "-->", with: "→")
                return "\(format(c.start, separator: ".")) --> \(format(c.end, separator: "."))\n\(text)\n"
            }.joined(separator: "\n")
            return "WEBVTT\n\n" + body
        case "sbv":
            return cues.map { c in
                "\(format(c.start, separator: ".", hourDigits: 1)),\(format(c.end, separator: ".", hourDigits: 1))\n\(stripTags(c.text))\n"
            }.joined(separator: "\n")
        case "txt":
            return cues.map { stripTags($0.text) }.joined(separator: "\n") + "\n"
        default:
            throw MacFlowError.unsupported("Writing \(target.uppercased()) subtitles")
        }
    }

    static func stripTags(_ s: String) -> String {
        s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
    }

    static func convert(source: URL, sourceFormat: FileFormat, target: FileFormat, destination: URL) throws {
        let text = try DocumentEngine.readText(source)
        let cues = try parse(text, format: sourceFormat.id)
        try DocumentEngine.write(try serialize(cues, as: target.id), to: destination)
    }

    /// Shift every cue by `offset` ms (tool). Rejects shifts that would move
    /// a cue before 00:00:00.
    static func shift(_ cues: [SubtitleCue], by offset: Int) throws -> [SubtitleCue] {
        if let first = cues.map(\.start).min(), first + offset < 0 {
            throw MacFlowError("The shift would move subtitles before the start of the video.")
        }
        return cues.map { SubtitleCue(start: $0.start + offset, end: $0.end + offset, text: $0.text) }
    }
}
