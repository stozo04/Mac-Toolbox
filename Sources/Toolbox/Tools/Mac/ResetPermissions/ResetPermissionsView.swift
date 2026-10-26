import SwiftUI

struct ResetPermissionsView: View {
    @State private var model = ResetPermissionsModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            appList.frame(width: 250)
            detail
        }
        .onAppear { model.loadApps() }
    }

    private var appList: some View {
        MacCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("App").font(.headline)
                TextField("Search apps", text: $model.search).textFieldStyle(.roundedBorder)
                if model.apps.isEmpty {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                    Spacer()
                } else {
                    ScrollView {
                        LazyVStack(spacing: 3) {
                            ForEach(model.filtered) { app in
                                Button { model.selected = app } label: {
                                    HStack(spacing: 8) {
                                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 22, height: 22)
                                        Text(app.name).lineLimit(1)
                                        Spacer()
                                    }
                                    .padding(6)
                                    .background(model.selected == app ? Theme.accent.opacity(0.22) : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button("Choose Another App…") {
                    let panel = NSOpenPanel()
                    panel.directoryURL = URL(fileURLWithPath: "/Applications")
                    panel.allowedContentTypes = [.application]
                    if panel.runModal() == .OK, let url = panel.url { model.choose(url: url) }
                }
                .controlSize(.small)
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let app = model.selected {
            MacCard {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 48, height: 48)
                        VStack(alignment: .leading) {
                            Text(app.name).font(.title2.weight(.bold))
                            Text(app.bundleID).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Reset All for This App") { model.resetAll() }
                    }
                    Text("Resetting takes back the permission. The app asks again the next time it needs it. Quit the app first so it asks cleanly.")
                        .font(.caption).foregroundStyle(.secondary)
                    ScrollView {
                        InsetGroup {
                            ForEach(Array(PrivacyService.all.enumerated()), id: \.element.id) { index, service in
                                if index > 0 { Divider() }
                                row(service)
                            }
                        }
                    }
                    if let all = model.results["All"] { status(all) }
                }
            }
        } else {
            MacCard {
                CenteredState(symbol: "lock.rotation", message: "Choose an app to unstick its Screen Recording, Microphone, Camera or other privacy access.") { EmptyView() }
            }
        }
    }

    private func row(_ service: PrivacyService) -> some View {
        OptionRow(title: service.title) {
            HStack(spacing: 8) {
                if let s = model.results[service.id] { status(s) }
                Button("Reset") { model.reset(service) }.controlSize(.small)
                    .disabled(model.results[service.id] == .working)
                Button { SystemSettingsLink.open(service.settingsPane) } label: { Image(systemName: "gearshape") }
                    .buttonStyle(.borderless).help("Open this page in System Settings")
            }
        }
    }

    @ViewBuilder private func status(_ s: ResetPermissionsModel.Status) -> some View {
        switch s {
        case .done: Image(systemName: "checkmark").foregroundStyle(.green).help("Reset")
        case .working: ProgressView().controlSize(.small)
        case .failed(let m): Text(m).font(.caption2).foregroundStyle(.red).lineLimit(2).frame(maxWidth: 160)
        }
    }
}
