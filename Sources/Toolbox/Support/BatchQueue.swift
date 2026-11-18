import AppKit
import Observation

protocol BatchStatus: Equatable {
    static var waiting: Self { get }
    static func failed(_ message: String) -> Self
    var isFailed: Bool { get }
}

protocol BatchItem: Identifiable where ID == UUID {
    associatedtype QueueStatus: BatchStatus
    var url: URL { get }
    var status: QueueStatus { get set }
}

struct BatchTool {
    let outputFolderName: String
    let logCategory: String
    let failureLog: String
    let skippedBecause: String
    let files: (URL) -> [URL]
}

@MainActor @Observable
final class BatchQueue<Item: BatchItem> {
    typealias Work = @MainActor (Item, URL, Step) async throws -> Item.QueueStatus

    private(set) var items: [Item] = []
    private(set) var isRunning = false
    private(set) var folder: URL?
    var notice: String?

    @ObservationIgnored private let tool: BatchTool
    @ObservationIgnored private let outputParent: URL?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = UUID()
    @ObservationIgnored private var phase = UUID()

    init(_ tool: BatchTool, outputParent: URL? = nil) {
        self.tool = tool
        self.outputParent = outputParent
    }

    var hasItems: Bool { !items.isEmpty }
    var hasWaiting: Bool { items.contains { $0.status == .waiting } }

    func item(_ id: UUID) -> Item? { items.first { $0.id == id } }

    // MARK: Files

    @discardableResult
    func add(_ urls: [URL], make: (URL) -> Item?) -> [Item] {
        var found: [URL] = []
        var skipped = 0
        for url in urls {
            let files = tool.files(url)
            if files.isEmpty { skipped += 1 }
            found += files
        }
        var known = Set(items.map { BatchFiles.identity($0.url) })
        var added: [Item] = []
        for url in found where known.insert(BatchFiles.identity(url)).inserted {
            if let item = make(url) { added.append(item) } else { skipped += 1 }
        }
        items += added
        notice = skipped == 0 ? nil : "\(skipped) item(s) \(tool.skippedBecause) and were skipped."
        return added
    }

    @discardableResult
    func remove(_ id: UUID) -> Bool {
        guard !isRunning, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items.remove(at: index)
        return true
    }

    func remove(where shouldRemove: (Item) -> Bool) {
        guard !isRunning else { return }
        items.removeAll(where: shouldRemove)
    }

    func clear() {
        task?.cancel()
        runID = UUID()
        phase = UUID()
        items = []
        folder = nil
        notice = nil
        isRunning = false
    }

    func update(_ id: UUID, _ change: (inout Item) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    // MARK: Running

    struct Step {
        fileprivate let queue: BatchQueue
        fileprivate let id: UUID
        fileprivate let run: UUID

        @MainActor func set(_ status: Item.QueueStatus) {
            queue.begin(status, for: id, in: run)
        }

        @MainActor func progress(_ status: @escaping @Sendable (Double) -> Item.QueueStatus) -> @Sendable (Double) -> Void {
            let phase = queue.begin(status(0), for: id, in: run)
            return { [queue, id] fraction in
                Task { @MainActor in queue.report(status(fraction), for: id, in: phase) }
            }
        }
    }

    @discardableResult
    func run(retryingFailed: Bool = true, failureContext: [String: String] = [:],
             where isPending: (Item) -> Bool = { $0.status == .waiting }, work: @escaping Work) -> Bool {
        guard !isRunning, items.contains(where: isPending), let folder = outputFolder() else { return false }
        isRunning = true
        if retryingFailed {
            for index in items.indices where items[index].status.isFailed { items[index].status = .waiting }
        }
        let ids = items.filter(isPending).map(\.id)
        let run = UUID()
        runID = run
        task = Task { [weak self] in
            guard let self else { return }
            await process(ids, in: run, into: folder, failureContext: failureContext, work: work)
        }
        return true
    }

    func cancel() { task?.cancel() }

    private func outputFolder() -> URL? {
        do {
            let folder = try self.folder ?? BatchFiles.makeOutputFolder(named: tool.outputFolderName, in: outputParent)
            self.folder = folder
            notice = OutputFolderError.clearing(notice)
            return folder
        } catch {
            notice = error.localizedDescription
            Log.error("Output folder failed", category: tool.logCategory, Log.details(error))
            return nil
        }
    }

    private func process(_ ids: [UUID], in run: UUID, into folder: URL, failureContext: [String: String], work: @escaping Work) async {
        for id in ids {
            if Task.isCancelled || runID != run { break }
            guard let item = item(id) else { continue }
            let status = await outcome(of: work, on: item, into: folder, in: run, failureContext: failureContext)
            guard runID == run else { return }
            phase = UUID()
            update(id) { $0.status = status }
        }
        guard runID == run else { return }
        isRunning = false
    }

    private func outcome(of work: @escaping Work, on item: Item, into folder: URL, in run: UUID,
                         failureContext: [String: String]) async -> Item.QueueStatus {
        do {
            return try await work(item, folder, Step(queue: self, id: item.id, run: run))
        } catch is CancellationError {
            return .waiting
        } catch {
            Log.error(tool.failureLog, category: tool.logCategory, Log.details(error, file: item.url, failureContext))
            return .failed(error.localizedDescription)
        }
    }

    @discardableResult
    private func begin(_ status: Item.QueueStatus, for id: UUID, in run: UUID) -> UUID? {
        guard runID == run else { return nil }
        let phase = UUID()
        self.phase = phase
        update(id) { $0.status = status }
        return phase
    }

    private func report(_ status: Item.QueueStatus, for id: UUID, in phase: UUID?) {
        guard let phase, self.phase == phase else { return }
        update(id) { $0.status = status }
    }

    // MARK: Finder

    func reveal(_ url: URL) { NSWorkspace.shared.activateFileViewerSelecting([url]) }

    func revealFolder() { if let folder { NSWorkspace.shared.open(folder) } }
}

@MainActor
protocol BatchQueueModel {
    associatedtype Item: BatchItem
    var queue: BatchQueue<Item> { get }
}

extension BatchQueueModel {
    var items: [Item] { queue.items }
    var isRunning: Bool { queue.isRunning }
    var folder: URL? { queue.folder }
    var notice: String? { queue.notice }
    var hasItems: Bool { queue.hasItems }

    func remove(_ id: UUID) { queue.remove(id) }
    func clear() { queue.clear() }
    func cancel() { queue.cancel() }
    func reveal(_ url: URL) { queue.reveal(url) }
    func revealFolder() { queue.revealFolder() }
}
