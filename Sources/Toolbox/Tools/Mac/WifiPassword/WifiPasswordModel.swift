import AppKit
import Observation

@MainActor @Observable
final class WifiPasswordModel {
    static let shared = WifiPasswordModel()

    enum Load: Equatable {
        case idle, loading
        case loaded
        case failed(String)
    }

    enum Reveal: Equatable {
        case hidden
        case asking
        case shown(String)
        case message(String)
    }

    private(set) var load = Load.idle
    private(set) var networks: [String] = []
    private(set) var reveal = Reveal.hidden
    var selected: String? { didSet { if selected != oldValue { reveal = .hidden } } }
    var security = WifiSecurity.wpa
    var hidden = false

    var password: String? { if case .shown(let p) = reveal { p } else { nil } }

    var qrText: String? {
        guard let selected, let password else { return nil }
        return WifiService.qrPayload(ssid: selected, password: password, security: security, hidden: hidden)
    }

    func loadNetworks() {
        guard load != .loading else { return }
        load = .loading
        Task {
            do {
                networks = try await WifiService.savedNetworks()
                load = .loaded
                if let selected, !networks.contains(selected) { self.selected = nil }
            } catch {
                load = .failed(error.localizedDescription)
            }
        }
    }

    func showPassword() {
        guard let ssid = selected, reveal != .asking else { return }
        reveal = .asking
        Task {
            let result = await WifiService.password(for: ssid)
            guard selected == ssid else { return }
            switch result {
            case .found(let p):
                reveal = .shown(p)
                Log.info("Wi-Fi password shown", category: "wifi")
            case .notFound:
                reveal = .message("No password is saved for this network. It may be an open network.")
                security = .none
            case .cancelled: reveal = .hidden
            case .failed(let m): reveal = .message(m.isEmpty ? "The password could not be read." : m)
            }
        }
    }

    func hidePassword() { reveal = .hidden }

    func copyPassword() {
        guard let password else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(password, forType: .string)
    }
}
