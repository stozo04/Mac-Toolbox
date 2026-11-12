import Foundation
import VaultSearch

struct VaultSearchHit: Equatable {
    let path: String
    let score: Double
}

struct VaultSearchResult: Equatable {
    var hits: [VaultSearchHit] = []
    var clearCount = 0
    var isFallback = false

    var clearHits: ArraySlice<VaultSearchHit> { hits.prefix(clearCount) }
    var possibleHits: ArraySlice<VaultSearchHit> { hits.dropFirst(clearCount) }
}

enum VaultRanking {
    static let clearGate = 2.0
    static let possibleGate = 0.5
    static let nameBonus = 2.0
    static let limit = 60
    static let closestCount = 6
    static let minimumWordLength = 2

    static func rank(query: String, vectors: VaultVectors, scores: [Float], names: [String: String]) -> VaultSearchResult {
        let meaning = Scoring.meaning(scores, vectors.modalities)
        var best: [String: Double] = [:]
        for row in meaning.indices {
            let path = vectors.paths[row]
            if meaning[row] > (best[path] ?? -.infinity) { best[path] = meaning[row] }
        }
        let words = self.words(query)
        let named = Set(names.filter { matchesName(words, $0.value) }.keys)

        var clear: [VaultSearchHit] = []
        var possible: [VaultSearchHit] = []
        for path in Set(best.keys).union(named) {
            let z = best[path] ?? 0
            let isNamed = named.contains(path)
            let hit = VaultSearchHit(path: path, score: max(z, 0) + (isNamed ? nameBonus : 0))
            if isNamed || z >= clearGate {
                clear.append(hit)
            } else if z >= possibleGate {
                possible.append(hit)
            }
        }
        clear.sort(by: isRankedBefore)
        possible.sort(by: isRankedBefore)
        if !clear.isEmpty || !possible.isEmpty {
            let shown = Array((clear + possible).prefix(limit))
            return VaultSearchResult(hits: shown, clearCount: min(clear.count, shown.count))
        }
        let closest = best.map { VaultSearchHit(path: $0.key, score: $0.value) }
            .sorted(by: isRankedBefore)
            .prefix(closestCount)
        return VaultSearchResult(hits: Array(closest), clearCount: 0, isFallback: true)
    }

    static func isRankedBefore(_ first: VaultSearchHit, _ second: VaultSearchHit) -> Bool {
        if first.score != second.score { return first.score > second.score }
        return first.path < second.path
    }

    static func words(_ text: String) -> [String] {
        text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= minimumWordLength }
    }

    static func matchesName(_ words: [String], _ name: String) -> Bool {
        guard !words.isEmpty else { return false }
        let lower = name.lowercased()
        return words.allSatisfy { lower.contains($0) }
    }
}
