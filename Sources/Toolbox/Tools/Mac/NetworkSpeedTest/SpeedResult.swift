import Foundation

struct SpeedResult: Codable, Equatable, Identifiable {
    var id = UUID()
    var date = Date()
    var downloadMbps: Double
    var uploadMbps: Double
    /// Round trips per minute under load. Apple's "responsiveness" figure.
    var responsiveness: Int?
    /// Delay on an idle line, in milliseconds.
    var latencyMs: Double?
    var interface: String?

    enum Responsiveness: String {
        case low = "Low", medium = "Medium", high = "High"
    }

    var responsivenessLevel: Responsiveness? {
        guard let rpm = responsiveness else { return nil }
        // Apple's own bands: under 200 is poor, over 1000 is excellent.
        return rpm < 200 ? .low : (rpm < 1000 ? .medium : .high)
    }

    /// A one-line plain-language verdict that connects the numbers to what people do.
    var advice: String {
        let fast = downloadMbps >= 25
        switch (fast, responsivenessLevel) {
        case (true, .low?): return "Fast enough for 4K streaming, but lag under load can make calls and games choppy."
        case (true, _): return downloadMbps >= 100 ? "Plenty fast for 4K streaming, big downloads and video calls at once." : "Fast enough for 4K streaming and video calls."
        case (false, _): return downloadMbps >= 5 ? "Fine for browsing and HD video. Large downloads and 4K streaming will be slow." : "Slow. Even video calls may struggle."
        }
    }

    /// 0...1 position on a log scale from 1 Mbps to 1 Gbps, as the gauge draws it.
    static func gaugeFraction(_ mbps: Double) -> Double {
        guard mbps > 1 else { return 0 }
        return min(1, log10(mbps) / 3)
    }
}

enum NetworkQuality {
    enum Mode: String, CaseIterable, Identifiable {
        case together = "Download and upload together"
        case sequential = "One after the other"
        var id: String { rawValue }
    }

    enum QualityError: LocalizedError {
        case unreadable
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: "The test finished but its result couldn't be read."
            case .failed(let m): m.isEmpty ? "The test could not run. Check your internet connection." : m
            }
        }
    }

    static func arguments(for mode: Mode) -> [String] {
        mode == .sequential ? ["-c", "-s"] : ["-c"]
    }

    /// Reads the JSON that `networkQuality -c` prints. Throughput there is in bits per second.
    static func parse(_ json: Data) throws -> SpeedResult {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let down = (object["dl_throughput"] as? NSNumber)?.doubleValue,
              let up = (object["ul_throughput"] as? NSNumber)?.doubleValue else { throw QualityError.unreadable }
        return SpeedResult(downloadMbps: down / 1_000_000, uploadMbps: up / 1_000_000,
                           responsiveness: (object["responsiveness"] as? NSNumber)?.intValue,
                           latencyMs: (object["base_rtt"] as? NSNumber)?.doubleValue,
                           interface: object["interface_name"] as? String)
    }

    static func run(_ mode: Mode) async throws -> SpeedResult {
        let result = try await Shell.run("/usr/bin/networkQuality", arguments(for: mode), timeout: 180)
        guard result.succeeded else { throw QualityError.failed(result.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return try parse(Data(result.out.utf8))
    }

    /// "Wi-Fi", "Ethernet" or nil, from the interface the test used.
    static func connectionKind(interface: String?) async -> String? {
        guard let interface,
              let ports = try? await Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"]).out else { return nil }
        return portName(for: interface, in: ports)
    }

    static func portName(for interface: String, in listing: String) -> String? {
        var port: String?
        for line in listing.split(separator: "\n") {
            if line.hasPrefix("Hardware Port: ") { port = String(line.dropFirst("Hardware Port: ".count)) }
            if line == "Device: \(interface)" { return port?.hasPrefix("Wi-Fi") == true ? "Wi-Fi" : (port?.contains("Ethernet") == true ? "Ethernet" : port) }
        }
        return nil
    }
}
