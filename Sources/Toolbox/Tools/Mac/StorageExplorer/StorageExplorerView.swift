import SwiftUI

struct StorageExplorerView: View {
    @State private var model = StorageExplorerModel.shared
    @State private var explorer = FolderExplorer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("", selection: $model.tab) {
                Text("Explore").tag(StorageExplorerModel.Tab.explore)
                Text("Space Hogs").tag(StorageExplorerModel.Tab.hogs)
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            HStack(alignment: .top, spacing: 14) {
                if model.tab == .hogs {
                    if let hog = model.detail { HogDetail(model: model, hog: hog) } else { hogList }
                } else {
                    ExploreList(explorer: explorer)
                }
                sidebar.frame(width: 240)
            }
        }
        .onAppear {
            if model.measures.isEmpty { model.measureAll() }
            if explorer.entries.isEmpty { explorer.go(to: explorer.location) }
        }
    }

    // MARK: Space hogs

    private var hogList: some View {
        MacCard(padding: 0) {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.hogs.enumerated()), id: \.element.id) { index, hog in
                        if index > 0 { Divider() }
                        Button { model.open(hog) } label: { hogRow(hog) }.buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func hogRow(_ hog: SpaceHog) -> some View {
        HStack(spacing: 12) {
            Image(systemName: hog.symbol).foregroundStyle(Color.cyan).frame(width: 32, height: 32)
                .background(Color.cyan.opacity(0.14), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(hog.title).font(.callout.weight(.semibold))
                Text(hog.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2).multilineTextAlignment(.leading)
            }
            Spacer()
            switch model.measures[hog.id] {
            case .measuring?, nil: ProgressView().controlSize(.small)
            case .done(let r)?: Text(r.needsAccess ? "No access" : ByteFormat.string(r.total)).font(.callout.monospacedDigit())
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16).padding(.vertical, 10).contentShape(Rectangle())
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(spacing: 14) {
            MacCard {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Startup Disk").font(.headline)
                        Text(model.disk.map { ByteFormat.string($0.total) } ?? "").font(.caption).foregroundStyle(.secondary)
                    }
                    if let d = model.disk {
                        GeometryReader { geo in
                            let w = geo.size.width, total = Double(max(d.total, 1))
                            HStack(spacing: 1) {
                                Rectangle().fill(Color.blue).frame(width: w * Double(d.used) / total)
                                Rectangle().fill(Color.blue.opacity(0.45)).frame(width: w * Double(d.purgeable) / total)
                                Rectangle().fill(Theme.tint.opacity(0.15))
                            }
                            .clipShape(Capsule())
                        }
                        .frame(height: 8)
                        HStack {
                            legend(.blue, "Used", d.used); legend(.blue.opacity(0.45), "Purgeable", d.purgeable); legend(.gray, "Free", d.free)
                        }
                    }
                }
            }
            .frame(height: 120)
            MacCard {
                VStack(alignment: .leading, spacing: 6) {
                    Text("About System Data").font(.headline)
                    Text("macOS counts caches, developer tools, backups and snapshots as System Data. These are the biggest of them, with what's safe to remove.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            MacCard {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Found").font(.caption).foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        let parts = ByteFormat.string(model.found).split(separator: " ")
                        Text(parts.first.map(String.init) ?? "0").font(.system(size: 38, weight: .bold, design: .rounded))
                        Text(parts.dropFirst().joined(separator: " ")).font(.title3.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    Text("In the places listed here.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    HStack { Spacer(); Button("Measure Again") { model.measureAll() }.disabled(model.isMeasuring) }
                }
            }
            .frame(height: 150)
        }
    }

    private func legend(_ color: Color, _ title: String, _ bytes: Int64) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(spacing: 4) { Circle().fill(color).frame(width: 6, height: 6); Text(title).font(.caption2).foregroundStyle(.secondary) }
            Text(ByteFormat.string(bytes)).font(.caption.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct HogDetail: View {
    let model: StorageExplorerModel
    let hog: SpaceHog

    var body: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button { model.back() } label: { Label("Back", systemImage: "chevron.left") }.buttonStyle(.borderless)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([hog.root]) }.controlSize(.small)
                }
                Text(hog.title).font(.title2.weight(.bold))
                Text(hog.detail).font(.caption).foregroundStyle(.secondary)
                if case .notHere(let message) = hog.clearing {
                    Label(message, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
                }
                content
                footer
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch model.measures[hog.id] {
        case .measuring?, nil:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .done(let r)?:
            if r.needsAccess {
                VStack(spacing: 8) {
                    Text("macOS doesn't let Toolbox look inside this folder.").font(.callout)
                    Button("Open Full Disk Access Settings") { SystemSettingsLink.open("Privacy_AllFiles") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if r.items.isEmpty {
                Text("Nothing here.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    InsetGroup {
                        ForEach(Array(r.items.enumerated()), id: \.element.id) { index, item in
                            if index > 0 { Divider() }
                            HStack {
                                if canClear { Toggle("", isOn: Binding(get: { model.selection.contains(item.url) }, set: { _ in model.toggle(item) })).labelsHidden() }
                                Text(item.url.lastPathComponent).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text(ByteFormat.string(item.bytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 7)
                        }
                    }
                }
            }
        }
    }

    private var canClear: Bool { if case .notHere = hog.clearing { false } else { true } }

    @ViewBuilder private var footer: some View {
        if let outcome = model.lastOutcome {
            if outcome.failures.isEmpty {
                Label("Cleared \(ByteFormat.string(outcome.freed)).", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
            } else {
                Text("Couldn't clear: \(outcome.failures.prefix(3).joined(separator: ", ")). They may be in use or protected.").font(.caption).foregroundStyle(.red)
            }
        }
        if canClear {
            HStack {
                Button("Select All") { model.selectAll() }
                Spacer()
                Text(ByteFormat.string(model.selectedBytes)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                Button(isTrash ? "Delete Permanently…" : "Move to Trash…") { model.confirmAndClear() }
                    .buttonStyle(.borderedProminent).tint(isTrash ? .red : nil).disabled(model.selection.isEmpty)
            }
        }
    }

    private var isTrash: Bool { if case .emptyTrash = hog.clearing { true } else { false } }
}

private struct ExploreList: View {
    let explorer: FolderExplorer

    var body: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button { explorer.goUp() } label: { Image(systemName: "chevron.left") }.buttonStyle(.borderless).disabled(!explorer.canGoUp)
                    Text(explorer.location.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([explorer.location]) }.controlSize(.small)
                }
                if explorer.unreadable {
                    Text("macOS doesn't let Toolbox look inside this folder.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: 4) {
                            ForEach(explorer.entries) { entry in
                                Button { if entry.isFolder { explorer.go(to: entry.url) } } label: { row(entry) }.buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
        }
    }

    private func row(_ e: FolderExplorer.Entry) -> some View {
        HStack(spacing: 10) {
            Image(systemName: e.isFolder ? "folder.fill" : "doc").foregroundStyle(e.isFolder ? Color.cyan : .secondary).frame(width: 20)
            Text(e.url.lastPathComponent).lineLimit(1).truncationMode(.middle).frame(width: 220, alignment: .leading)
            GeometryReader { geo in
                Capsule().fill(Color.cyan.opacity(0.5))
                    .frame(width: e.bytes.map { geo.size.width * Double($0) / Double(max(explorer.largest, 1)) } ?? 0)
            }
            .frame(height: 6)
            Group {
                if let bytes = e.bytes { Text(ByteFormat.string(bytes)) } else { ProgressView().controlSize(.mini) }
            }
            .font(.callout.monospacedDigit()).frame(width: 80, alignment: .trailing)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary).opacity(e.isFolder ? 1 : 0)
        }
        .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
        .background(Theme.inset.opacity(0.6), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
