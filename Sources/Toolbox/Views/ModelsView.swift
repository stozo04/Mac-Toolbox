import AppKit
import SwiftUI

struct ModelsView: View {
    @State private var library = ModelLibrary.shared
    @State private var moving: Set<String> = []
    @State private var confirming: InstalledModel?
    @State private var confirmingAll = false
    @State private var problem: String?

    private let columns = [GridItem(.adaptive(minimum: 340), spacing: 16)]

    private var mover: ModelMover {
        ModelMover(central: library.central) { name in
            NSWorkspace.shared.runningApplications.contains { $0.localizedName == name }
        }
    }

    private var movable: [InstalledModel] { library.models.filter { $0.movability == .movable } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                centralFolder
                if library.models.isEmpty {
                    empty
                } else {
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(library.models) { model in
                            card(model).transition(.opacity.combined(with: .scale(scale: 0.97)))
                        }
                    }
                }
            }
            .padding(20)
            .animation(.easeInOut(duration: 0.25), value: library.models.map(\.id))
        }
        .onAppear { library.start() }
        .alert("Move this model?", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), presenting: confirming) { model in
            Button("Move") { move([model]) }
            Button("Cancel", role: .cancel) {}
        } message: { model in
            Text(confirmation(for: [model]))
        }
        .alert("Move \(movable.count) models?", isPresented: $confirmingAll) {
            Button("Move") { move(movable) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(confirmation(for: movable))
        }
        .alert("Couldn't move it", isPresented: Binding(get: { problem != nil }, set: { if !$0 { problem = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(problem ?? "")
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryLine).font(.caption).foregroundStyle(.secondary)
                Text("AI Models").font(.system(size: 34, weight: .bold))
            }
            Spacer()
            if let note = library.changeNote {
                Label(note, systemImage: "sparkles").font(.callout).foregroundStyle(Theme.accent).transition(.opacity)
            } else if library.isScanning {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Looking…").font(.caption).foregroundStyle(.secondary) }
            } else if library.hasScanned {
                Label("Up to date. Changes show up on their own.", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            }
            Button { library.refresh() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Look again")
        }
        .animation(.default, value: library.changeNote)
    }

    private var summaryLine: String {
        guard library.hasScanned else { return "Looking for models on this Mac…" }
        let count = library.models.count
        return "\(count) model\(count == 1 ? "" : "s") on this Mac · nothing leaves your Mac"
    }

    // MARK: Central folder

    private var centralFolder: some View {
        HStack(spacing: 14) {
            Image(systemName: "folder.badge.gearshape").font(.title2).foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44).background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text("Central folder").font(.headline)
                Text(tilde(library.central.path)).font(.callout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text("Models you move here leave a link behind, so the apps that use them keep working.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Button("Show in Finder") { reveal(library.central, create: true) }
            Button(movable.isEmpty ? "Nothing to move" : "Move \(movable.count) here") { confirmingAll = true }
                .buttonStyle(.borderedProminent).disabled(movable.isEmpty || !moving.isEmpty)
        }
        .padding(16).cardBackground()
    }

    // MARK: Cards

    private func card(_ model: InstalledModel) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: model.kind.symbol).font(.title2).foregroundStyle(Theme.accent)
                    .frame(width: 48, height: 48).background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.headline).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                    Text(model.kind.rawValue + (model.owner.map { " · \($0)" } ?? "")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .layoutPriority(1)
                Spacer(minLength: 8)
                versionBadge(model)
            }
            Text(model.summary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            tags(model)
            versionDetail(model)
            apps(model)
            Divider()
            location(model)
            Spacer(minLength: 0)
            action(model)
        }
        .frame(maxWidth: .infinity, minHeight: 260, alignment: .topLeading)
        .padding(16).cardBackground()
    }

    /// The version where the size used to be: big and plain, or a dash when nothing records one.
    private func versionBadge(_ model: InstalledModel) -> some View {
        let value = model.version?.value ?? ""
        return VStack(alignment: .trailing, spacing: 1) {
            Text(value.isEmpty ? "—" : value)
                .font(.callout.weight(.semibold)).monospacedDigit().foregroundStyle(value.isEmpty ? .secondary : .primary)
                .lineLimit(2).multilineTextAlignment(.trailing)
            Text(value.isEmpty ? "no version" : "version").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: 90, alignment: .trailing)
    }

    /// Where the version number comes from, so a guess from a name is not mistaken for one the model states.
    private func versionDetail(_ model: InstalledModel) -> some View {
        Label(versionExplanation(model), systemImage: "number").font(.caption2).foregroundStyle(.secondary).lineLimit(2)
    }

    private func versionExplanation(_ model: InstalledModel) -> String {
        guard let version = model.version else { return "No version is recorded in this model's files." }
        let source = version.value.isEmpty ? "Version not recorded" : version.source.prefix(1).uppercased() + version.source.dropFirst()
        return [source, version.format].compactMap { $0 }.joined(separator: " · ")
    }

    private func tags(_ model: InstalledModel) -> some View {
        HStack(spacing: 6) {
            ForEach(model.tags, id: \.self) { tag in
                Text(tag).font(.caption2).padding(.horizontal, 8).padding(.vertical, 3).background(Capsule().fill(Theme.tint.opacity(0.08)))
            }
        }
    }

    @ViewBuilder private func apps(_ model: InstalledModel) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("Used by").font(.caption).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
            if model.apps.isEmpty {
                Text("No app found. It may be a file you downloaded yourself.").font(.caption).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(model.apps, id: \.self) { app in
                        HStack(spacing: 6) {
                            if let url = app.bundleURL {
                                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 18, height: 18)
                            } else if app.isMacOS {
                                Image(systemName: "apple.logo").frame(width: 18, height: 18)
                            } else {
                                Image(systemName: "app.dashed").foregroundStyle(.secondary).frame(width: 18, height: 18)
                            }
                            Text(app.name).font(.callout)
                            if app.inUse {
                                Label("using it now", systemImage: "circle.fill").labelStyle(.titleAndIcon).font(.caption2).foregroundStyle(.green)
                            }
                            if let note = app.note { Text(note).font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
            }
        }
    }

    private func location(_ model: InstalledModel) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18)
                Text(tilde(model.url.path)).font(.caption).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 4)
                RevealButton { reveal(model.url) }
            }
            ForEach(model.linkedFrom, id: \.self) { link in
                Label("Found through a link at \(tilde(link.path))", systemImage: "link").font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    @ViewBuilder private func action(_ model: InstalledModel) -> some View {
        switch model.movability {
        case .movable:
            HStack {
                Spacer()
                if moving.contains(model.id) { ProgressView().controlSize(.small) }
                Button("Move to central folder") { confirming = model }.disabled(!moving.isEmpty)
            }
        case .central:
            HStack {
                Label("In the central folder", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                Spacer()
                if moving.contains(model.id) { ProgressView().controlSize(.small) }
                if !model.linkedFrom.isEmpty {
                    Button("Move back") { moveBack(model) }.disabled(!moving.isEmpty)
                }
            }
        case .managed(let reason):
            Label(reason, systemImage: "lock").font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Image(systemName: "cpu").font(.system(size: 36)).foregroundStyle(.secondary)
            Text(library.hasScanned ? "No AI models found" : "Looking…").font(.headline)
            Text("Toolbox looks in the places apps keep models and watches them. Download a model with any app and it appears here by itself.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
        }
        .frame(maxWidth: .infinity, minHeight: 240).cardBackground()
    }

    // MARK: Actions

    private func confirmation(for models: [InstalledModel]) -> String {
        let names = models.map(\.name)
        let list = names.count > 3 ? names.prefix(3).joined(separator: ", ") + " and \(names.count - 3) more" : names.joined(separator: ", ")
        let apps = Set(models.compactMap(\.owner)).sorted()
        let who = apps.isEmpty ? "" : " " + apps.joined(separator: " and ") + " will keep working:"
        return "\(list) goes to \(tilde(library.central.path)).\(who) a link stays where the model was, so it is still found. You can move it back at any time."
    }

    private func move(_ models: [InstalledModel]) {
        run(models) { try mover.move($0) }
    }

    private func moveBack(_ model: InstalledModel) {
        run([model]) { try mover.moveBack($0) }
    }

    private func run(_ models: [InstalledModel], _ work: @escaping @Sendable (InstalledModel) throws -> Any) {
        moving = Set(models.map(\.id))
        Task {
            var failure: String?
            for model in models {
                let outcome = await Task.detached(priority: .userInitiated) { Result { try work(model) } }.value
                if case .failure(let error) = outcome { failure = "\(model.name): \(error.localizedDescription)"; break }
                moving.remove(model.id)
            }
            moving = []
            problem = failure
            library.refresh()
        }
    }

    private func reveal(_ url: URL, create: Bool = false) {
        if create { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func tilde(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
}
