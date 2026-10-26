import SwiftUI

struct HiddenSettingsView: View {
    @State private var model = HiddenSettingsModel.shared

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 14) {
                VStack(spacing: 14) { group(.dock); group(.screenshots); group(.textEdit) }
                VStack(spacing: 14) {
                    group(.finder)
                    group(.files)
                    if model.anyModified {
                        Button("Reset Everything to Defaults") { model.resetAll() }.controlSize(.small)
                    }
                }
            }
        }
    }

    private func group(_ g: HiddenSetting.Group) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(g.rawValue, systemImage: g.symbol).font(.headline)
                Spacer()
                if let target = g.restarts { Pill(text: "Restarts \(target.rawValue)") }
            }
            InsetGroup {
                let items = HiddenSetting.settings(in: g)
                ForEach(Array(items.enumerated()), id: \.element.id) { index, s in
                    if index > 0 { Divider() }
                    row(s)
                }
            }
            if let note = g.footnote { Text(note).font(.caption2).foregroundStyle(.secondary) }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .topLeading).cardBackground(corner: 24)
    }

    private func row(_ s: HiddenSetting) -> some View {
        OptionRow(title: s.title, subtitle: s.subtitle) {
            HStack(spacing: 8) {
                if model.isModified(s) {
                    Button { model.reset(s) } label: { Image(systemName: "arrow.uturn.backward") }
                        .buttonStyle(.borderless).help("Back to the macOS default")
                }
                control(s)
            }
        }
    }

    @ViewBuilder private func control(_ s: HiddenSetting) -> some View {
        switch s.kind {
        case .toggle:
            Toggle("", isOn: Binding(get: { model.isOn(s) }, set: { model.setOn($0, s) })).labelsHidden().toggleStyle(.switch)
        case .slider(let range):
            HStack(spacing: 8) {
                Slider(value: Binding(get: { model.number(s) ?? range.lowerBound }, set: { model.setNumber($0, s) }), in: range)
                    .frame(width: 110)
                Text(sliderLabel(s)).font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
            }
        case .choice(let options, _):
            Picker("", selection: Binding(get: { model.text(s) }, set: { model.setText($0, s) })) {
                ForEach(options, id: \.self) { Text($0.uppercased()).tag($0) }
            }.labelsHidden().fixedSize()
        case .folder:
            Button { chooseFolder(for: s) } label: {
                Label(URL(fileURLWithPath: (model.text(s) as NSString).expandingTildeInPath).lastPathComponent, systemImage: "folder")
            }
        }
    }

    private func sliderLabel(_ s: HiddenSetting) -> String {
        guard let value = model.number(s) else { return "Default" }
        return String(format: "%.2f s", value)
    }

    private func chooseFolder(for s: HiddenSetting) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { model.setText(url.path, s) }
    }
}
