import AVKit
import SwiftUI

struct TrimVideoView: View {
    @State private var model = TrimVideoModel.shared

    var body: some View {
        if model.hasClip && !model.isLoading {
            editor
        } else {
            VStack(spacing: 10) {
                DropZone(title: "a Video", hint: "Drop a video to choose the part you want to keep.", symbol: "film",
                         allowsMultiple: false) { urls in
                    if let url = urls.first { model.load(url) }
                }
                .overlay { if model.isLoading { ProgressView().controlSize(.large) } }
                if let error = model.loadError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.yellow)
                }
            }
        }
    }

    // MARK: Editor

    private var editor: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                previewCard
                timelineCard
            }
            options.frame(width: 240)
        }
    }

    private var previewCard: some View {
        VStack(spacing: 10) {
            PlayerSurface(player: model.player)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(spacing: 12) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Play or pause (Space)")
                Text("\(TrimTime.format(model.playhead)) / \(TrimTime.format(model.selection.duration))")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Text(model.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Button("Play Selection") { model.playSelection() }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground(corner: 24)
    }

    private var timelineCard: some View {
        VStack(spacing: 8) {
            Timeline(model: model).frame(height: 70)
            HStack {
                timeChip("Start", model.selection.start)
                Spacer()
                timeChip("Length", model.selection.length)
                Spacer()
                timeChip("End", model.selection.end)
            }
        }
        .padding(14)
        .cardBackground(corner: 24)
    }

    private func timeChip(_ title: String, _ value: Double) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(TrimTime.format(value)).font(.system(.callout, design: .monospaced))
        }
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Trim").font(.headline)
            Text("Drag the handles, or type a time.").font(.caption).foregroundStyle(.secondary)
            timeField("Start", value: model.selection.start, set: { model.setStart($0) }, playheadAction: model.setStartToPlayhead,
                      playheadTitle: "Set Start to Playhead")
            timeField("End", value: model.selection.end, set: { model.setEnd($0) }, playheadAction: model.setEndToPlayhead,
                      playheadTitle: "Set End to Playhead")
            Text("Keeps \(TrimTime.format(model.selection.length)) of \(TrimTime.format(model.selection.duration)).")
                .font(.caption).foregroundStyle(.secondary)
            Text("The video is copied without re-encoding whenever the format allows, so quality is unchanged. The original file is never changed.")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            result
            HStack {
                Button("Choose Another") { model.close() }.disabled(model.isSaving)
                Spacer()
                if model.isSaving {
                    Button("Cancel", role: .cancel) { model.cancelTrim() }
                } else {
                    Button("Trim") { model.trim() }
                        .buttonStyle(.borderedProminent).disabled(model.selection.isWholeClip)
                        .help(model.selection.isWholeClip ? "Move a handle to choose what to cut" : "Save the selection as a new file")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private func timeField(_ title: String, value: Double, set: @escaping (Double) -> Void,
                           playheadAction: @escaping () -> Void, playheadTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 8) {
                TimeField(value: value, set: set)
                Button(playheadTitle, action: playheadAction).controlSize(.small)
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder private var result: some View {
        switch model.saveState {
        case .idle: EmptyView()
        case .saving(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p)
                Text("Saving… \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .done(let url, let reencoded):
            VStack(alignment: .leading, spacing: 6) {
                Label("Saved to Downloads", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                Text(url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                if reencoded {
                    Text("This format can't be copied as is, so the clip was re-encoded at high quality.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Button("Show in Finder") { model.reveal() }.controlSize(.small)
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}

/// A text field that shows a time and applies it on Return or when focus leaves.
private struct TimeField: View {
    let value: Double
    let set: (Double) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField("0:00.00", text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))
            .focused($focused)
            .onAppear { text = TrimTime.format(value) }
            .onChange(of: value) { _, new in if !focused { text = TrimTime.format(new) } }
            .onSubmit(commit)
            .onChange(of: focused) { _, now in if !now { commit() } }
    }

    private func commit() {
        if let parsed = TrimTime.parse(text) { set(parsed) }
        text = TrimTime.format(value)
    }
}

private struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.videoGravity = .resizeAspect
        view.player = player
        return view
    }

    func updateNSView(_ view: AVPlayerView, context: Context) { view.player = player }
}

private struct Timeline: View {
    let model: TrimVideoModel
    private let handleWidth: CGFloat = 14

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let duration = max(model.selection.duration, 0.001)
            let x = { (t: Double) -> CGFloat in CGFloat(t / duration) * width }
            let time = { (x: CGFloat) -> Double in Double(min(max(x, 0), width) / width) * duration }
            let startX = x(model.selection.start), endX = x(model.selection.end)

            ZStack(alignment: .leading) {
                filmstrip(width: width)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { model.seek(to: time($0.location.x)) })

                // Dim what will be cut.
                Rectangle().fill(.black.opacity(0.55)).frame(width: startX).allowsHitTesting(false)
                Rectangle().fill(.black.opacity(0.55)).frame(width: max(0, width - endX))
                    .offset(x: endX).allowsHitTesting(false)

                // Selection frame between the handles.
                Rectangle().strokeBorder(Theme.accent, lineWidth: 3)
                    .frame(width: max(endX - startX, 0), height: geo.size.height)
                    .offset(x: startX).allowsHitTesting(false)

                // Playhead.
                Rectangle().fill(.white).frame(width: 2, height: geo.size.height + 8)
                    .shadow(radius: 2).offset(x: x(model.playhead) - 1).allowsHitTesting(false)

                handle(systemImage: "chevron.compact.right")
                    .offset(x: startX - handleWidth)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { model.setStart(time($0.location.x)) })
                handle(systemImage: "chevron.compact.left")
                    .offset(x: endX)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("strip")).onChanged { model.setEnd(time($0.location.x)) })
            }
            .coordinateSpace(name: "strip")
        }
        .padding(.horizontal, handleWidth)
    }

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<TrimVideoModel.thumbnailCount, id: \.self) { i in
                Group {
                    if i < model.thumbnails.count {
                        Image(nsImage: model.thumbnails[i]).resizable().scaledToFill()
                    } else {
                        Theme.inset
                    }
                }
                .frame(width: width / CGFloat(TrimVideoModel.thumbnailCount))
                .clipped()
            }
        }
        .frame(width: width)
        .background(Theme.inset)
    }

    private func handle(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.accent)
            .frame(width: handleWidth)
            .overlay(Image(systemName: systemImage).font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            .contentShape(Rectangle())
    }
}
