import AppKit
import Observation

@MainActor @Observable
final class RedactImageModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = RedactImageModel()

    enum Status: BatchStatus {
        case ready
        case working
        case done(RedactResult)
        case failed(String)

        static var waiting: Status { .ready }

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Region: Identifiable, Equatable {
        let id = UUID()
        /// Normalized to the upright image, origin at the top left.
        var rect: CGRect
        var coversFoundText = false
    }

    struct Item: BatchItem {
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

    let queue: BatchQueue<Item>

    init(outputParent: URL? = nil) {
        let tool = BatchTool(outputFolderName: "Toolbox Redacted Images", logCategory: "redact-image", failureLog: "Redaction failed",
                             skippedBecause: "were not images macOS can read, or were animated,", files: BatchFiles.images)
        queue = BatchQueue(tool, outputParent: outputParent)
    }

    private(set) var finding: RedactFind?
    /// What the last Find & Cover did.
    private(set) var findMessage: String?
    var selectedID: UUID?
    var selectedRegionID: UUID?

    var settings = RedactSettings()
    private(set) var styleWasChosen = false
    var scope = Scope.thisImage

    private var findTask: Task<Void, Never>?
    private var findRun = UUID()
    private var thumbnailer: Task<Void, Never>?

    var selected: Item? { items.first { $0.id == selectedID } }
    var isBusy: Bool { isRunning || finding != nil }
    var hasExportable: Bool { items.contains { $0.isExportable } }
    var doneCount: Int { items.filter(\.isDone).count }
    /// Images with nothing covered, which Export leaves out.
    var untouchedCount: Int { items.filter { $0.regions.isEmpty }.count }
    var regionCount: Int { items.reduce(0) { $0 + $1.regions.count } }
    var needsRecoverableTextCaution: Bool {
        settings.style != .blackBox && items.contains { $0.regions.contains(where: \.coversFoundText) }
    }

    func chooseStyle(_ style: RedactStyle) {
        apply(style)
        styleWasChosen = true
    }

    private func apply(_ style: RedactStyle) {
        guard settings.style != style else { return }
        settings.style = style
        for item in items where !item.regions.isEmpty { queue.update(item.id, Self.reopen) }
    }

    // MARK: Queue

    func add(_ urls: [URL]) {
        queue.add(urls) { url in
            RedactImage.inspect(url).map { Item(url: url, bytes: BatchFiles.bytes(of: url), size: $0) }
        }
        if selectedID == nil || selected == nil { select(items.first?.id) }
        loadThumbnails()
    }

    func remove(_ id: UUID) {
        guard !isBusy, queue.remove(id) else { return }
        if selectedID == id { select(items.first?.id) }
    }

    func clear() {
        findTask?.cancel()
        findRun = UUID()
        queue.clear()
        selectedID = nil
        selectedRegionID = nil
        findMessage = nil
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
                // Without a thumbnail the loop would find this image again forever.
                queue.update(item.id) { $0.thumbnail = image ?? Self.placeholder }
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
        guard !isBusy, let item = selected else { return nil }
        let region = Region(rect: RedactImage.fitted(rect))
        queue.update(item.id) {
            $0.regions.append(region)
            Self.reopen(&$0)
        }
        selectedRegionID = region.id
        return region.id
    }

    func setRect(_ rect: CGRect, of regionID: UUID) {
        guard !isBusy, let item = selected, item.regions.contains(where: { $0.id == regionID }) else { return }
        queue.update(item.id) {
            guard let index = $0.regions.firstIndex(where: { $0.id == regionID }) else { return }
            $0.regions[index].rect = RedactImage.fitted(rect)
            Self.reopen(&$0)
        }
    }

    /// Removes the selected region.
    func deleteSelectedRegion() {
        guard !isBusy, let item = selected, let id = selectedRegionID else { return }
        queue.update(item.id) {
            $0.regions.removeAll { $0.id == id }
            Self.reopen(&$0)
        }
        selectedRegionID = nil
    }

    /// Removes every region from the selected image.
    func clearRegions() {
        guard !isBusy, let item = selected, !item.regions.isEmpty else { return }
        queue.update(item.id) {
            $0.regions = []
            Self.reopen(&$0)
        }
        selectedRegionID = nil
    }

    /// A saved or failed image whose regions change has to be exported again.
    private static func reopen(_ item: inout Item) {
        switch item.status {
        case .done, .failed: item.status = .ready
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
        let run = UUID()
        findRun = run
        findTask = Task {
            var added = 0, images = 0, failed = 0
            for target in targets {
                if Task.isCancelled || findRun != run { break }
                let url = target.url
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[CGRect], Error> in
                    Result { try RedactImage.find(kind, in: url) }
                }.value
                switch outcome {
                case .success(let boxes):
                    let n = merge(boxes, into: target.id, areText: kind != .faces)
                    added += n
                    if n > 0 { images += 1 }
                case .failure(let error):
                    failed += 1
                    Log.error("Find failed", category: "redact-image", Log.details(error, file: url, ["kind": kind.rawValue]))
                }
            }
            guard findRun == run else { return }
            Log.info("Regions found", category: "redact-image", ["kind": kind.rawValue, "found": "\(added)", "images": "\(targets.count)"])
            if !Task.isCancelled { findMessage = summary(kind, added: added, images: images, of: targets.count, failed: failed) }
            finding = nil
        }
    }

    /// Adds the boxes that are not already covered. Returns how many were added.
    private func merge(_ boxes: [CGRect], into id: UUID, areText: Bool) -> Int {
        var added = 0
        var coversFoundText = false
        queue.update(id) { item in
            for box in boxes {
                let covering = item.regions.indices.filter { RedactImage.overlaps(item.regions[$0].rect, box) }
                if covering.isEmpty {
                    item.regions.append(Region(rect: box, coversFoundText: areText))
                    added += 1
                } else if areText {
                    for index in covering { item.regions[index].coversFoundText = true }
                }
                coversFoundText = coversFoundText || areText
            }
            if added > 0 { Self.reopen(&item) }
        }
        // Blurred or pixelated text can sometimes be made out again; a black box cannot.
        if added > 0 || coversFoundText, !styleWasChosen { apply(.blackBox) }
        return added
    }

    private func summary(_ kind: RedactFind, added: Int, images: Int, of total: Int, failed: Int) -> String {
        var text = added == 0 ? kind.nothing : "Added \(kind.count(added))"
        if added > 0, total > 1 { text += " in \(images) of \(total) images" }
        if failed > 0 { text += ". \(failed) image\(failed == 1 ? "" : "s") could not be searched" }
        return text + "."
    }

    // MARK: Exporting

    func export() {
        guard !isBusy, hasExportable else { return }
        let settings = self.settings
        queue.run(retryingFailed: false, failureContext: ["style": settings.style.rawValue], where: \.isExportable) { item, folder, step in
            let rects = item.rects
            let result = try await step.detached(showing: .working) {
                try RedactImage.save(source: item.url, regions: rects, settings: settings, into: folder)
            }
            Log.info("Image redacted", category: "redact-image", ["regions": "\(result.regions)", "style": settings.style.rawValue,
                                                               "removeMetadata": "\(settings.removeMetadata)"])
            return .done(result)
        }
    }

    func cancel() {
        findTask?.cancel()
        queue.cancel()
    }
}
