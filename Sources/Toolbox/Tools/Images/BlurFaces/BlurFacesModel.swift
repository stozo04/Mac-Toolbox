import AppKit
import Observation

@MainActor @Observable
final class BlurFacesModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = BlurFacesModel()

    enum Status: Equatable {
        /// Looking for faces; the photo can't be previewed yet.
        case detecting
        /// Faces are known; waiting for Blur Faces.
        case ready
        case blurring
        case done(FaceBlurResult)
        case failed(String)
    }

    struct Face: Identifiable, Equatable {
        let id = UUID()
        /// Normalized to the upright photo, origin at the bottom left.
        let box: CGRect
        /// Off means this face stays visible.
        var isIncluded = true
    }

    struct Item: Identifiable {
        let id = UUID()
        let url: URL
        let bytes: Int64
        var status = Status.detecting
        var faces: [Face] = []

        var name: String { url.lastPathComponent }
        var includedBoxes: [CGRect] { faces.filter(\.isIncluded).map(\.box) }
    }

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var folder: URL?
    private(set) var notice: String?
    var selectedID: UUID?

    var settings = FaceBlurSettings()

    private var detector: Task<Void, Never>?
    private var task: Task<Void, Never>?

    var hasItems: Bool { !items.isEmpty }
    var hasPending: Bool { items.contains { $0.status == .ready } }
    var isDetecting: Bool { items.contains { $0.status == .detecting } }
    var selected: Item? { items.first { $0.id == selectedID } }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }
    /// Photos where at least one face was hidden.
    var hiddenCount: Int {
        items.filter { if case .done(let r) = $0.status { r.facesHidden > 0 } else { false } }.count
    }

    // MARK: Queue

    /// Adds photos; folders are searched for images inside them. Faces are looked for in the background.
    func add(_ urls: [URL]) {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let before = found.count
            found += BatchFiles.images(in: url)
            if found.count == before { skipped += 1 }
        }
        var known = Set(items.map { BatchFiles.identity($0.url) })
        items += found.filter { known.insert(BatchFiles.identity($0)).inserted }.map {
            Item(url: $0, bytes: Int64((try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0))
        }
        if selectedID == nil { selectedID = items.first?.id }
        notice = skipped == 0 ? nil : "\(skipped) item(s) had no images and were skipped."
        detectFaces()
    }

    func remove(_ id: UUID) {
        guard !isRunning else { return }
        items.removeAll { $0.id == id }
        if selectedID == id { selectedID = items.first?.id }
    }

    func clear() {
        task?.cancel()
        items = []
        selectedID = nil
        folder = nil
        notice = nil
        isRunning = false
    }

    /// Turns one face on or off for this photo.
    func toggle(_ faceID: UUID, in itemID: UUID) {
        guard !isRunning, let i = items.firstIndex(where: { $0.id == itemID }),
              let f = items[i].faces.firstIndex(where: { $0.id == faceID }) else { return }
        items[i].faces[f].isIncluded.toggle()
    }

    // MARK: Finding faces

    private func detectFaces() {
        guard detector == nil else { return }
        detector = Task {
            while let item = items.first(where: { $0.status == .detecting }) {
                let url = item.url
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[CGRect], Error> in
                    Result { try FaceBlur.detectFaces(in: url) }
                }.value
                switch outcome {
                case .success(let boxes):
                    setFaces(item.id, boxes)
                    Log.info("Faces found", category: "blur-faces", ["faces": "\(boxes.count)"])
                case .failure(let error):
                    update(item.id, .failed(error.localizedDescription))
                    Log.error("Face search failed", category: "blur-faces", Log.details(error, file: url))
                }
            }
            detector = nil
        }
    }

    private func setFaces(_ id: UUID, _ boxes: [CGRect]) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].faces = boxes.map { Face(box: $0) }
        items[i].status = .ready
    }

    // MARK: Hiding faces

    /// Saves a copy of every ready photo with its included faces hidden, into one new dated folder in Downloads.
    func blur() {
        guard !isRunning, hasPending, !isDetecting else { return }
        isRunning = true
        let folder = self.folder ?? BatchFiles.makeOutputFolder(named: "Toolbox Blurred Photos")
        self.folder = folder
        let settings = self.settings
        let work = items.filter { $0.status == .ready }.map { (id: $0.id, url: $0.url, boxes: $0.includedBoxes) }
        task = Task {
            for job in work {
                if Task.isCancelled { break }
                update(job.id, .blurring)
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<FaceBlurResult, Error> in
                    Result { try FaceBlur.save(source: job.url, faces: job.boxes, settings: settings, into: folder) }
                }.value
                switch outcome {
                case .success(let result):
                    update(job.id, .done(result))
                    Log.info("Faces hidden", category: "blur-faces", ["faces": "\(result.facesHidden)", "style": settings.style.rawValue])
                case .failure(let error):
                    update(job.id, .failed(error.localizedDescription))
                    Log.error("Face blur failed", category: "blur-faces", Log.details(error, file: job.url, ["style": settings.style.rawValue]))
                }
            }
            for i in items.indices where items[i].status == .blurring { items[i].status = .ready }
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
