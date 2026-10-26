import Foundation

/// What the main workspace of a tool looks like before any work has started.
enum ToolInput: Hashable {
    /// Drag-and-drop / file chooser. `title` is e.g. "Drop a Video Here".
    case dropFiles(title: String, hint: String, symbol: String)
    /// Paste one or more links (Download Video).
    case link
    /// No input file; the tool acts live (Keep Awake, Battery Health...).
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
