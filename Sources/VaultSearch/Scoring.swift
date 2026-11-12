import Accelerate
import Foundation

public enum Modality: String, Sendable, CaseIterable {
    case image, audio
}

public enum Scoring {
    public static let smallGroup = 20
    public static let minimumDeviation = 0.02

    public static func cosines(_ query: [Float], against matrix: [Float], rows: Int, dimension: Int = LlamaEmbedder.dimension) -> [Float] {
        guard rows > 0, query.count == dimension, matrix.count == rows * dimension else { return [] }
        var scores = [Float](repeating: 0, count: rows)
        matrix.withUnsafeBufferPointer { matrix in
            query.withUnsafeBufferPointer { query in
                scores.withUnsafeMutableBufferPointer { scores in
                    vDSP_mmul(matrix.baseAddress!, 1, query.baseAddress!, 1, scores.baseAddress!, 1,
                              vDSP_Length(rows), 1, vDSP_Length(dimension))
                }
            }
        }
        return scores
    }

    public static func meaning(_ scores: [Float], _ modality: [Modality]) -> [Double] {
        guard !scores.isEmpty, scores.count == modality.count else { return [] }
        let means = modalityMeans(scores, modality)
        let centered = zip(scores, modality).map { Double($0) - means[$1, default: 0] }
        let mean = centered.reduce(0, +) / Double(centered.count)
        let squares = centered.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        let deviation = max((squares / Double(centered.count)).squareRoot(), minimumDeviation)
        return centered.map { ($0 - mean) / deviation }
    }

    public static func modalityMeans(_ scores: [Float], _ modality: [Modality]) -> [Modality: Double] {
        var sum: [Modality: Double] = [:], count: [Modality: Int] = [:]
        for row in scores.indices {
            sum[modality[row], default: 0] += Double(scores[row])
            count[modality[row], default: 0] += 1
        }
        let all = scores.reduce(0) { $0 + Double($1) } / Double(max(scores.count, 1))
        var out: [Modality: Double] = [:]
        for kind in Modality.allCases {
            if let n = count[kind], n >= smallGroup { out[kind] = sum[kind]! / Double(n) } else { out[kind] = all }
        }
        return out
    }
}
