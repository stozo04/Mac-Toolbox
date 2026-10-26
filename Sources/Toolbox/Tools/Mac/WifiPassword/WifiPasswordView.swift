import SwiftUI

struct WifiPasswordView: View {
    @State private var model = WifiPasswordModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            list.frame(width: 240)
            detail
        }
        .onAppear { model.loadNetworks() }
    }

    private var list: some View {
        MacCard(padding: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Saved networks").font(.headline)
                    Spacer()
                    Button { model.loadNetworks() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }
                switch model.load {
                case .loading where model.networks.isEmpty: ProgressView().frame(maxWidth: .infinity).padding(.top, 20)
                case .failed(let m): Text(m).font(.caption).foregroundStyle(.red)
                default:
                    if model.networks.isEmpty {
                        Text("No saved Wi-Fi networks were found.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            VStack(spacing: 4) {
                                ForEach(model.networks, id: \.self) { name in
                                    Button { model.selected = name } label: {
                                        HStack {
                                            Image(systemName: "wifi").foregroundStyle(Theme.accent)
                                            Text(name).lineLimit(1).truncationMode(.middle)
                                            Spacer()
                                        }
                                        .padding(8)
                                        .background(model.selected == name ? Theme.accent.opacity(0.22) : Theme.inset,
                                                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let name = model.selected {
            MacCard {
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 14) {
                        Label(name, systemImage: "wifi").font(.title2.weight(.bold)).lineLimit(2)
                        passwordBox
                        InsetGroup {
                            OptionRow(title: "Security") {
                                Picker("", selection: $model.security) {
                                    ForEach(WifiSecurity.allCases) { Text($0.rawValue).tag($0) }
                                }.labelsHidden().fixedSize()
                            }
                            Divider()
                            OptionRow(title: "Hidden network") { Toggle("", isOn: $model.hidden).labelsHidden().toggleStyle(.switch) }
                        }
                        Text("macOS asks for your approval before it shows a saved password. The password stays on this Mac.")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                    }
                    qr.frame(width: 260)
                }
            }
        } else {
            MacCard {
                CenteredState(symbol: "wifi", message: "Choose a saved network to see its password and a QR code guests can scan.") { EmptyView() }
            }
        }
    }

    private var passwordBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch model.reveal {
            case .hidden:
                Button("Show Password") { model.showPassword() }.buttonStyle(.borderedProminent)
            case .asking:
                HStack { ProgressView().controlSize(.small); Text("Waiting for your approval…").font(.callout).foregroundStyle(.secondary) }
            case .shown(let password):
                Text(password).font(.system(.title3, design: .monospaced)).textSelection(.enabled)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                HStack {
                    Button("Copy Password") { model.copyPassword() }
                    Button("Hide") { model.hidePassword() }
                }
            case .message(let text):
                Text(text).font(.callout).foregroundStyle(.secondary)
                Button("Try Again") { model.showPassword() }.controlSize(.small)
            }
        }
    }

    @ViewBuilder private var qr: some View {
        VStack(spacing: 10) {
            if let text = model.qrText, let image = WifiService.qrImage(text) {
                Image(nsImage: image).resizable().interpolation(.none).frame(width: 240, height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Point a phone camera at this to join.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Copy Image") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.writeObjects([image])
                    }
                    Button("Save…") { save(image, name: model.selected ?? "Wi-Fi") }
                }
            } else {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset).frame(width: 240, height: 240)
                    .overlay(Text("Show the password to make a QR code.").font(.caption).foregroundStyle(.secondary).padding())
            }
        }
    }

    private func save(_ image: NSImage, name: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "\(name) Wi-Fi.png"
        if panel.runModal() == .OK, let url = panel.url, let data = WifiService.pngData(image) { try? data.write(to: url) }
    }
}
