import Foundation

enum VaultDuplicates {
    enum Match: Comparable { case exact, likely }

    struct Group: Identifiable, Equatable {
        let copies: [VaultItem]
        var match: Match = .exact

        var id: String { copies.map(\.id).joined(separator: "|") }
        var bytesEach: Int64 { copies.first?.bytes ?? 0 }
        var totalBytes: Int64 { copies.reduce(0) { $0 + $1.bytes } }
        var extraBytes: Int64 { totalBytes - (copies.map(\.bytes).max() ?? 0) }
        var kind: VaultItem.Kind? { copies.first?.kind }
    }

    static let sameIDLengthTolerance = 2.0
    static let sameLookLengthTolerance = 1.5

    static func groups(in items: [VaultItem], digest: (VaultItem) throws -> Data,
                       durations: [VaultItem: Double] = [:], looks: [VaultItem: VaultLook] = [:]) -> [Group] {
        let usable = items.filter { $0.bytes > 0 }
        var links = Links(count: usable.count)
        let digests = exactDigests(of: usable, digest: digest)
        linkExactCopies(usable, digests: digests, into: &links)
        linkSamePostID(usable, durations: durations, into: &links)
        linkSameLook(usable, durations: durations, looks: looks, into: &links)

        let groups = links.clusters().filter { $0.count > 1 }.map { indexes in
            let copies = indexes.map { usable[$0] }.sorted(by: isOlder)
            return Group(copies: copies, match: isExact(copies, digests: digests) ? .exact : .likely)
        }
        return groups.sorted {
            if $0.match != $1.match { return $0.match < $1.match }
            return $0.extraBytes != $1.extraBytes ? $0.extraBytes > $1.extraBytes : $0.id < $1.id
        }
    }

    static func lookCandidates(in items: [VaultItem], durations: [VaultItem: Double]) -> [VaultItem] {
        let images = items.filter { $0.kind == .image && $0.bytes > 0 }
        let timed = items.compactMap { item -> (item: VaultItem, seconds: Double)? in
            guard item.kind == .video, item.bytes > 0, let seconds = durations[item] else { return nil }
            return (item, seconds)
        }.sorted { $0.seconds < $1.seconds }
        var wanted = Set<VaultItem>()
        for (a, b) in zip(timed, timed.dropFirst()) where b.seconds - a.seconds <= sameLookLengthTolerance {
            wanted.insert(a.item)
            wanted.insert(b.item)
        }
        return images + timed.map(\.item).filter(wanted.contains)
    }

    static func postID(in name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        return bracketedID(in: stem) ?? longNumber(in: stem)
    }

    private static let youTubeIDLength = 11
    private static let numberIDLengths = 15...20

    private static func bracketedID(in stem: String) -> String? {
        stem.split(separator: "[").dropFirst().compactMap { piece -> String? in
            guard let close = piece.firstIndex(of: "]") else { return nil }
            let inside = String(piece[..<close])
            return isNumberID(inside) || isYouTubeID(inside) ? inside : nil
        }.last
    }

    private static func longNumber(in stem: String) -> String? {
        stem.split { !$0.isASCII || !$0.isNumber }.map(String.init).last(where: isNumberID)
    }

