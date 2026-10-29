import AppKit
import Observation
import UniformTypeIdentifiers

@MainActor @Observable
final class MediaInfoModel {
    /// Shared so the file list survives switching to another tool and back.
    static let shared = MediaInfoModel()

    enum State: Equatable {
        case reading
        case ready(MediaReport)
        case failed(String)
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        var state = State.reading
    }

    private(set) var items: [Item] = []
    var selection: Item.ID?
    private(set) var notice: String?
    private(set) var flash: String?

    var hasItems: Bool { !items.isEmpty }
    var selected: Item? { items.first { $0.id == selection } }
    var reports: [MediaReport] { items.compactMap { if case .ready(let r) = $0.state { r } else { nil } } }

    // MARK: Files

    /// Adds files; folders are searched for video and audio files inside them.
    func add(_ urls: [URL]) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let before = found.count
            found += Self.mediaFiles(in: url)
            if found.count == before { skipped += 1 }
        }
        var known = Set(items.map { BatchFiles.identity($0.url) })
        let new = found.filter { known.insert(BatchFiles.identity($0)).inserted }.map { Item(url: $0) }
        items += new
        if selection == nil { selection = new.first?.id }
        notice = skipped == 0 ? nil : "\(skipped) item(s) had no video or audio files and were skipped."
        for item in new { read(item) }
    }

    func remove(_ id: Item.ID) {
        items.removeAll { $0.id == id }
        if selection == id { selection = items.first?.id }
    }

    func clear() {
        items = []
        selection = nil
        notice = nil
    }

    /// A file given directly is always tried (the result says if it can't be read); a folder yields only audio and video files.
    static func mediaFiles(in url: URL) -> [URL] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return [] }
        if !isDirectory.boolValue { return [url] }
        let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.contentTypeKey],
                                                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
        return (walker?.compactMap { $0 as? URL } ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.contentTypeKey]).contentType)?.conforms(to: .audiovisualContent) ?? false }
            .sorted { $0.path < $1.path }
    }

    private func read(_ item: Item) {
        Task { [weak self] in
            let state: State
            do {
                state = .ready(try await MediaInspector.inspect(item.url))
            } catch {
                state = .failed(error.localizedDescription)
                Log.warning("Media info failed", category: "mediainfo", Log.details(error, file: item.url))
            }
            self?.set(item.id, state)
        }
    }

    private func set(_ id: Item.ID, _ state: State) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].state = state
    }

    // MARK: Report

    /// The report for the selected file, or for every file that could be read.
    private func chosen(all: Bool) -> [MediaReport] {
        if all { return reports }
        if case .ready(let r)? = selected?.state { return [r] }
        return []
    }

    func copyText(all: Bool) {
        let chosen = chosen(all: all)
        guard !chosen.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(chosen.map(\.text).joined(separator: "\n\n———\n\n"), forType: .string)
        showFlash("Copied")
    }

    func exportJSON(all: Bool) {
        let chosen = chosen(all: all)
        guard !chosen.isEmpty else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = chosen.count == 1
            ? "\((chosen[0].fileName as NSString).deletingPathExtension) media info.json" : "Media Info.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try MediaReport.json(chosen).write(to: url, options: .atomic)
            showFlash("Saved")
        } catch {
            showFlash("Could not save the file")
        }
    }

    func openInMaps(_ location: MediaReport.Location) {
        var components = URLComponents(string: "https://maps.apple.com/")!
        components.queryItems = [URLQueryItem(name: "ll", value: "\(location.latitude),\(location.longitude)"),
                                 URLQueryItem(name: "q", value: "Video location")]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    private func showFlash(_ text: String) {
        flash = text
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            if self?.flash == text { self?.flash = nil }
        }
    }
}
