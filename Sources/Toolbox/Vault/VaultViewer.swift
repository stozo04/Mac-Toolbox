import AVKit
import SwiftUI

struct VaultViewer: View {
    @Environment(VaultModel.self) private var vault
    @FocusState private var focused: Bool

    private var index: Int? { vault.displayedItems.firstIndex { $0.id == vault.viewing } }
    private var item: VaultItem? { index.map { vault.displayedItems[$0] } }

    var body: some View {
        ZStack {
            Color.black.opacity(0.94).ignoresSafeArea().onTapGesture { vault.viewing = nil }
            if let item {
                VaultViewerContent(item: item).id(item.id).padding(.horizontal, 80).padding(.vertical, 56)
                VStack {
                    topBar(item)
                    Spacer()
                }
                HStack {
                    arrow("chevron.left", help: "Previous (←)", step: -1, shown: (index ?? 0) > 0)
                    Spacer()
                    arrow("chevron.right", help: "Next (→)", step: 1, shown: (index ?? 0) < vault.displayedItems.count - 1)
                }
                .padding(.horizontal, 16)
            }
        }
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { vault.step(-1); return .handled }
        .onKeyPress(.rightArrow) { vault.step(1); return .handled }
        .onKeyPress(.escape) { vault.viewing = nil; return .handled }
    }

    private func topBar(_ item: VaultItem) -> some View {
        HStack {
            Text(item.name).font(.headline).foregroundStyle(.white).lineLimit(1)
            Text("\((index ?? 0) + 1) of \(vault.displayedItems.count)").font(.callout).foregroundStyle(.white.opacity(0.6)).monospacedDigit()
            Spacer()
            Button { vault.detailing = item.id } label: {
                Image(systemName: "info").font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .keyboardShortcut("i", modifiers: .command)
            .help("Details (⌘I)")
            Button { vault.viewing = nil } label: {
                Image(systemName: "xmark").font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .frame(width: 36, height: 36).background(Circle().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")
        }
        .padding(16)
    }

    @ViewBuilder private func arrow(_ symbol: String, help: String, step: Int, shown: Bool) -> some View {
        Button { vault.step(step) } label: {
            Image(systemName: symbol).font(.title.weight(.semibold)).foregroundStyle(.white)
                .frame(width: 52, height: 52).background(Circle().fill(.white.opacity(0.12)))
        }
        .buttonStyle(.plain)
        .help(help)
        .opacity(shown ? 1 : 0)
        .disabled(!shown)
    }
}

private struct VaultViewerContent: View {
    @Environment(VaultModel.self) private var vault
    let item: VaultItem
    @State private var image: NSImage?
    @State private var player: AVPlayer?

    var body: some View {
        Group {
            switch item.kind {
            case .image:
                if let image {
                    Image(nsImage: image).resizable().scaledToFit()
                } else {
                    ProgressView().tint(.white)
                }
            case .video:
                if let player { PlayerView(player: player) } else { ProgressView().tint(.white) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            switch item.kind {
            case .image:
                let url = item.url
                image = await Task.detached { NSImage(contentsOf: url) }.value
            case .video:
                let url = await vault.playableURL(for: item)
                guard !Task.isCancelled else { return }
                let made = AVPlayer(url: url)
                player = made
                vault.player = made
                made.play()
            }
        }
        .onDisappear {
            player?.pause()
            player?.replaceCurrentItem(with: nil)
            if let player, vault.player === player { vault.player = nil }
        }
    }
}

private struct PlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .floating
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}
