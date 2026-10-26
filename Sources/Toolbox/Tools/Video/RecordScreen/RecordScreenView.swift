import SwiftUI

struct RecordScreenView: View {
    @State private var model = RecordScreenModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                if model.access == .denied { permissionBanner }
                if let notice = model.notice { noticeBanner(notice) }
                sourceCard
                recordBar
            }
            options.frame(width: 240)
        }
        .task { await model.refresh() }
    }

    // MARK: Source

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Source").font(.headline)
                Text(countText).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Picker("Source", selection: $model.kind) {
                    ForEach(RecordingSourceKind.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(model.isBusy)
                Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Refresh")
                    .disabled(model.isBusy || model.isLoading)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 14, alignment: .top)], spacing: 14) {
                    if model.kind == .window {
                        ForEach(model.windows) { w in
                            SourceTile(image: w.thumbnail, title: w.app, subtitle: w.title.isEmpty ? "Untitled" : w.title,
                                       selected: model.selectedWindowID == w.id) { model.selectedWindowID = w.id }
                        }
                    } else {
                        ForEach(model.displays) { d in
                            SourceTile(image: d.thumbnail, title: d.name, subtitle: d.sizeText,
                                       selected: model.selectedDisplayID == d.id) { model.selectDisplay(d.id) }
                        }
                    }
                }
                .padding(2)
                if emptyList { emptyState }
            }
            .disabled(model.isBusy)
            if model.kind == .area { areaBar }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .cardBackground(corner: 24)
    }

    private var countText: String {
        switch model.kind {
        case .window: "\(model.windows.count) window\(model.windows.count == 1 ? "" : "s")"
        default: "\(model.displays.count) display\(model.displays.count == 1 ? "" : "s")"
        }
    }

    private var emptyList: Bool {
        model.kind == .window ? model.windows.isEmpty : model.displays.isEmpty
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            if model.isLoading { ProgressView() } else {
                Image(systemName: model.kind == .window ? "macwindow" : "display").font(.largeTitle).foregroundStyle(.secondary)
                Text(model.access == .denied ? "Screen Recording is off" : "Nothing to record").font(.headline)
                if model.kind == .window {
                    Text("Open the app you want to record, then refresh.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var areaBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "viewfinder").foregroundStyle(Theme.accent)
            if let area = model.area {
                Text("\(Int(area.width)) × \(Int(area.height)) points").font(.callout)
            } else {
                Text("No area chosen yet. Pick one now, or when you start.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(model.area == nil ? "Select Area…" : "Change Area…") { Task { await model.chooseArea() } }
                .disabled(model.isBusy || model.selectedDisplay == nil)
        }
        .padding(10)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    // MARK: Banners

    private var permissionBanner: some View {
        banner(title: "Screen Recording is off",
               detail: "Allow Toolbox in System Settings > Privacy & Security > Screen & System Audio Recording. You may need to reopen Toolbox afterwards.",
               settingsURL: RecordScreenModel.screenSettingsURL, retry: true)
    }

    private func noticeBanner(_ notice: RecordScreenModel.Notice) -> some View {
        banner(title: "Couldn't record", detail: notice.message, settingsURL: notice.settingsURL, retry: false)
    }

    private func banner(title: String, detail: String, settingsURL: URL?, retry: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if let settingsURL { Button("Open Settings") { NSWorkspace.shared.open(settingsURL) } }
            if retry { Button("Try Again") { Task { await model.refresh() } } }
        }
        .padding(12).cardBackground(corner: 16)
    }

    // MARK: Record bar

    private var recordBar: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Label(statusText, systemImage: statusSymbol)
                    .font(.caption).foregroundStyle(model.phase == .recording ? .red : .secondary)
                Text(RecordingGeometry.clock(model.elapsed))
                    .font(.system(size: 40, weight: .bold, design: .rounded)).monospacedDigit()
                Text(savedText ?? model.sourceSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            if model.savedFile != nil, !model.isBusy {
                Button("Show in Finder") { model.reveal() }
                Button("Open") { model.open() }
            }
            RecordButton(phase: model.phase) { model.toggle() }
                .disabled(!model.canRecord && model.phase == .idle)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .cardBackground(corner: 24)
    }

    private var statusText: String {
        switch model.phase {
        case .idle: model.savedFile == nil ? "Ready to record" : "Saved to Downloads"
        case .countdown(let n): "Starting in \(n)…"
        case .starting: "Starting…"
        case .recording: "Recording"
        case .finishing: "Saving…"
        }
    }

    private var statusSymbol: String {
        switch model.phase {
        case .recording: "record.circle.fill"
        case .idle where model.savedFile != nil: "checkmark.circle.fill"
        default: "record.circle"
        }
    }

    private var savedText: String? {
        model.phase == .idle ? model.savedFile?.lastPathComponent : nil
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Options").font(.headline)
            Text("Sound, pointer and file format.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    section("Sound") {
                        toggleRow("System audio", $model.options.systemAudio)
                        Divider().overlay(Theme.stroke)
                        toggleRow("Microphone", $model.options.microphone)
                    }
                    section("Pointer") {
                        toggleRow("Show pointer", $model.options.showPointer)
                        Divider().overlay(Theme.stroke)
                        toggleRow("Highlight clicks", $model.options.highlightClicks)
                        Divider().overlay(Theme.stroke)
                        toggleRow("Include Toolbox windows", $model.options.includeToolboxWindows)
                            .disabled(model.kind == .window)
                    }
                    section("Recording") {
                        pickerRow("Resolution", $model.options.resolution, RecordingResolution.allCases) { $0.rawValue }
                        Divider().overlay(Theme.stroke)
                        pickerRow("Frame rate", $model.options.frameRate, RecordingFrameRate.allCases) { $0.label }
                        Divider().overlay(Theme.stroke)
                        pickerRow("Format", $model.options.format, RecordingFormat.allCases) { $0.rawValue }
                        Divider().overlay(Theme.stroke)
                        toggleRow("3-second countdown", $model.options.countdown)
                    }
                    Text(footnote).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .disabled(model.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private var footnote: String {
        let resolution = switch model.options.resolution {
        case .native: "Native keeps every pixel, so files are the largest."
        case .p1440: "1440p is sharp on large displays."
        case .p1080: "1080p is a good balance of sharpness and size."
        case .p720: "720p makes the smallest files, good for quick shares and chat."
        }
        return "\(resolution) Saved as H.264, which plays everywhere. Stop from the floating controls at the top of the screen."
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold))
            VStack(spacing: 0) { content() }
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Toggle(title, isOn: binding).toggleStyle(.switch).labelsHidden()
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
    }

    private func pickerRow<T: Hashable & Identifiable>(_ title: String, _ binding: Binding<T>, _ all: [T],
                                                       label: @escaping (T) -> String) -> some View {
        HStack {
            Text(title).font(.callout)
            Spacer()
            Picker(title, selection: binding) { ForEach(all) { Text(label($0)).tag($0) } }
                .labelsHidden().fixedSize()
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
    }
}

private struct SourceTile: View {
    let image: NSImage?
    let title: String
    let subtitle: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack {
                    Theme.inset
                    if let image {
                        Image(nsImage: image).resizable().scaledToFit()
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .aspectRatio(16 / 10, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                        Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                }
            }
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(selected ? Theme.accent : Theme.stroke, lineWidth: selected ? 2 : 1))
        }
        .buttonStyle(.plain)
    }
}

private struct RecordButton: View {
    let phase: RecordScreenModel.Phase
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(Theme.tint.opacity(0.35), lineWidth: 3).frame(width: 56, height: 56)
                if phase == .recording {
                    RoundedRectangle(cornerRadius: 5).fill(.red).frame(width: 22, height: 22)
                } else if phase == .starting || phase == .finishing {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(.red).frame(width: 44, height: 44)
                    if case .countdown = phase { Image(systemName: "xmark").font(.headline).foregroundStyle(.white) }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(phase == .starting || phase == .finishing)
        .help(phase == .recording ? "Stop recording" : "Start recording")
    }
}
