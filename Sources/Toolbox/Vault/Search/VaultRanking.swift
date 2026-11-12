import Foundation
import VaultSearch

struct VaultSearchHit: Equatable {
    let path: String
    let score: Double
    let start: Double?
}

struct VaultSearchResult: Equatable {
    var hits: [VaultSearchHit] = []
    var strong = true
}

enum VaultRanking {
    static let zGate = 2.0
    static let nameBonus = 2.0
    static let limit = 60
    static let closestCount = 6
    static let minimumWordLength = 2

    static func rank(query: String, vectors: VaultVectors, scores: [Float], names: [String: String]) -> VaultSearchResult {
        let meaning = Scoring.meaning(scores, vectors.modalities)
        var best: [String: (z: Double, start: Double)] = [:]
        for row in meaning.indices {
            let path = vectors.paths[row]
            if meaning[row] > (best[path]?.z ?? -.infinity) { best[path] = (meaning[row], vectors.starts[row]) }
        }
        let words = self.words(query)
        let named = Set(names.filter { matchesName(words, $0.value) }.keys)

        var candidates = Set(best.filter { $0.value.z >= zGate }.keys)
        candidates.formUnion(named)
        guard !candidates.isEmpty else {
            let closest = best.sorted { $0.value.z > $1.value.z || ($0.value.z == $1.value.z && $0.key < $1.key) }
                .prefix(closestCount)
                .map { VaultSearchHit(path: $0.key, score: $0.value.z, start: $0.value.start) }
            return VaultSearchResult(hits: closest, strong: false)
        }
        var hits: [VaultSearchHit] = []
        for path in candidates {
            let meaningScore: Double = max(best[path]?.z ?? 0, 0)
            let bonus: Double = named.contains(path) ? nameBonus : 0
            hits.append(VaultSearchHit(path: path, score: meaningScore + bonus, start: best[path]?.start))
        }
        hits.sort(by: isRankedBefore)
        return VaultSearchResult(hits: Array(hits.prefix(limit)), strong: true)
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
