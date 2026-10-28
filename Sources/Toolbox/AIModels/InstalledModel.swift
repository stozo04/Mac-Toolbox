import Foundation

/// What a model is for, in plain words.
enum ModelKind: String, CaseIterable {
    case language = "Language", embedding = "Search", speech = "Speech", vision = "Vision"
    case imageGeneration = "Image creation", audio = "Audio", other = "Other"

    var symbol: String {
        switch self {
        case .language: "text.bubble"
        case .embedding: "sparkles"
        case .speech: "waveform"
        case .vision: "camera.viewfinder"
        case .imageGeneration: "photo.artframe"
        case .audio: "music.note"
        case .other: "cpu"
        }
    }
}

/// Whether a model can be gathered into the central folder.
enum Movability: Equatable {
    /// Safe to move; a link stays where the app looks for it.
    case movable
    /// Already in the central folder.
    case central
    /// Leave it: the reason says which app would lose track of it.
    case managed(String)
}

/// An app (or program) that uses a model.
struct AssociatedApp: Hashable {
    var name: String
    /// The app itself, when it is installed here; gives its icon.
    var bundleURL: URL?
    /// Has the model open at this moment.
    var inUse = false
    /// Why there is no app to show ("built into macOS").
    var note: String?

    /// Part of macOS itself, so it gets the Apple logo instead of an app icon.
    var isMacOS: Bool { bundleURL == nil && note == AssociatedApp.builtIntoMacOS }
    static let builtIntoMacOS = "built into macOS"
}

/// One AI model (or a set of files that work as one) on this Mac.
struct InstalledModel: Identifiable, Equatable {
    /// The real location of the model, links resolved.
    var id: String { url.path }
    var name: String
    var summary: String
    /// The app that uses it, if known ("DigUp", "superwhisper"...). Nil for a loose file.
    var owner: String?
    var kind: ModelKind
    /// "GGUF", "Core ML", "ONNX"...
    var format: String
    var tags: [String] = []
    /// The apps that use it: the app whose folder it sits in, an app that carries it inside, or one that has it open right now.
    var apps: [AssociatedApp] = []
    /// Which version of the model this is, and where that number comes from; nil when nothing says.
    var version: ModelVersion?
    var bytes: Int64
    /// The file or folder itself.
    var url: URL
    /// The folder to open to see it.
    var location: URL
    /// Places an app looks for it that now point at `url`.
    var linkedFrom: [URL] = []
    var movability: Movability
    /// Parts, for a model made of several files.
    var parts = 1
}
