import AppKit
import Observation

@MainActor @Observable
final class EjectAllDisksModel {
    static let shared = EjectAllDisksModel()

    enum Status: Equatable {
        case ready, ejecting, ejected
        case failed(String)
    }

    private(set) var volumes: [VolumeInfo] = []
    private(set) var status: [String: Status] = [:]
    private(set) var isScanning = false
    private var observers: [NSObjectProtocol] = []

    private let scan: () async -> [VolumeInfo]
    private let eject: (URL) async throws -> Void

    init(scan: @escaping () async -> [VolumeInfo] = { await VolumeScanner.ejectableVolumes(diskImages: VolumeScanner.diskImages()) },
         eject: @escaping (URL) async throws -> Void = EjectAllDisksModel.systemEject) {
        self.scan = scan
        self.eject = eject
    }

    /// The call blocks until the disk is unmounted (or fails because it is busy), so it runs off the main thread.
    nonisolated static func systemEject(_ url: URL) async throws {
        try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }.value
    }

    var remaining: [VolumeInfo] { volumes.filter { status[$0.id] != .ejected } }
    var isEjecting: Bool { status.values.contains(.ejecting) }

    func startWatching() {
        guard observers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isEjecting == false { self?.refresh() } }
            })
        }
    }

    func refresh() {
        isScanning = true
        Task {
            let found = await scan()
            volumes = found
            status = status.filter { key, _ in found.contains { $0.id == key } }
            isScanning = false
        }
    }

    /// Ejects each volume in turn; one that is busy does not stop the rest.
    func ejectAll() {
        let targets = remaining
        Task {
            for volume in targets {
                status[volume.id] = .ejecting
                do {
                    try await eject(volume.url)
                    status[volume.id] = .ejected
                } catch {
                    status[volume.id] = .failed("In use. Close the files or apps using it, then try again.")
                }
            }
            Log.info("Eject all finished", category: "eject", ["count": String(targets.count)])
        }
    }
}
