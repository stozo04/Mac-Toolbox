import Foundation

/// One caption: the text and when it shows, in seconds.
struct SubtitleCue: Equatable {
    var start: Double
    var end: Double
    var text: String
}

enum SubtitleError: LocalizedError {
    case unreadable
    case noCues

    var errorDescription: String? {
        switch self {
        case .unreadable: "The subtitle file could not be read."
        case .noCues: "No captions were found in the subtitle file. Use an SRT or WebVTT file."
        }
    }
}

/// Reads SRT and WebVTT files and writes SRT.
enum SubtitleFile {
    static let extensions = ["srt", "vtt"]

    /// A subtitle file with the video's name next to it, e.g. `Trip.srt` for `Trip.mp4`.
    static func sidecar(for video: URL) -> URL? {
        let folder = video.deletingLastPathComponent()
        let name = video.deletingPathExtension().lastPathComponent.lowercased()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for ext in extensions {
            if let match = names.sorted().first(where: { $0.lowercased() == "\(name).\(ext)" }) {
                return folder.appendingPathComponent(match)
            }
        }
        return nil
    }

    static func load(_ url: URL) throws -> [SubtitleCue] {
        guard let data = try? Data(contentsOf: url) else { throw SubtitleError.unreadable }
        var converted: NSString?
        let encoding = NSString.stringEncoding(for: data, encodingOptions: [.suggestedEncodingsKey: [String.Encoding.utf8.rawValue]],
                                               convertedString: &converted, usedLossyConversion: nil)
        guard encoding != 0, let text = converted as String? else { throw SubtitleError.unreadable }
        let cues = parse(text)
        guard !cues.isEmpty else { throw SubtitleError.noCues }
        return cues
    }

    /// Parses SRT or WebVTT text; the two share the "start --> end" line, so one reader covers both.
    static func parse(_ raw: String) -> [SubtitleCue] {
        let text = raw.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var cues: [SubtitleCue] = []
        for block in text.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            guard let at = lines.firstIndex(where: { $0.contains("-->") }) else { continue }  // header, NOTE, STYLE, stray numbers
            let parts = lines[at].components(separatedBy: "-->")
            guard parts.count == 2, let start = time(parts[0]),
                  let end = time(String(parts[1].split(separator: " ", omittingEmptySubsequences: true).first ?? "")) else { continue }
            let body = lines[(at + 1)...].map(clean).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty, end > start { cues.append(SubtitleCue(start: start, end: end, text: body)) }
        }
        return cues.sorted { $0.start < $1.start }
    }

    /// "01:02:03,500", "02:03.500" or "3.5" to seconds.
    static func time(_ string: String) -> Double? {
        let parts = string.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":").map(String.init)
        guard (1...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let n = Double(part), n >= 0 else { return nil }
            seconds = seconds * 60 + n
        }
        return seconds
    }

    /// Drops markup a plain caption can't show: <i>, <c.yellow>, <00:01.000>, {\an8}; decodes common entities.
    static func clean(_ line: String) -> String {
        var s = line
        for pattern in ["<[^>]*>", "\\{\\\\[^}]*\\}"] {
            s = s.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        for (entity, char) in [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"), ("&amp;", "&")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func srt(_ cues: [SubtitleCue]) -> String {
        cues.enumerated().map { i, cue in
            "\(i + 1)\n\(stamp(cue.start)) --> \(stamp(cue.end))\n\(cue.text)\n"
        }.joined(separator: "\n")
    }

    private static func stamp(_ t: Double) -> String {
        let ms = Int((max(t, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, ms % 1000)
    }
}

/// One recognized word with its place in the audio.
struct TimedWord: Equatable {
    var text: String
    var start: Double
    var duration: Double
    var end: Double { start + duration }
}

/// Groups recognized words into readable captions.
enum CueBuilder {
    static let maxCharacters = 42
    static let maxSeconds = 6.0
    static let pause = 0.8

    static func cues(from words: [TimedWord]) -> [SubtitleCue] {
        var cues: [SubtitleCue] = []
        var current: [TimedWord] = []

        func flush() {
            guard let first = current.first, let last = current.last else { return }
            cues.append(SubtitleCue(start: first.start, end: last.end, text: current.map(\.text).joined(separator: " ")))
            current = []
        }

        for word in words where !word.text.trimmingCharacters(in: .whitespaces).isEmpty {
            if let last = current.last {
                let length = current.map(\.text).joined(separator: " ").count + 1 + word.text.count
                let breaks = word.start - last.end > pause || length > maxCharacters || word.end - current[0].start > maxSeconds
                if breaks { flush() }
            }
            current.append(word)
            if let end = word.text.last, ".?!…。？！".contains(end) { flush() }
        }
        flush()
        return cues
    }
}
