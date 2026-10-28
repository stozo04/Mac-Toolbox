import Foundation

/// What the main workspace of a tool looks like before any work has started.
enum ToolInput: Hashable {
    /// Drag-and-drop / file chooser. `title` is e.g. "Drop a Video Here".
    case dropFiles(title: String, hint: String, symbol: String)
    /// Paste one or more links (Download Video).
    case link
    /// Display, window or area picker with a record button (Record Screen).
    case recordScreen
    /// Video preview with a timeline and in/out handles (Trim Video).
    case trimVideo
    /// Queue of videos with frame rate and width options (Video to GIF).
    case videoToGif
    /// Queue of videos with size, fit and format options (Resize Video).
    case resizeVideo
    /// Queue of videos that get captions drawn in (Burn In Subtitles).
    case burnInSubtitles
    /// Queue of videos whose soundtrack is removed (Mute Video).
    case muteVideo
    /// List of files with codec, track and metadata details (Media Info).
    case mediaInfo
    /// One of the Mac category's native tools (Keep Awake, Hidden Settings...).
    case mac(MacTool)
    /// No input file; the tool acts live (Keep Awake...).
    case live(symbol: String, idle: String, action: String)
    /// Free text in, result out (Base64, JSON Formatter...).
    case text
}

struct Tool: Identifiable, Hashable {
    let name: String
    let category: ToolCategory
    let symbol: String
    let tagline: String
    let input: ToolInput

    var id: String { "\(category.rawValue)/\(name)" }
}
