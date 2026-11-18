import SwiftUI
import UniformTypeIdentifiers

enum FileDrop {
    typealias Loader = (@escaping @Sendable (URL?) -> Void) -> Void

    static func collect(from loaders: [Loader], deliver: @escaping @MainActor ([URL]) -> Void) {
        let collector = Collector(count: loaders.count, deliver: deliver)
        for (index, load) in loaders.enumerated() {
            load { collector.loaded($0, at: index) }
        }
    }

    static func loader(for provider: NSItemProvider) -> Loader {
        { done in _ = provider.loadObject(ofClass: URL.self) { url, _ in done(url) } }
    }

    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var urls: [URL?]
        private var waitingFor: Set<Int>
        private let deliver: @MainActor ([URL]) -> Void

        init(count: Int, deliver: @escaping @MainActor ([URL]) -> Void) {
            urls = Array(repeating: nil, count: count)
            waitingFor = Set(0..<count)
            self.deliver = deliver
        }

        func loaded(_ url: URL?, at index: Int) {
            guard let dropped = record(url, at: index), !dropped.isEmpty else { return }
            Task { @MainActor in deliver(dropped) }
        }

        private func record(_ url: URL?, at index: Int) -> [URL]? {
            lock.lock(); defer { lock.unlock() }
            guard waitingFor.remove(index) != nil else { return nil }
            urls[index] = url
            return waitingFor.isEmpty ? urls.compactMap { $0 } : nil
        }
    }
}

extension View {
    func fileDrop(isTargeted: Binding<Bool>? = nil, perform: @escaping @MainActor ([URL]) -> Void) -> some View {
        onDrop(of: [.fileURL], isTargeted: isTargeted) { providers in
            FileDrop.collect(from: providers.map(FileDrop.loader), deliver: perform)
            return !providers.isEmpty
        }
    }
}
