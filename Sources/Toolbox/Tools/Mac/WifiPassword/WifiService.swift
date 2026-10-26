import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

enum WifiSecurity: String, CaseIterable, Identifiable {
    case wpa = "WPA/WPA2/WPA3"
    case wep = "WEP"
    case none = "No password"
    var id: String { rawValue }
    var qrCode: String {
        switch self { case .wpa: "WPA"; case .wep: "WEP"; case .none: "nopass" }
    }
}

enum WifiService {
    enum PasswordResult: Equatable {
        case found(String)
        case notFound
        case cancelled
        case failed(String)
    }

    // MARK: Saved networks

    /// The device name of the Wi-Fi interface, usually "en0" or "en1".
    static func interface(inHardwarePorts listing: String) -> String? {
        var isWifi = false
        for line in listing.split(separator: "\n") {
            if line.hasPrefix("Hardware Port:") { isWifi = line.contains("Wi-Fi") || line.contains("AirPort") }
            if isWifi, line.hasPrefix("Device: ") { return String(line.dropFirst("Device: ".count)) }
        }
        return nil
    }

    /// Parses `networksetup -listpreferredwirelessnetworks`: a header line, then one tab-indented name per line.
    static func parseNetworks(_ output: String) -> [String] {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .filter { $0.first == "\t" || $0.first == " " }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    static func savedNetworks() async throws -> [String] {
        let ports = try await Shell.run("/usr/sbin/networksetup", ["-listallhardwareports"]).out
        guard let device = interface(inHardwarePorts: ports) else { return [] }
        let listing = try await Shell.run("/usr/sbin/networksetup", ["-listpreferredwirelessnetworks", device])
        return parseNetworks(listing.out)
    }

    // MARK: Password

    static func passwordArguments(for ssid: String) -> [String] {
        ["find-generic-password", "-D", "AirPort network password", "-a", ssid, "-w"]
    }

    /// Asks the Keychain for the password. macOS shows its own approval window, so this waits for the person.
    static func password(for ssid: String) async -> PasswordResult {
        guard let result = try? await Shell.run("/usr/bin/security", passwordArguments(for: ssid)) else { return .failed("The Keychain could not be opened.") }
        return interpret(status: result.status, output: result.out, error: result.err)
    }

    static func interpret(status: Int32, output: String, error: String) -> PasswordResult {
        switch status {
        case 0: return .found(output.trimmingCharacters(in: CharacterSet(charactersIn: "\n")))
        case 44: return .notFound
        case 51, 128: return .cancelled
        default: return .failed(error.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    // MARK: QR code

    /// The text a phone camera reads as "join this network". Special characters are backslash-escaped.
    static func qrPayload(ssid: String, password: String, security: WifiSecurity, hidden: Bool) -> String {
        // The characters that have a meaning in the WIFI: format get a backslash in front.
        let backslash = Character(UnicodeScalar(92))
        let special: Set<Character> = [backslash, ";", ",", ":", Character(UnicodeScalar(34))]
        func escape(_ s: String) -> String {
            var out = ""
            for c in s {
                if special.contains(c) { out.append(backslash) }
                out.append(c)
            }
            return out
        }
        var payload = "WIFI:T:\(security.qrCode);S:\(escape(ssid));"
        if security != .none { payload += "P:\(escape(password));" }
        if hidden { payload += "H:true;" }
        return payload + ";"
    }

    /// A crisp black-on-white QR code with the quiet zone scanners need.
    static func qrImage(_ text: String, side: CGFloat = 320) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
              let cg = CIContext().createCGImage(output, from: output.extent) else { return nil }
        let modules = CGFloat(cg.width)
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            let margin = rect.width * 4 / (modules + 8)
            NSGraphicsContext.current?.cgContext.interpolationQuality = .none
            NSGraphicsContext.current?.cgContext.draw(cg, in: rect.insetBy(dx: margin, dy: margin))
            return true
        }
        return image
    }

    static func pngData(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
}
