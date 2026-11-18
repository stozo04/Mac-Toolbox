import AppKit
import Observation

@MainActor @Observable
final class BlurFacesModel: BatchQueueModel {
    /// Shared so the queue survives switching to another tool and back.
    static let shared = BlurFacesModel()

    enum Status: BatchStatus {
        /// Looking for faces; the photo can't be previewed yet.
        case detecting
        /// Faces are known; waiting for Blur Faces.
        case ready
        case blurring
        case done(FaceBlurResult)
        case failed(String)

        static var waiting: Status { .ready }

        var isFailed: Bool { if case .failed = self { true } else { false } }
    }

    struct Face: Identifiable, Equatable {
        let id = UUID()
        /// Normalized to the upright photo, origin at the bottom left.
        let box: CGRect
        /// Off means this face stays visible.
        var isIncluded = true
    }

    struct Item: BatchItem {
        let id = UUID()
        let url: URL
        let bytes: Int64
        var status = Status.detecting
        var faces: [Face] = []

        var name: String { url.lastPathComponent }
        var includedBoxes: [CGRect] { faces.filter(\.isIncluded).map(\.box) }
    }

    let queue: BatchQueue<Item>

    init(outputParent: URL? = nil) {
        queue = BatchQueue(BatchTool(outputFolderName: "Toolbox Blurred Photos", logCategory: "blur-faces", failureLog: "Face blur failed",
                                     skippedBecause: "had no images", files: BatchFiles.images), outputParent: outputParent)
    }

    var selectedID: UUID?

    var settings = FaceBlurSettings()

    private var detector: Task<Void, Never>?

    var hasPending: Bool { queue.hasWaiting }
    var isDetecting: Bool { items.contains { $0.status == .detecting } }
    var selected: Item? { items.first { $0.id == selectedID } }
    var doneCount: Int { items.filter { if case .done = $0.status { true } else { false } }.count }
    /// Photos where at least one face was hidden.
    var hiddenCount: Int {
        items.filter { if case .done(let r) = $0.status { r.facesHidden > 0 } else { false } }.count
    }

    // MARK: Queue

    func add(_ urls: [URL]) {
        queue.add(urls) { Item(url: $0, bytes: BatchFiles.bytes(of: $0)) }
        if selectedID == nil { selectedID = items.first?.id }
        detectFaces()
    }

    func remove(_ id: UUID) {
        guard queue.remove(id) else { return }
        if selectedID == id { selectedID = items.first?.id }
    }

    func clear() {
        queue.clear()
        selectedID = nil
    }

    /// Turns one face on or off for this photo.
    func toggle(_ faceID: UUID, in itemID: UUID) {
        guard !isRunning else { return }
        queue.update(itemID) { item in
            guard let face = item.faces.firstIndex(where: { $0.id == faceID }) else { return }
            item.faces[face].isIncluded.toggle()
        }
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
                    queue.update(item.id) { $0.status = .failed(error.localizedDescription) }
                    Log.error("Face search failed", category: "blur-faces", Log.details(error, file: url))
                }
            }
            detector = nil
        }
    }

    private func setFaces(_ id: UUID, _ boxes: [CGRect]) {
        queue.update(id) {
            $0.faces = boxes.map { Face(box: $0) }
            $0.status = .ready
        }
    }

    // MARK: Hiding faces

    func blur() {
        guard !isDetecting else { return }
        let settings = self.settings
        queue.run(retryingFailed: false, failureContext: ["style": settings.style.rawValue]) { item, folder, step in
            let boxes = item.includedBoxes
            let result = try await step.detached(showing: .blurring) {
                try FaceBlur.save(source: item.url, faces: boxes, settings: settings, into: folder)
            }
            Log.info("Faces hidden", category: "blur-faces", ["faces": "\(result.facesHidden)", "style": settings.style.rawValue])
            return .done(result)
        }
    }
}
