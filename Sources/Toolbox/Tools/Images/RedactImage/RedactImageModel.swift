import AppKit
import Observation

@MainActor @Observable
final class RedactImageModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = RedactImageModel()

    enum Status: Equatable {
        case ready
        case working
        case done(RedactResult)
        case failed(String)
    }

    struct Region: Identifiable, Equatable {
        let id = UUID()
        /// Normalized to the upright image, origin at the top left.
        var rect: CGRect
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: Int64
        /// The upright size in pixels.
        let size: PixelSize
        var thumbnail: CGImage?
        var regions: [Region] = []
        var status = Status.ready

        var name: String { url.lastPathComponent }
        var rects: [CGRect] { regions.map(\.rect) }
        var isDone: Bool { if case .done = status { true } else { false } }
        /// Worth exporting: something is covered and the copy is not already saved.
        var isExportable: Bool {
            guard !regions.isEmpty else { return false }
            switch status {
            case .ready, .failed: return true
            case .working, .done: return false
            }
        }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case thisImage = "This Image"
        case allImages = "All Images"
        var id: String { rawValue }
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var finding: RedactFind?
    private(set) var folder: URL?
    private(set) var notice: String?
    /// What the last Find & Cover did.
    private(set) var findMessage: String?
    var selectedID: UUID?
    var selectedRegionID: UUID?

    var settings = RedactSettings()
    var scope = Scope.thisImage

    private var task: Task<Void, Never>?
    private var thumbnailer: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }
    var selected: Item? { items.first { $0.id == selectedID } }
    var isBusy: Bool { isRunning || finding != nil }
    var hasExportable: Bool { items.contains { $0.isExportable } }
    var doneCount: Int { items.filter(\.isDone).count }
    /// Images with nothing covered, which Export leaves out.
    var untouchedCount: Int { items.filter { $0.regions.isEmpty }.count }
    var regionCount: Int { items.reduce(0) { $0 + $1.regions.count } }

    // MARK: Queue

    /// Adds images; folders are searched for images inside them. Animated and unreadable ones are skipped.
    func add(_ urls: [URL]) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let before = found.count
            found += BatchFiles.images(in: url)
            if found.count == before { skipped += 1 }
        }
        var known = Set(items.map { BatchFiles.identity($0.url) })
        for url in found where known.insert(BatchFiles.identity(url)).inserted {
            guard let size = RedactImage.inspect(url) else { skipped += 1; continue }
            items.append(Item(url: url, bytes: Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0), size: size))
        }
        if selectedID == nil || selected == nil { select(items.first?.id) }
        notice = skipped == 0 ? nil : "\(skipped) item(s) were not images macOS can read, or were animated, and were skipped."
        loadThumbnails()
    }

    func remove(_ id: UUID) {
        guard !isBusy else { return }
        items.removeAll { $0.id == id }
        if selectedID == id { select(items.first?.id) }
    }

    func clear() {
        task?.cancel()
        items = []
        selectedID = nil
        selectedRegionID = nil
        folder = nil
        notice = nil
        findMessage = nil
        isRunning = false
        finding = nil
    }

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        selectedID = id
        selectedRegionID = nil
        findMessage = nil
    }

    private func loadThumbnails() {
        guard thumbnailer == nil else { return }
        thumbnailer = Task {
            while let item = items.first(where: { $0.thumbnail == nil }) {
                let url = item.url
                let image = await Task.detached(priority: .utility) { ImageConverter.thumbnail(of: url, maxSize: 200) }.value
                guard let i = items.firstIndex(where: { $0.id == item.id }) else { continue }
                // Without a thumbnail the loop would find this image again forever.
                items[i].thumbnail = image ?? Self.placeholder
            }
            thumbnailer = nil
        }
    }

    private static let placeholder: CGImage = {
        let context = CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return context.makeImage()!
    }()

    // MARK: Regions

    /// Covers a new region on the selected image and selects it.
    @discardableResult
    func addRegion(_ rect: CGRect) -> UUID? {
        guard !isBusy, let i = selectedIndex else { return nil }
        let region = Region(rect: RedactImage.fitted(rect))
        items[i].regions.append(region)
        reopen(i)
        selectedRegionID = region.id
        return region.id
    }

    func setRect(_ rect: CGRect, of regionID: UUID) {
        guard !isBusy, let i = selectedIndex, let r = items[i].regions.firstIndex(where: { $0.id == regionID }) else { return }
        items[i].regions[r].rect = RedactImage.fitted(rect)
        reopen(i)
    }

    /// Removes the selected region.
    func deleteSelectedRegion() {
        guard !isBusy, let i = selectedIndex, let id = selectedRegionID else { return }
        items[i].regions.removeAll { $0.id == id }
        selectedRegionID = nil
        reopen(i)
    }

    /// Removes every region from the selected image.
    func clearRegions() {
        guard !isBusy, let i = selectedIndex, !items[i].regions.isEmpty else { return }
        items[i].regions = []
        selectedRegionID = nil
        reopen(i)
    }

    private var selectedIndex: Int? { items.firstIndex { $0.id == selectedID } }

    /// A saved or failed image whose regions change has to be exported again.
    private func reopen(_ i: Int) {
        switch items[i].status {
        case .done, .failed: items[i].status = .ready
        case .ready, .working: break
        }
    }

    // MARK: Finding

    /// Adds regions for faces, text or sensitive lines to the selected image, or to every image. Regions already there stay.
    func find(_ kind: RedactFind) {
        guard !isBusy else { return }
        let targets = scope == .allImages ? items : (selected.map { [$0] } ?? [])
        guard !targets.isEmpty else { return }
        finding = kind
        findMessage = nil
        task = Task {
            var added = 0, images = 0, failed = 0
            for target in targets {
                if Task.isCancelled { break }
                let url = target.url
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[CGRect], Error> in
                    Result { try RedactImage.find(kind, in: url) }
                }.value
                switch outcome {
                case .success(let boxes):
                    let n = merge(boxes, into: target.id)
                    added += n
                    if n > 0 { images += 1 }
                case .failure(let error):
                    failed += 1
                    Log.error("Find failed", category: "redact-image", ["kind": kind.rawValue, "reason": "\((error as NSError).domain) \((error as NSError).code)"])
                }
            }
            Log.info("Regions found", category: "redact-image", ["kind": kind.rawValue, "found": "\(added)", "images": "\(targets.count)"])
            if !Task.isCancelled { findMessage = summary(kind, added: added, images: images, of: targets.count, failed: failed) }
            finding = nil
        }
    }

    /// Adds the boxes that are not already covered. Returns how many were added.
    private func merge(_ boxes: [CGRect], into id: UUID) -> Int {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return 0 }
        var added = 0
        for box in boxes where !items[i].regions.contains(where: { RedactImage.overlaps($0.rect, box) }) {
            items[i].regions.append(Region(rect: box))
            added += 1
        }
        if added > 0 { reopen(i) }
        return added
    }

    private func summary(_ kind: RedactFind, added: Int, images: Int, of total: Int, failed: Int) -> String {
        var text = added == 0 ? kind.nothing : "Added \(kind.count(added))"
        if added > 0, total > 1 { text += " in \(images) of \(total) images" }
        if failed > 0 { text += ". \(failed) image\(failed == 1 ? "" : "s") could not be searched" }
        return text + "."
    }

    // MARK: Exporting

    /// Saves a copy of every image that has regions, with them covered, into one new dated folder in Downloads.
    func export() {
        guard !isBusy, hasExportable else { return }
        isRunning = true
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Redacted Images")
        self.folder = folder
        let settings = self.settings
        let work = items.filter(\.isExportable).map { (id: $0.id, url: $0.url, rects: $0.rects) }
        task = Task {
            for job in work {
                if Task.isCancelled { break }
                update(job.id, .working)
                // Decoding and encoding are heavy; keep them off the main thread.
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<RedactResult, Error> in
                    Result { try RedactImage.save(source: job.url, regions: job.rects, settings: settings, into: folder) }
                }.value
                switch outcome {
                case .success(let result):
                    update(job.id, .done(result))
                    Log.info("Image redacted", category: "redact-image", ["regions": "\(result.regions)", "style": settings.style.rawValue,
                                                                       "removeMetadata": "\(settings.removeMetadata)"])
                case .failure(let error):
                    update(job.id, .failed(error.localizedDescription))
                    Log.error("Redaction failed", category: "redact-image", ["style": settings.style.rawValue, "reason": "\((error as NSError).domain) \((error as NSError).code)"])
                }
            }
            for i in items.indices where items[i].status == .working { items[i].status = .ready }
            isRunning = false
        }
    }

    func cancel() { task?.cancel() }

    private func update(_ id: UUID, _ status: Status) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].status = status
    }

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func revealFolder() { if let folder { NSWorkspace.shared.open(folder) } }
}
