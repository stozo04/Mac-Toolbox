import Foundation

/// Placeholder model entry. No download or inference exists yet.
struct AIModel: Identifiable, Hashable {
    let name: String
    let publisher: String
    let symbol: String
    let summary: String
    let size: String
    let tags: [String]

    var id: String { name }

    static let samples: [AIModel] = [
        AIModel(name: "Gemma 3", publisher: "Google", symbol: "sparkles",
                summary: "Small, fast language model for summarizing, translating and answering questions about your documents.",
                size: "2.5 GB", tags: ["Text", "On device", "4B"]),
        AIModel(name: "Whisper Large v3 Turbo", publisher: "OpenAI", symbol: "waveform",
                summary: "Speech recognition for turning audio and video into accurate, timestamped transcripts.",
                size: "1.6 GB", tags: ["Speech", "On device", "Multilingual"]),
    ]
}
