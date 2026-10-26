import SwiftUI

struct FixDamagedAppView: View {
    @State private var model = FixDamagedAppModel.shared

    var body: some View {
        if let app = model.app {
            HStack(alignment: .top, spacing: 14) {
                details(app)
                actions(app).frame(width: 260)
            }
        } else {
            VStack(spacing: 10) {
                DropZone(title: "Drop an App Here", hint: "Drop the app that says it's damaged or can't be opened.", symbol: "app.dashed",
                         allowsMultiple: false) { urls in if let url = urls.first { model.load(url) } }
                    .overlay { if model.isLoading { ProgressView().controlSize(.large) } }
                if let error = model.loadError { Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.yellow) }
            }
        }
    }

    private func details(_ app: AppDetails) -> some View {
        MacCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: app.url.path)).resizable().frame(width: 64, height: 64)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(app.name).font(.title2.weight(.bold))
                        Text([app.version.map { "Version \($0)" }, app.bundleID].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                InsetGroup {
                    row("Made by", value: maker(app))
                    Divider()
                    row("Signature", value: signatureText(app), color: app.signature.isValid ? .green : .orange)
                    Divider()
                    row("Apple's check", value: assessmentText(app.assessment), color: assessmentColor(app.assessment))
                    Divider()
                    row("Download flag", value: app.isQuarantined ? "Quarantined" : "None", color: app.isQuarantined ? .orange : .green)
                }
                if let verdict = model.verdict {
                    Label(verdict.text, systemImage: verdict.symbol)
                        .font(.callout).foregroundStyle(verdict.good ? Color.green : .primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
        }
    }

    private func actions(_ app: AppDetails) -> some View {
        MacCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Fix it").font(.headline)
                Text("Clearing the quarantine removes the “downloaded from the internet” flag so macOS stops blocking the app. The app itself isn't changed.")
                    .font(.caption).foregroundStyle(.secondary)
                switch model.outcome {
                case .none: EmptyView()
                case .cleared: Label("Quarantine cleared. Try opening the app again.", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(.red)
                }
                Spacer()
                Button("Open App") { NSWorkspace.shared.open(app.url) }.disabled(model.outcome != .cleared && app.isQuarantined)
                HStack {
                    Button("Choose Another") { model.close() }
                    Spacer()
                    Button("Clear Quarantine") { model.confirmAndClear() }
                        .buttonStyle(.borderedProminent).disabled(!app.isQuarantined)
                        .help(app.isQuarantined ? "Remove the download flag" : "This app has no download flag")
                }
            }
        }
    }

    private func row(_ title: String, value: String, color: Color = .primary) -> some View {
        OptionRow(title: title) { Text(value).font(.callout).foregroundStyle(color).multilineTextAlignment(.trailing) }
    }

    private func maker(_ app: AppDetails) -> String {
        app.signature.developer ?? (app.signature.isSigned ? "Unknown developer" : "Unknown (not signed)")
    }

    private func signatureText(_ app: AppDetails) -> String {
        if !app.signature.isSigned { return "Not signed" }
        if !app.signature.isValid { return "Broken" }
        return app.signature.isAdHoc ? "Local only" : "Valid"
    }

    private func assessmentText(_ a: Assessment) -> String {
        switch a {
        case .notarized: "Approved (notarized)"
        case .developerID: "Identified developer"
        case .appStore: "Mac App Store"
        case .rejected: "Not approved"
        case .unknown: "Unknown"
        }
    }

    private func assessmentColor(_ a: Assessment) -> Color {
        switch a {
        case .notarized, .developerID, .appStore: .green
        case .rejected: .orange
        case .unknown: .secondary
        }
    }
}
