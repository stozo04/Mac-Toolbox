import AppKit
import Observation

@MainActor @Observable
final class FixDamagedAppModel {
    static let shared = FixDamagedAppModel()

    enum Outcome: Equatable {
        case none
        case cleared
        case failed(String)
    }

    private(set) var app: AppDetails?
    private(set) var isLoading = false
    private(set) var loadError: String?
    private(set) var outcome = Outcome.none

    func load(_ url: URL) {
        isLoading = true
        loadError = nil
        outcome = .none
        Task {
            do {
                app = try await AppInspector.inspect(url)
            } catch {
                app = nil
                loadError = error.localizedDescription
            }
            isLoading = false
        }
    }

    func close() { app = nil; loadError = nil; outcome = .none }

    /// What the check found, in plain words, and whether clearing the flag is likely to help.
    var verdict: (text: String, symbol: String, good: Bool)? {
        guard let app else { return nil }
        if case .rejected(let reason) = app.assessment {
            if !app.isQuarantined {
                return ("macOS still rejects this app, but it isn't quarantined, so clearing the flag won't help. \(reason)", "xmark.octagon.fill", false)
            }
            return ("macOS blocks this app because it came from the internet. \(reason) Clearing the quarantine lets it open if you trust it.", "exclamationmark.triangle.fill", false)
        }
        if app.isQuarantined {
            return ("This app is flagged as downloaded from the internet. If macOS says it's damaged, clearing the flag usually fixes it.", "exclamationmark.circle.fill", false)
        }
        return ("This app isn't flagged and macOS accepts it. If it still won't open, the app may be damaged: download it again.", "checkmark.circle.fill", true)
    }

    func clearQuarantine() {
        guard let app else { return }
        let url = app.url
        do {
            try Quarantine.clear(at: url)
            outcome = .cleared
            Log.info("Quarantine cleared", category: "fixdamaged", ["signed": String(app.signature.isSigned)])
            Task { self.app = try? await AppInspector.inspect(url) }
        } catch {
            outcome = .failed(Quarantine.message(for: error))
            Log.warning("Quarantine clear failed", category: "fixdamaged", Log.details(error, file: url, ["signed": String(app.signature.isSigned)]))
        }
    }

    /// Asks first: this switches off a macOS safety check for one app.
    func confirmAndClear() {
        guard let app else { return }
        let alert = NSAlert()
        alert.messageText = "Open “\(app.name)” without the download check?"
        alert.informativeText = "This removes the flag that makes macOS check the app when it's first opened. Only do this for an app you downloaded from someone you trust."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear Quarantine")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { clearQuarantine() }
    }
}
