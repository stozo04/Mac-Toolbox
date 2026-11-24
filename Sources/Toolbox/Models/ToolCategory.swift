import Foundation

enum ToolCategory: String, CaseIterable, Identifiable, Hashable {
    case video = "Video"
    case audio = "Audio"
    case images = "Images"
    case docs = "Docs"
    case mac = "Mac"

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        case .images: "photo"
        case .docs: "doc.text"
        case .mac: "desktopcomputer"
        }
    }

    var summary: String {
        switch self {
        case .video: "Record, trim, convert and shrink video"
        case .audio: "Record, clean up and convert audio"
        case .images: "Edit, convert and protect photos"
        case .docs: "Read, sign and edit PDFs in Folio"
        case .mac: "Free up space and fix what's stuck"
        }
    }
}
