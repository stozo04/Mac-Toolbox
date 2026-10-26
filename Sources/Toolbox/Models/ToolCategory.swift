import Foundation

enum ToolCategory: String, CaseIterable, Identifiable, Hashable {
    case video = "Video"
    case audio = "Audio"
    case images = "Images"
    case docs = "Docs"
    case textAndSpeech = "Text & Speech"
    case files = "Files"
    case mac = "Mac"
    case developer = "Developer"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .images: "photo"
        case .docs: "doc.text"
        case .textAndSpeech: "text.bubble"
        case .files: "folder"
        case .mac: "desktopcomputer"
        case .developer: "chevron.left.forwardslash.chevron.right"
        }
    }

    var summary: String {
        switch self {
        case .video: "Record, trim, convert and shrink video"
        case .audio: "Record, clean up and convert audio"
        case .images: "Edit, convert and protect photos"
        case .docs: "Scan, sign, convert and protect docs"
        case .textAndSpeech: "Transcribe, translate and summarize, privately"
        case .files: "Rename in bulk and make QR codes"
        case .mac: "Free up space and fix what's stuck"
        case .developer: "Format, decode, hash and compare. Offline and instant."
        }
    }
}
