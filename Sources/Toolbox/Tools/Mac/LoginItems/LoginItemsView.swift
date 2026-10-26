import SwiftUI

struct LoginItemsView: View {
    @State private var model = LoginItemsModel.shared

    var body: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Background items").font(.headline)
                    Text(model.items.isEmpty ? "" : "\(model.items.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    TextField("Search", text: $model.search).textFieldStyle(.roundedBorder).frame(width: 180)
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                    Button("Login Items Settings…") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") { NSWorkspace.shared.open(url) }
                    }
                    .controlSize(.small)
                }
                if model.items.isEmpty {
                    CenteredState(symbol: "switch.2", message: model.isLoading ? "Loading startup items…" : "No background items were found.") { EmptyView() }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ForEach(LaunchItem.Scope.allCases, id: \.self) { scope in
                                let items = model.items(in: scope)
                                if !items.isEmpty { section(scope, items) }
                            }
                        }
                    }
                    Text("Apps you add under General › Login Items in System Settings are managed there. Items for all users and system services need an administrator, so they are shown but locked.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { model.refresh() }
    }

    private func section(_ scope: LaunchItem.Scope, _ items: [LaunchItem]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(scope.rawValue).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            InsetGroup {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider() }
                    row(item)
                }
            }
        }
    }

    private func row(_ item: LaunchItem) -> some View {
        HStack(spacing: 10) {
            Image(nsImage: icon(for: item)).resizable().frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.displayName).font(.callout.weight(.semibold)).lineLimit(1)
                    if !item.signature.isSigned && item.exists { Pill(text: "Unsigned", color: .orange) }
                    if item.signature.isSigned && !item.signature.isValid { Pill(text: "Changed since signed", color: .red) }
                    if item.runsAtLogin { Pill(text: "At login") }
                }
                Text(item.displayName == item.label ? item.developerText : "\(item.developerText) · \(item.label)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let error = model.errors[item.id] { Text(error).font(.caption2).foregroundStyle(.red) }
            }
            Spacer()
            Button { model.reveal(item) } label: { Image(systemName: "magnifyingglass") }.buttonStyle(.borderless).help("Show the file in Finder")
            if item.scope.canToggle {
                Toggle("", isOn: Binding(get: { item.isEnabled }, set: { model.toggle(item, to: $0) })).labelsHidden().toggleStyle(.switch)
            } else {
                Image(systemName: "lock.fill").foregroundStyle(.secondary).help("Needs an administrator to change")
            }
        }
        .padding(.vertical, 8)
    }

    private func icon(for item: LaunchItem) -> NSImage {
        if let program = item.program, item.exists {
            return NSWorkspace.shared.icon(forFile: LaunchItems.signingTarget(forProgram: program))
        }
        return NSImage(systemSymbolName: "questionmark.app", accessibilityDescription: nil) ?? NSImage()
    }
}
