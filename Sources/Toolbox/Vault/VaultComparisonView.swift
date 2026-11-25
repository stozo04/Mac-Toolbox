import AVFoundation
import SwiftUI

/// Every copy of one photo or video side by side, with what each one is, so the person ticks the ones to keep.
struct VaultComparisonView: View {
    @Bindable var comparison: VaultComparison
    @FocusState private var focused: Bool

    /// More copies than this sit in the same row and scroll sideways, so their lines stay level for comparing.
    private static let panesInView = 3
    private static let paneSpacing: CGFloat = 14
    private static let mediaHeight: CGFloat = 210

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let group = comparison.group {
                header(group)
                ScrollViewReader { scroller in
                    ScrollView([.horizontal, .vertical]) {
                        HStack(alignment: .top, spacing: Self.paneSpacing) {
                            ForEach(Array(group.copies.enumerated()), id: \.element.id) { index, copy in
                                pane(copy, at: index, in: group)
                                    .containerRelativeFrame(.horizontal, count: min(group.copies.count, Self.panesInView),
                                                            spacing: Self.paneSpacing)
                                    .id(index)
                            }
                        }
                        .padding(.bottom, 16)
                    }
                    .scrollIndicators(.visible)
                    .onChange(of: comparison.focus) { withAnimation { scroller.scrollTo(comparison.focus) } }
                }
                if group.kind == .video { VaultPlaybackBar(playback: comparison.playback, selected: comparison.focus) }
                footer(group)
            }
        }
        .padding(20)
        .frame(minWidth: 760, idealWidth: 1040, minHeight: 600, idealHeight: 760)
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onAppear { focused = true }
        .onKeyPress(.leftArrow) { comparison.moveFocus(by: -1); return .handled }
        .onKeyPress(.rightArrow) { comparison.moveFocus(by: 1); return .handled }
        .onKeyPress(.space) { comparison.playback.togglePlay(only: comparison.focus); return .handled }
        .onKeyPress(.return) {
            if NSEvent.modifierFlags.contains(.command) { comparison.confirm() } else { comparison.toggleFocused() }
            return .handled
        }
    }

    private func header(_ group: VaultComparison.Group) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("These files look like the same \(group.kind == .video ? "video" : "photo")").font(.title2.weight(.semibold))
            badge(group.match == .exact ? "Exact match" : "Likely match",
                  color: group.match == .exact ? Theme.accent : .orange)
                .help(group.match == .exact ? "Byte for byte the same file" : "Same post ID or the same frames, but not the same bytes")
            Spacer()
            if comparison.counter.total > 1 {
                Text("Set \(comparison.counter.current) of \(comparison.counter.total)").foregroundStyle(.secondary).monospacedDigit()
            }
        }
    }

    private func pane(_ copy: VaultComparison.Copy, at index: Int, in group: VaultComparison.Group) -> some View {
        let comparisonResult = comparison.comparison
        let isBest = comparisonResult?.best == index
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { comparison.ticked.contains(copy.id) }, set: { _ in comparison.toggle(copy.id) })) {
                    Text("Keep").fontWeight(.semibold)
                }
                .toggleStyle(.checkbox)
                .focusable(false)
                Text(placeLabel(copy, in: group)).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                if isBest { badge("Higher quality", color: .green) }
                if group.kind == .video {
                    Button { comparison.playback.soundFrom = index } label: {
                        Image(systemName: comparison.playback.soundFrom == index ? "speaker.wave.2.fill" : "speaker.slash")
                    }
                    .buttonStyle(.borderless)
                    .focusable(false)
                    .help(copy.isIncoming ? "Play the sound of this copy when all play together. It plays as it is: a sound this Mac can't decode stays silent."
                          : "Play the sound of this copy when all play together")
                }
            }
            media(copy, at: index, in: group)
                .frame(height: Self.mediaHeight)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            readout(at: index, comparisonResult)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.card))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(comparison.focus == index ? Theme.accent : Color.clear, lineWidth: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture { comparison.focus = index }
    }

    @ViewBuilder
    private func media(_ copy: VaultComparison.Copy, at index: Int, in group: VaultComparison.Group) -> some View {
        if group.kind == .video {
            if let player = comparison.playback.players.dropFirst(index).first {
                VaultPlayerSurface(player: player)
            } else {
                ProgressView()
            }
        } else {
            VaultZoomGroup.Pane(url: copy.item.url, zoom: comparison.zoom)
        }
    }

    @ViewBuilder
    private func readout(at index: Int, _ result: VaultQualityComparison?) -> some View {
        if let result {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
                ForEach(result.rows) { row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        HStack(spacing: 4) {
                            Text(row.values.dropFirst(index).first.flatMap { $0 } ?? "—")
                                .fontWeight(row.differs ? .semibold : .regular)
                                .lineLimit(1).truncationMode(.middle)
                            if row.better.contains(index) {
                                Image(systemName: "arrow.up.circle.fill").foregroundStyle(.green).help("Better on this line")
                            }
                        }
                        .help(row.values.dropFirst(index).first.flatMap { $0 } ?? "")
                    }
                    .font(.callout)
                }
            }
        } else {
            ProgressView().controlSize(.small)
        }
    }

    private func footer(_ group: VaultComparison.Group) -> some View {
        HStack(spacing: 12) {
            if group.match == .exact && comparison.counter.total > comparison.counter.current {
                Toggle("Do the same for the remaining Exact matches", isOn: $comparison.repeatsExactChoice)
                    .toggleStyle(.checkbox)
                    .disabled(comparison.whyNoRepeat != nil)
                    .help(comparison.whyNoRepeat ?? "The same choice is made for every later set of exact copies in this review")
            }
            Text(qualityNote).font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button("Keep All") { comparison.keepAll() }
            Button("Cancel", role: .cancel) { comparison.cancel() }.keyboardShortcut(.cancelAction)
            Button("Keep \(comparison.ticked.count) of \(group.copies.count)") { comparison.confirm() }
                .keyboardShortcut(.return, modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!comparison.canConfirm)
                .help(comparison.canConfirm ? "Unticked copies already in the vault go to its Trash; unticked new files stay where they are"
                      : "Tick at least one copy to keep")
        }
    }

    private var qualityNote: String {
        guard let result = comparison.comparison else { return "Reading the files…" }
        return result.best == nil ? "Same quality" : ""
    }

    private func placeLabel(_ copy: VaultComparison.Copy, in group: VaultComparison.Group) -> String {
        switch copy.place {
        case .incoming: return "Adding now"
        case .downloaded: return "Added by Download Video"
        case .vault:
            guard comparison.origin == .vault else { return "Already in the Vault" }
            let added = "Added \(copy.item.added.formatted(date: .abbreviated, time: .omitted))"
            return group.copies.first?.id == copy.id ? "\(added) · Oldest" : added
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.2)))
    }
}

