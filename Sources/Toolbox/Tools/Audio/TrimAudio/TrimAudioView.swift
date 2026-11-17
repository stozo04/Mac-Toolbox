import SwiftUI

struct TrimAudioView: View {
    @State private var model = TrimAudioModel.shared

    var body: some View {
        if model.hasClip && !model.isLoading {
            editor
        } else {
            VStack(spacing: 10) {
                DropZone(title: "Drop an Audio File Here", hint: "MP3, M4A, WAV, FLAC, AIFF and more.", symbol: "waveform",
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
            waveformCard
            options.frame(width: 240)
        }
    }

    private var waveformCard: some View {
        VStack(spacing: 14) {
            HStack {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                Text(model.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
            }
            WaveformTimeline(model: model).frame(maxHeight: .infinity)
            HStack {
                timeChip("Start", model.selection.start)
                Spacer()
                timeChip("Length", model.selection.length)
                Spacer()
                timeChip("End", model.selection.end)
            }
            HStack(spacing: 12) {
                Button { model.togglePlay() } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 18)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Play or pause (Space)")
                Text("\(TrimTime.format(model.playhead)) / \(TrimTime.format(model.selection.duration))")
                    .font(.system(.callout, design: .monospaced)).foregroundStyle(.secondary)
                Spacer()
                Button("Play Selection") { model.playSelection() }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Trim").font(.headline)
                Text("Drag the handles, or type a time.").font(.caption).foregroundStyle(.secondary)
                timeField("Start", value: model.selection.start, set: { model.setStart($0) },
                          playheadAction: model.setStartToPlayhead, playheadTitle: "Set Start to Playhead")
                timeField("End", value: model.selection.end, set: { model.setEnd($0) },
                          playheadAction: model.setEndToPlayhead, playheadTitle: "Set End to Playhead")
                fades
                format
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .safeAreaInset(edge: .bottom) { footer }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private var fades: some View {
        section("Fade") {
            fadePicker("In", selection: model.settings.fades.fadeIn, set: model.setFadeIn)
            fadePicker("Out", selection: model.settings.fades.fadeOut, set: model.setFadeOut)
        }
    }

    private func fadePicker(_ title: String, selection: FadeLength, set: @escaping (FadeLength) -> Void) -> some View {
        Picker(title, selection: Binding(get: { selection }, set: set)) {
            ForEach(FadeLength.allCases) { Text($0.label).tag($0) }
        }
        .pickerStyle(.menu)
    }

    private var format: some View {
        section("Save As") {
            Picker("Format", selection: Binding(get: { model.settings.format }, set: model.setFormat)) {
                ForEach(TrimAudioFormat.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.menu).labelsHidden()
            Text(formatNote).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var formatNote: String {
        guard let plan = model.plan else { return "" }
        if plan.keepsSoundUnchanged { return "The sound is kept exactly as it is, only shorter. The original file is never changed." }
        if model.settings.format == .original {
            return "Fades need a re-encode, saved as \(plan.fileExtension.uppercased()) at high quality. The original file is never changed."
        }
        return "Saved as \(plan.fileExtension.uppercased()). The original file is never changed."
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            VStack(alignment: .leading, spacing: 8, content: content)
                .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func timeField(_ title: String, value: Double, set: @escaping (Double) -> Void,
                           playheadAction: @escaping () -> Void, playheadTitle: String) -> some View {
        section(title) {
            TimeField(value: value, set: set)
            Button(playheadTitle, action: playheadAction).controlSize(.small)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            result
            HStack {
                Button("Choose Another") { model.close() }.disabled(model.isSaving)
                Spacer()
                if model.isSaving {
                    Button("Cancel", role: .cancel) { model.cancelSave() }
                } else {
                    Button("Save") { model.save() }
                        .buttonStyle(.borderedProminent).disabled(!model.canSave)
                        .help(model.canSave ? "Save the selection as a new file" : "Move a handle, add a fade or pick a format first")
                }
            }
        }
        .padding(.top, 10)
        .background(Theme.card)
    }

    @ViewBuilder private var result: some View {
        switch model.saveState {
        case .idle: EmptyView()
        case .saving(let p):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: p)
                Text("Saving… \(Int(p * 100))%").font(.caption).foregroundStyle(.secondary)
            }
        case .done(let result):
            VStack(alignment: .leading, spacing: 6) {
                Label("Saved to Downloads", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                HStack(spacing: 6) {
                    Text(result.url.lastPathComponent).font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
                    Spacer()
                    RevealButton { model.reveal() }
                }
            }
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red)
        }
    }
}

private struct WaveformTimeline: View {
    let model: TrimAudioModel
    private let handleWidth: CGFloat = 14
    private let barGap: CGFloat = 1
    private let minimumBarHeight: CGFloat = 2

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let duration = max(model.selection.duration, 0.001)
            let x = { (t: Double) -> CGFloat in CGFloat(t / duration) * width }
            let time = { (x: CGFloat) -> Double in Double(min(max(x, 0), width) / width) * duration }
            let startX = x(model.selection.start), endX = x(model.selection.end)

            ZStack(alignment: .leading) {
                waveform(size: geo.size)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave")).onChanged { model.seek(to: time($0.location.x)) })

                Rectangle().strokeBorder(Theme.accent, lineWidth: 3)
                    .frame(width: max(endX - startX, 0), height: geo.size.height)
                    .offset(x: startX).allowsHitTesting(false)

                Rectangle().fill(Theme.tint).frame(width: 2, height: geo.size.height + 8)
                    .shadow(radius: 2).offset(x: x(model.playhead) - 1).allowsHitTesting(false)

                handle(systemImage: "chevron.compact.right")
                    .offset(x: startX - handleWidth)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave")).onChanged { model.setStart(time($0.location.x)) })
                handle(systemImage: "chevron.compact.left")
                    .offset(x: endX)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("wave")).onChanged { model.setEnd(time($0.location.x)) })
            }
            .coordinateSpace(name: "wave")
        }
        .padding(.horizontal, handleWidth)
        .overlay {
            if model.waveformFailed {
                Text("The waveform can't be drawn for this file, but it can still be trimmed.").font(.caption).foregroundStyle(.secondary)
            } else if model.peaks.isEmpty {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func waveform(size: CGSize) -> some View {
        let peaks = model.peaks
        let selection = model.selection
        let (fadeIn, fadeOut) = model.fadeSeconds
        let inside = Theme.accent, outside = Theme.tint.opacity(0.25)
        return Canvas { context, size in
            guard !peaks.isEmpty, selection.duration > 0 else { return }
            let step = size.width / CGFloat(peaks.count)
            let barWidth = max(step - barGap, 1)
            for (i, peak) in peaks.enumerated() {
                let t = selection.duration * (Double(i) + 0.5) / Double(peaks.count)
                let isKept = t >= selection.start && t <= selection.end
                let gain = isKept ? Self.fadeGain(at: t, selection: selection, fadeIn: fadeIn, fadeOut: fadeOut) : 1
                let height = max(CGFloat(peak) * CGFloat(gain) * size.height * 0.9, minimumBarHeight)
                let bar = CGRect(x: CGFloat(i) * step, y: (size.height - height) / 2, width: barWidth, height: height)
                context.fill(Path(roundedRect: bar, cornerRadius: barWidth / 2), with: .color(isKept ? inside : outside))
            }
        }
        .frame(width: size.width, height: size.height)
    }

    static func fadeGain(at t: Double, selection: TrimSelection, fadeIn: Double, fadeOut: Double) -> Double {
        var gain = 1.0
        if fadeIn > 0 { gain = min(gain, (t - selection.start) / fadeIn) }
        if fadeOut > 0 { gain = min(gain, (selection.end - t) / fadeOut) }
        return min(max(gain, 0), 1)
    }

    private func handle(systemImage: String) -> some View {
        RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Theme.accent)
            .frame(width: handleWidth)
            .overlay(Image(systemName: systemImage).font(.system(size: 12, weight: .bold)).foregroundStyle(.white))
            .contentShape(Rectangle())
    }
}
