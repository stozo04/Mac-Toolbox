import Foundation

/// The last colors you picked or typed, newest first, kept between launches.
struct ColorHistory: Equatable {
    static let limit = 20

    private(set) var colors: [RGBAColor] = []

    init(colors: [RGBAColor] = []) {
        for color in colors.reversed() { add(color) }
    }

    /// Puts `color` first. A color already in the list moves up instead of appearing twice.
    mutating func add(_ color: RGBAColor) {
        let color = color.quantized
        colors.removeAll { $0 == color }
        colors.insert(color, at: 0)
        if colors.count > Self.limit { colors.removeLast(colors.count - Self.limit) }
    }

    mutating func clear() { colors = [] }

    // MARK: Saving

    private static let key = "colorPicker.history"

    /// Stored as `#RRGGBBAA` text so the file is readable and survives changes to this type.
    static func load(from defaults: UserDefaults = .standard) -> ColorHistory {
        let saved = defaults.stringArray(forKey: key) ?? []
        // Saved newest first, so adding them oldest first rebuilds the same order.
        var history = ColorHistory()
        for text in saved.reversed() {
            if let color = RGBAColor.parse(text) { history.add(color) }
        }
        return history
    }

    func save(to defaults: UserDefaults = .standard) {
        defaults.set(colors.map { ColorFormat.hex.string(for: $0, includeAlpha: true) }, forKey: Self.key)
    }
}
