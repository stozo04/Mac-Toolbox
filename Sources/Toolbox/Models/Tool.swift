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
    /// Queue of images saved in another format (Convert Images).
    case convertImages
    /// Queue of photos re-saved smaller at a chosen quality (Compress Images).
    case compressImages
    /// Queue of photos scaled by percentage, longest side or exact size, with a draggable preview (Resize Images).
    case resizeImages
    /// Queue of photos saved again without their location, camera and date details (Remove Metadata).
    case removeMetadata
    /// Queue of photos with faces found and hidden on device (Blur Faces).
    case blurFaces
    /// Queue of images with parts covered by a blur, a pixel mosaic or a black box, drawn by hand or found on device (Redact Image).
    case redactImage
    /// Queue of screenshots framed on a background with padding and a shadow (Beautify Screenshot).
    case beautifyScreenshot
    /// One screenshot with arrows, boxes, text, numbered steps, blur and crop drawn on it (Annotate Screenshot).
    case annotateScreenshot
    /// Queue of photos with the subject cut out onto a transparent or solid background (Remove Background).
    case removeBackground
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
