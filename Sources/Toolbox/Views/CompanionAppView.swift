import SwiftUI

/// The page of a companion app's card. Clicking the card opens an installed app directly, so this page mostly appears when
/// the app is missing: it says what the app does and where to download it.
struct CompanionAppView: View {
    @Environment(AppState.self) private var state
    let app: CompanionApp
    @State private var installedURL: URL?

    var body: some View {
        VStack(spacing: 14) {
            CompanionAppIcon(app: app, size: 96)
            Text(app.name).font(.title.bold())
            Text(app.pitch).font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 460)
            if installedURL != nil {
                Button("Open \(app.name)") { state.companionApps.open(app) }
                    .buttonStyle(.borderedProminent).controlSize(.large)
            } else {
                Text("\(app.name) is not installed on this Mac.").font(.callout)
                HStack {
                    Button("Get \(app.name)") { NSWorkspace.shared.open(app.downloadPage) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                    Button("Check Again") { refresh() }.controlSize(.large)
                }
                Text("Opens its download page on GitHub in your browser.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
        .onAppear(perform: refresh)
    }

    private func refresh() { installedURL = state.companionApps.installedURL(of: app) }
}

/// The app's own icon when it is installed, otherwise a generic app symbol.
struct CompanionAppIcon: View {
    @Environment(AppState.self) private var state
    let app: CompanionApp
    let size: CGFloat

    var body: some View {
        if let url = state.companionApps.installedURL(of: app) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false)))
                .resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "app.dashed").font(.system(size: size * 0.6)).foregroundStyle(.secondary)
                .frame(width: size, height: size)
        }
    }
}
