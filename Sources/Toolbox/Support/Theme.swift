import SwiftUI

enum Theme {
    static let background = adaptive(light: 0.94, dark: 0.13)
    static let card = adaptive(light: 1.0, dark: 0.17)
    static let inset = adaptive(light: 0.92, dark: 0.10)
    /// Base for translucent overlays: white on dark, black on light.
    static let tint = adaptive(light: 0.0, dark: 1.0)
    static let stroke = tint.opacity(0.08)
    static let accent = Color.accentColor
    static let corner: CGFloat = 20

    private static func adaptive(light: CGFloat, dark: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(white: isDark ? dark : light, alpha: 1)
        })
    }
}

extension View {
    func cardBackground(corner: CGFloat = Theme.corner) -> some View {
        background(Theme.card, in: RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: corner, style: .continuous).strokeBorder(Theme.stroke))
    }
}
