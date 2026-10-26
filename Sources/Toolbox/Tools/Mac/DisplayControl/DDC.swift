import Foundation

/// DDC/CI: the language monitors understand for brightness, contrast and volume. Pure packet logic, no hardware.
enum DDC {
    enum Control: String, CaseIterable, Identifiable, Codable {
        case brightness, contrast, volume
        var id: String { rawValue }
        /// The monitor's feature code (VCP) for this control.
        var vcp: UInt8 {
            switch self { case .brightness: 0x10; case .contrast: 0x12; case .volume: 0x62 }
        }
        var title: String { rawValue.capitalized }
        var symbol: String {
            switch self { case .brightness: "sun.max"; case .contrast: "circle.lefthalf.filled"; case .volume: "speaker.wave.2" }
        }
    }

    /// I2C addresses used over the display connection: 0x37 is the monitor, 0x51 is the host's source address.
    static let chipAddress: UInt32 = 0x37
    static let sourceAddress: UInt32 = 0x51
    /// Replies are read back from offset 0 (checked against real monitors; reading at 0x51 mostly returns nothing).
    static let replyAddress: UInt32 = 0x00

    /// The checksum covers the destination (0x6E), the source (0x51) and every byte of the message.
    static func checksum(_ bytes: [UInt8]) -> UInt8 { bytes.reduce(0x6E ^ 0x51, ^) }

    static func setPacket(vcp: UInt8, value: UInt16) -> [UInt8] {
        let body: [UInt8] = [0x84, 0x03, vcp, UInt8(value >> 8), UInt8(value & 0xFF)]
        return body + [checksum(body)]
    }

    static func getRequestPacket(vcp: UInt8) -> [UInt8] {
        let body: [UInt8] = [0x82, 0x01, vcp]
        return body + [checksum(body)]
    }

    /// Reads a "get value" reply: length 0x88, opcode 0x02, result 0 (ok), the feature code, type, max, current.
    /// Tolerates a leading source byte (0x6E) being present or not.
    static func parseReply(_ bytes: [UInt8], vcp: UInt8) -> (current: Int, max: Int)? {
        for start in 0...1 {
            guard bytes.count >= start + 10, bytes[start] == 0x88, bytes[start + 1] == 0x02 else { continue }
            guard bytes[start + 2] == 0x00, bytes[start + 3] == vcp else { return nil }
            let max = Int(bytes[start + 5]) << 8 | Int(bytes[start + 6])
            let current = Int(bytes[start + 7]) << 8 | Int(bytes[start + 8])
            return max > 0 ? (current, max) : nil
        }
        return nil
    }

    static func raw(percent: Double, max maximum: Int) -> UInt16 {
        let clamped = Swift.min(Swift.max(percent, 0), 100)
        return UInt16(Swift.min(Double(maximum), (clamped / 100 * Double(maximum)).rounded()))
    }

    static func percent(current: Int, max maximum: Int) -> Double {
        maximum > 0 ? Swift.min(100, Double(current) / Double(maximum) * 100) : 0
    }
}
