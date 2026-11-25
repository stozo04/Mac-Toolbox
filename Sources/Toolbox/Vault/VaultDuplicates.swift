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

    /// Two files one of the link rules says are the same.
    struct Pair: Hashable {
        let first: VaultItem
        let second: VaultItem
        let match: Match
    }

    static let sameIDLengthTolerance = 2.0
    static let sameLookLengthTolerance = 1.5

    static func groups(in items: [VaultItem], digest: (VaultItem) throws -> Data,
                       durations: [VaultItem: Double] = [:], looks: [VaultItem: VaultLook] = [:],
                       isRemembered: (Pair) -> Bool = { _ in false }) -> [Group] {
        let found = pairs(in: items, digest: digest, durations: durations, looks: looks)
        return groups(joining: found.pairs.filter { !isRemembered($0) }, digests: found.digests)
    }

    /// Every pair the rules find. With `touching`, only pairs that include one of those files, and only the files that
    /// could pair with one of them are hashed.
    static func pairs(in items: [VaultItem], digest: (VaultItem) throws -> Data, durations: [VaultItem: Double] = [:],
                      looks: [VaultItem: VaultLook] = [:],
                      touching: Set<VaultItem>? = nil) -> (pairs: [Pair], digests: [VaultItem: Data]) {
        let usable = items.filter { $0.bytes > 0 }
        let digests = exactDigests(of: usable, touching: touching, digest: digest)
        var found = exactPairs(usable, digests: digests)
        found += samePostIDPairs(usable, durations: durations)
        found += sameLookPairs(usable, durations: durations, looks: looks)
        var seen = Set<Set<VaultItem>>()
        let unique = found.filter { pair in
            guard touching.map({ $0.contains(pair.first) || $0.contains(pair.second) }) ?? true else { return false }
            return seen.insert([pair.first, pair.second]).inserted
        }
        return (unique, digests)
    }

    /// Joins pairs into sets: two pairs that share a file are one set.
    static func groups(joining pairs: [Pair], digests: [VaultItem: Data]) -> [Group] {
        let members = Array(Set(pairs.flatMap { [$0.first, $0.second] }))
        let index = Dictionary(uniqueKeysWithValues: members.enumerated().map { ($1, $0) })
        var links = Links(count: members.count)
        for pair in pairs {
            if let a = index[pair.first], let b = index[pair.second] { links.join(a, b) }
        }
        let groups = links.clusters().filter { $0.count > 1 }.map { indexes in
            let copies = indexes.map { members[$0] }.sorted(by: isOlder)
            return Group(copies: copies, match: isExact(copies, digests: digests) ? .exact : .likely)
        }
        return groups.sorted {
            if $0.match != $1.match { return $0.match < $1.match }
            return $0.extraBytes != $1.extraBytes ? $0.extraBytes > $1.extraBytes : $0.id < $1.id
        }
    }

    static func lookCandidates(in items: [VaultItem], durations: [VaultItem: Double],
                               near anchors: Set<VaultItem>? = nil) -> [VaultItem] {
        let wantsImages = anchors.map { $0.contains { $0.kind == .image } } ?? true
        let images = wantsImages ? items.filter { $0.kind == .image && $0.bytes > 0 } : []
        let timed = items.compactMap { item -> (item: VaultItem, seconds: Double)? in
            guard item.kind == .video, item.bytes > 0, let seconds = durations[item] else { return nil }
            return (item, seconds)
        }.sorted { $0.seconds < $1.seconds }
        var wanted = Set<VaultItem>()
        if let anchors {
            let anchorLengths = timed.filter { anchors.contains($0.item) }.map(\.seconds)
            for entry in timed where anchorLengths.contains(where: { abs($0 - entry.seconds) <= sameLookLengthTolerance }) {
                wanted.insert(entry.item)
            }
        } else {
            for (a, b) in zip(timed, timed.dropFirst()) where b.seconds - a.seconds <= sameLookLengthTolerance {
                wanted.insert(a.item)
                wanted.insert(b.item)
            }
        }
        return images + timed.map(\.item).filter(wanted.contains)
    }

    static func postID(in name: String) -> String? {
        let stem = (name as NSString).deletingPathExtension
        return bracketed(in: stem).last(where: isNumberID) ?? longNumber(in: stem) ?? trailingYouTubeID(in: stem)
    }

    private static let youTubeIDLength = 11
    private static let minimumLetterDigitSwitches = 2
    private static let numberIDLengths = 15...20

    private static func bracketed(in stem: String) -> [String] {
        stem.split(separator: "[").dropFirst().compactMap { piece in
            piece.firstIndex(of: "]").map { String(piece[..<$0]) }
        }
    }

    private static func longNumber(in stem: String) -> String? {
        stem.split { !$0.isASCII || !$0.isNumber }.map(String.init).last(where: isNumberID)
    }

    private static func trailingYouTubeID(in stem: String) -> String? {
        let trimmed = stem.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix("]"), let last = bracketed(in: trimmed).last, trimmed.hasSuffix("[\(last)]"),
              isYouTubeID(last) else { return nil }
        return last
    }

    private static func isNumberID(_ text: String) -> Bool {
        numberIDLengths.contains(text.count) && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func isYouTubeID(_ text: String) -> Bool {
        let allowed = text.count == youTubeIDLength && text.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-")
        }
        let switches = text.split { $0 == "-" || $0 == "_" }.reduce(0) { total, piece in
            let classes = piece.map(\.isNumber)
            return total + zip(classes, classes.dropFirst()).filter { $0 != $1 }.count
        }
        return allowed && switches >= minimumLetterDigitSwitches
    }

    /// Every copy is still there with the size it had when compared, so acting on the set can't lose the last copy.
    static func isStillIntact(_ copies: [VaultItem]) -> Bool {
        copies.allSatisfy { copy in
            let size = (try? FileManager.default.attributesOfItem(atPath: copy.url.path))?[.size] as? NSNumber
            return size?.int64Value == copy.bytes
        }
    }

    static func filtered(_ groups: [Group], by filter: VaultFilter) -> [Group] {
        groups.filter { group in group.copies.first.map(filter.includes) ?? false }
    }

    private static func exactDigests(of items: [VaultItem], touching: Set<VaultItem>?,
                                     digest: (VaultItem) throws -> Data) -> [VaultItem: Data] {
        var digests: [VaultItem: Data] = [:]
        let sameSize = Dictionary(grouping: items, by: \.bytes).values.filter { bucket in
            bucket.count > 1 && (touching.map { wanted in bucket.contains(where: wanted.contains) } ?? true)
        }
        for item in sameSize.joined() {
            if let hash = try? digest(item) { digests[item] = hash }
        }
        return digests
    }

    private static func isExact(_ copies: [VaultItem], digests: [VaultItem: Data]) -> Bool {
        guard let first = copies.first.flatMap({ digests[$0] }) else { return false }
        return copies.allSatisfy { digests[$0] == first }
    }

    private static func exactPairs(_ items: [VaultItem], digests: [VaultItem: Data]) -> [Pair] {
        let byDigest = Dictionary(grouping: items.filter { digests[$0] != nil }) { digests[$0] }
        return byDigest.values.flatMap { copies in
            pairs(Array(copies.indices)).map { Pair(first: copies[$0.0], second: copies[$0.1], match: .exact) }
        }
    }

    private static func samePostIDPairs(_ items: [VaultItem], durations: [VaultItem: Double]) -> [Pair] {
        var byID: [String: [Int]] = [:]
        for (index, item) in items.enumerated() where item.kind == .video {
            if let id = postID(in: item.name) { byID[id, default: []].append(index) }
        }
        return byID.values.flatMap { indexes in
            pairs(indexes).filter { lengthsAgree(items[$0.0], items[$0.1], durations) }
                .map { Pair(first: items[$0.0], second: items[$0.1], match: .likely) }
        }
    }

    private static func sameLookPairs(_ items: [VaultItem], durations: [VaultItem: Double],
                                      looks: [VaultItem: VaultLook]) -> [Pair] {
        let looked = items.indices.filter { looks[items[$0]] != nil }
        return pairs(looked).compactMap { a, b in
            guard items[a].kind == items[b].kind, closeInLength(items[a], items[b], durations),
                  let first = looks[items[a]], let second = looks[items[b]], first.resembles(second) else { return nil }
            return Pair(first: items[a], second: items[b], match: .likely)
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
