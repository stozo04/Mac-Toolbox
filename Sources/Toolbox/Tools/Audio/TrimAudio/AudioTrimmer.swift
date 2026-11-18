import Foundation

enum TrimAudioError: LocalizedError, Equatable {
    case noEncoder
    case notAudio
    case encoderFailed(String)

    var errorDescription: String? {
        switch self {
        case .noEncoder: "The audio encoder is missing from this copy of Toolbox."
        case .notAudio: "This file has no sound that can be read."
        case .encoderFailed(let detail): detail.isEmpty ? "The audio could not be saved." : "The audio could not be saved: \(detail)"
        }
    }
}

struct TrimAudioJob: Equatable, Sendable {
    let source: URL
    let start: Double
    let end: Double
    let sample: SourceSampleFormat
    let settings: TrimAudioSettings

    var length: Double { max(end - start, 0) }
    var plan: TrimAudioPlan { TrimAudioPlan(sourceExtension: source.pathExtension, sample: sample, settings: settings) }
}

struct TrimAudioResult: Equatable, Sendable {
    let url: URL
    let copiedAsIs: Bool
}

enum AudioTrimmer {
    static let outputSuffix = " (Trimmed)"
    private static let quiet = ["-nostdin", "-hide_banner", "-v", "error"]
    private static let firstSoundtrackOnly = ["-map", "0:a:0", "-map_metadata", "0", "-vn", "-sn", "-dn"]
    private static let progressOutput = ["-progress", "pipe:1", "-nostats", "-y"]

    static func outputURL(for job: TrimAudioJob, in folder: URL) -> URL {
        let name = job.source.deletingPathExtension().lastPathComponent + outputSuffix
        return BatchFiles.uniqueURL(in: folder, name: name, ext: job.plan.fileExtension)
    }

    static func arguments(for job: TrimAudioJob, output: URL) -> [String] {
        quiet
            + ["-ss", seconds(job.start), "-i", job.source.path, "-t", seconds(job.length)]
            + firstSoundtrackOnly
            + fadeFilter(job.settings.fades, length: job.length)
            + job.plan.codecArguments
            + progressOutput
            + [output.path]
    }

    static func fadeFilter(_ fades: TrimFades, length: Double) -> [String] {
        let (fadeIn, fadeOut) = fades.seconds(within: length)
        var filters: [String] = []
        if fadeIn > 0 { filters.append("afade=t=in:st=0:d=\(seconds(fadeIn))") }
        if fadeOut > 0 { filters.append("afade=t=out:st=\(seconds(length - fadeOut)):d=\(seconds(fadeOut))") }
        return filters.isEmpty ? [] : ["-af", filters.joined(separator: ",")]
    }

    static func trim(_ job: TrimAudioJob, into folder: URL, ffmpeg: URL? = MediaTools.ffmpeg(),
                     progress: @escaping @Sendable (Double) -> Void) async throws -> TrimAudioResult {
        guard let ffmpeg else { throw TrimAudioError.noEncoder }
        let output = outputURL(for: job, in: folder)
        let parser = FFmpegProgress(total: job.length, report: progress)
        let result: Shell.Result
        do {
            result = try await Shell.run(ffmpeg.path, arguments(for: job, output: output), timeout: .untilCancelled) { parser.feed($0) }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        if Task.isCancelled {
            try? FileManager.default.removeItem(at: output)
            throw CancellationError()
        }
        guard result.succeeded else {
            try? FileManager.default.removeItem(at: output)
            let detail = result.err.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            throw TrimAudioError.encoderFailed(detail)
        }
        progress(1)
        return TrimAudioResult(url: output, copiedAsIs: job.plan.copiesAsIs)
    }

    private static func seconds(_ value: Double) -> String { String(format: "%.3f", max(value, 0)) }
}
