import Foundation

extension VaultModel {
    enum Phase: Equatable { case setup, locked, opening, open }

    enum Mode: String, CaseIterable, Identifiable {
        case library, duplicates

        var id: Self { self }
        var title: String { self == .library ? "Library" : "Duplicates" }
    }

    enum SearchState: Equatable {
        case off
        case needsModel
        case downloading(Double)
        case indexing(done: Int, total: Int)
        case ready(unreadable: Int)
        case failed(String)
    }

    struct MoveProgress: Equatable {
        var done: Int
        var total: Int
    }

    func volumeDidUnmount(_ volume: URL?) {
        guard volume?.resolvingSymlinksInPath().path == root.resolvingSymlinksInPath().path else { return }
        lockIfClosedFromOutside()
    }

    func addDebugFiles() {
        #if DEBUG
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--vault-debug-add"), flag + 1 < arguments.count else { return }
        let folder = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        add([folder])
        #endif
    }
}