/// Play the selected copy, play all together, and the one scrubber every player follows.
private struct VaultPlaybackBar: View {
    let playback: VaultSyncedPlayback
    let selected: Int
    @State private var scrubbing: Double?

    var body: some View {
        HStack(spacing: 10) {
            Button { playback.togglePlay(only: selected) } label: {
                Image(systemName: playback.isPlaying && playback.solo != nil ? "pause.fill" : "play.fill").frame(width: 18)
            }
            .focusable(false)
            .help("Play or pause the selected copy (Space)")
            Button(playback.isPlaying && playback.solo == nil ? "Pause All" : "Play All") { playback.togglePlayAll() }
                .focusable(false)
                .help("Play every copy together, with the sound of the one whose speaker is on")
            Slider(value: Binding(get: { scrubbing ?? playback.position }, set: { scrubbing = $0 }),
                   in: 0...max(playback.length, 0.1)) { editing in
                guard !editing, let target = scrubbing else { return }
                Task {
                    await playback.seek(to: target)
                    scrubbing = nil
                }
            }
            Text("\(VaultTime.label(scrubbing ?? playback.position)) / \(VaultTime.label(playback.length))")
                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

/// A player's picture with no controls of its own: the comparison screen drives them all together.
private struct VaultPlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let layer = AVPlayerLayer(player: player)
        layer.videoGravity = .resizeAspect
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer = layer
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        (view.layer as? AVPlayerLayer)?.player = player
    }
}
