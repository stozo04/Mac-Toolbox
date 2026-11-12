import AVFoundation
import Foundation

enum VaultFilter: String, CaseIterable, Identifiable {
    case all, images, videos

    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .images: "Images"
        case .videos: "Videos"
        }
    }

    var emptyMessage: String {
        switch self {
        case .all: "Your vault is empty"
        case .images: "No images in the vault"
        case .videos: "No videos in the vault"
        }
    }

    func includes(_ item: VaultItem) -> Bool {
        switch self {
        case .all: true
        case .images: item.kind == .image
        case .videos: item.kind == .video
        }
    }
}

enum VaultVideoOrder: String, CaseIterable, Identifiable {
    case newest, shortest, longest

    var id: Self { self }

    var title: String {
        switch self {
        case .newest: "Newest first"
        case .shortest: "Shortest first"
        case .longest: "Longest first"
        }
    }
}

enum VaultBrowse {
    private static let parallelLoads = 8

    static func arranged(_ items: [VaultItem], filter: VaultFilter, order: VaultVideoOrder,
                         durations: [VaultItem: Double]) -> [VaultItem] {
        let shown = items.filter(filter.includes)
        guard filter == .videos, order != .newest else { return shown }
        let known = shown.filter { durations[$0] != nil }
        let unknown = shown.filter { durations[$0] == nil }
        let byLength = known.enumerated().sorted { first, second in
            let a = durations[first.element] ?? 0, b = durations[second.element] ?? 0
            if a == b { return first.offset < second.offset }
            return order == .shortest ? a < b : a > b
        }
        return byLength.map(\.element) + unknown
    }

    static func lengthLabel(for item: VaultItem, durations: [VaultItem: Double]) -> String? {
        guard item.kind == .video, let seconds = durations[item] else { return nil }
        return VaultTime.label(seconds)
    }

    static func duration(of url: URL) async -> Double? {
        guard let seconds = try? await AVURLAsset(url: url).load(.duration).seconds,
              seconds.isFinite, seconds > 0 else { return nil }
        return seconds
    }

    static func durations(of videos: [VaultItem]) async -> [VaultItem: Double] {
        await withTaskGroup(of: (VaultItem, Double?).self) { group in
            var found: [VaultItem: Double] = [:]
            var pending = videos.makeIterator()
            for _ in 0..<parallelLoads {
                guard let item = pending.next() else { break }
                group.addTask { (item, await duration(of: item.url)) }
            }
            for await (item, seconds) in group {
                if let seconds { found[item] = seconds }
                if !Task.isCancelled, let next = pending.next() {
                    group.addTask { (next, await duration(of: next.url)) }
                }
            }
            return found
        }
    }
}
