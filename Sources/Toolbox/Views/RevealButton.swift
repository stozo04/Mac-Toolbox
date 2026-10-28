import SwiftUI

/// The small icon button that shows a file or folder in Finder. An eye, because it is for looking at where something
/// is kept; a magnifying glass reads as "search", which is not what it does. Use this everywhere, so they all match.
struct RevealButton: View {
    static let symbol = "eye"

    var help = "Show in Finder"
    let action: () -> Void

    init(help: String = "Show in Finder", action: @escaping () -> Void) {
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) { Image(systemName: Self.symbol) }
            .buttonStyle(.borderless)
            .help(help)
            .accessibilityLabel(help)
    }
}