    private static func isNumberID(_ text: String) -> Bool {
        numberIDLengths.contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isYouTubeID(_ text: String) -> Bool {
        let scalars = text.unicodeScalars
        let allowed = scalars.allSatisfy { $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-") }
        let hasNonLetter = scalars.contains { CharacterSet.decimalDigits.contains($0) || $0 == "_" || $0 == "-" }
        let hasLetter = scalars.contains { CharacterSet.letters.contains($0) }
        return scalars.count == youTubeIDLength && allowed && hasNonLetter && hasLetter
    }

    /// The keeper and every copy are still there with the same size, so trashing the others can't lose the last copy.
    static func isStillIntact(_ group: Group, keeping keeper: VaultItem) -> Bool {
        guard group.copies.contains(keeper) else { return false }
        return group.copies.allSatisfy { copy in
            let size = (try? FileManager.default.attributesOfItem(atPath: copy.url.path))?[.size] as? NSNumber
            return size?.int64Value == copy.bytes
        }
    }

    static func others(than keeper: VaultItem, in group: Group) -> [VaultItem] {
        group.copies.filter { $0.id != keeper.id }
    }

    static func filtered(_ groups: [Group], by filter: VaultFilter) -> [Group] {
        groups.filter { group in group.copies.first.map(filter.includes) ?? false }
    }

    private static func exactDigests(of items: [VaultItem], digest: (VaultItem) throws -> Data) -> [VaultItem: Data] {
        var digests: [VaultItem: Data] = [:]
        let sameSize = Dictionary(grouping: items, by: \.bytes).values.filter { $0.count > 1 }
        for item in sameSize.joined() {
            if let hash = try? digest(item) { digests[item] = hash }
        }
        return digests
    }

    private static func isExact(_ copies: [VaultItem], digests: [VaultItem: Data]) -> Bool {
        let hashes = copies.map { digests[$0] }
        return hashes.allSatisfy { $0 != nil && $0 == hashes.first! }
    }

    private static func linkExactCopies(_ items: [VaultItem], digests: [VaultItem: Data], into links: inout Links) {
        var firstWithDigest: [Data: Int] = [:]
        for (index, item) in items.enumerated() {
            guard let hash = digests[item] else { continue }
            if let first = firstWithDigest[hash] { links.join(first, index) } else { firstWithDigest[hash] = index }
        }
    }

    private static func linkSamePostID(_ items: [VaultItem], durations: [VaultItem: Double], into links: inout Links) {
        var byID: [String: [Int]] = [:]
        for (index, item) in items.enumerated() where item.kind == .video {
            if let id = postID(in: item.name) { byID[id, default: []].append(index) }
        }
        for indexes in byID.values {
            for (a, b) in pairs(indexes) where lengthsAgree(items[a], items[b], durations) { links.join(a, b) }
        }
    }

    private static func linkSameLook(_ items: [VaultItem], durations: [VaultItem: Double], looks: [VaultItem: VaultLook],
                                     into links: inout Links) {
        let looked = items.indices.filter { looks[items[$0]] != nil }
        for (a, b) in pairs(looked) where items[a].kind == items[b].kind && closeInLength(items[a], items[b], durations) {
            if let first = looks[items[a]], let second = looks[items[b]], first.resembles(second) { links.join(a, b) }
        }
    }

    private static func lengthsAgree(_ a: VaultItem, _ b: VaultItem, _ durations: [VaultItem: Double]) -> Bool {
        guard let first = durations[a], let second = durations[b] else { return true }
        return abs(first - second) <= sameIDLengthTolerance
    }

    private static func closeInLength(_ a: VaultItem, _ b: VaultItem, _ durations: [VaultItem: Double]) -> Bool {
        guard a.kind == .video else { return true }
        guard let first = durations[a], let second = durations[b] else { return false }
        return abs(first - second) <= sameLookLengthTolerance
    }

    private static func pairs(_ indexes: [Int]) -> [(Int, Int)] {
        indexes.indices.flatMap { i in indexes[(i + 1)...].map { (indexes[i], $0) } }
    }

    private static func isOlder(_ a: VaultItem, _ b: VaultItem) -> Bool {
        a.added != b.added ? a.added < b.added : a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

private struct Links {
    private var parent: [Int]

    init(count: Int) { parent = Array(0..<count) }

    mutating func join(_ a: Int, _ b: Int) {
        let rootA = root(a), rootB = root(b)
        if rootA != rootB { parent[max(rootA, rootB)] = min(rootA, rootB) }
    }

    mutating func clusters() -> [[Int]] {
        var byRoot: [Int: [Int]] = [:]
        for index in parent.indices { byRoot[root(index), default: []].append(index) }
        return Array(byRoot.values)
    }

    private mutating func root(_ index: Int) -> Int {
        var current = index
        while parent[current] != current {
            parent[current] = parent[parent[current]]
            current = parent[current]
        }
        return current
    }
}
