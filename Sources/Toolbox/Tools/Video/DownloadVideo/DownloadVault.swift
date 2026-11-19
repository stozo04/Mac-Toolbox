import Foundation

/// The part of the vault Download Video uses, so its tests can stand in for the encrypted disk.
@MainActor
protocol DownloadVault: AnyObject {
    var acceptsFiles: Bool { get }
    func moveIn(_ file: URL) async throws -> URL
    func makeSearchable(_ file: URL) async -> Bool
}

extension VaultModel: DownloadVault {
    var acceptsFiles: Bool { phase == .open && !isLocking }
}

/// What happened to the downloads on their way into the vault, for the footer.
struct VaultSendReport: Equatable {
    var moved = 0
    var failed = 0
    var notSearchable = 0
}
