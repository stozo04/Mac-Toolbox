import Foundation

struct LaunchItem: Identifiable, Equatable {
    enum Scope: String, CaseIterable {
        case user = "Your items"
        case allUsers = "All users"
        case system = "System services"

        /// Only items in your own folder can be switched off without an administrator password.
        var canToggle: Bool { self == .user }
    }

    let label: String
    let plist: URL
    let scope: Scope
    let program: String?
    let runsAtLogin: Bool
    var isEnabled: Bool
    var signature: CodeSignInfo
    let exists: Bool
    var id: String { plist.path }

    /// The name of the app the item belongs to, otherwise its label.
    var displayName: String {
        if let program, let range = program.range(of: ".app/") {
            let app = String(program[..<range.lowerBound])
            return URL(fileURLWithPath: app).deletingPathExtension().lastPathComponent
        }
        return label
    }

    var developerText: String {
        if !exists { return "Program is missing" }
        if let developer = signature.developer { return developer }
        if signature.isAdHoc { return "Signed on this Mac, not by a developer" }
        return signature.isSigned ? "Unknown developer" : "Unknown (not signed)"
    }
}

enum LaunchItems {
    static var directories: [(URL, LaunchItem.Scope)] {
        [(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents"), .user),
         (URL(fileURLWithPath: "/Library/LaunchAgents"), .allUsers),
         (URL(fileURLWithPath: "/Library/LaunchDaemons"), .system)]
    }

    struct Parsed: Equatable {
        let label: String
        let program: String?
        let runAtLoad: Bool
        let disabledInPlist: Bool
    }

    static func parse(plistAt url: URL) -> Parsed? {
        guard let data = try? Data(contentsOf: url),
              let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return nil }
        let arguments = plist["ProgramArguments"] as? [String]
        let program = (plist["Program"] as? String) ?? arguments?.first
        return Parsed(label: (plist["Label"] as? String) ?? url.deletingPathExtension().lastPathComponent, program: program,
                      runAtLoad: (plist["RunAtLoad"] as? Bool) ?? false, disabledInPlist: (plist["Disabled"] as? Bool) ?? false)
    }

    /// `launchctl print-disabled` lines look like `"com.example.agent" => disabled`.
    static func parseDisabledOverrides(_ output: String) -> [String: Bool] {
        var overrides: [String: Bool] = [:]
        for line in output.split(separator: "\n") {
            let parts = line.components(separatedBy: "=>")
            guard parts.count == 2 else { continue }
            let label = parts[0].trimmingCharacters(in: CharacterSet(charactersIn: " \t\""))
            let state = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            guard !label.isEmpty, label != "disabled services" else { continue }
            if state == "disabled" || state == "true" { overrides[label] = true }
            if state == "enabled" || state == "false" { overrides[label] = false }
        }
        return overrides
    }

    /// The thing to check the signature of: the app a helper lives in, otherwise the program itself.
    static func signingTarget(forProgram program: String) -> String {
        if let range = program.range(of: ".app/") { return String(program[..<range.lowerBound]) + ".app" }
        return program
    }

    static func domain(uid: uid_t = getuid()) -> String { "gui/\(uid)" }

    static func disableCommands(label: String, uid: uid_t = getuid()) -> [[String]] {
        [["disable", "\(domain(uid: uid))/\(label)"], ["bootout", "\(domain(uid: uid))/\(label)"]]
    }

    static func enableCommands(label: String, plist: URL, uid: uid_t = getuid()) -> [[String]] {
        [["enable", "\(domain(uid: uid))/\(label)"], ["bootstrap", domain(uid: uid), plist.path]]
    }

    /// Reads every item. Slow (it checks signatures), so call off the main thread.
    static func scan(directories: [(URL, LaunchItem.Scope)] = LaunchItems.directories, overrides: [String: Bool]) -> [LaunchItem] {
        var items: [LaunchItem] = []
        for (directory, scope) in directories {
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "plist" {
                guard let parsed = parse(plistAt: file) else { continue }
                let exists = parsed.program.map { FileManager.default.fileExists(atPath: $0) } ?? false
                let signature = parsed.program.flatMap { exists ? CodeSignInfo.inspect(URL(fileURLWithPath: signingTarget(forProgram: $0))) : nil } ?? .unsigned
                let enabled = !(overrides[parsed.label] ?? parsed.disabledInPlist)
                items.append(LaunchItem(label: parsed.label, plist: file, scope: scope, program: parsed.program, runsAtLogin: parsed.runAtLoad,
                                        isEnabled: enabled, signature: signature, exists: exists))
            }
        }
        return items.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    static func currentOverrides() async -> [String: Bool] {
        guard let result = try? await Shell.run("/bin/launchctl", ["print-disabled", domain()]), result.succeeded else { return [:] }
        return parseDisabledOverrides(result.out)
    }

    /// Switches a user agent on or off. Throws the launchctl message if the final step fails.
    static func setEnabled(_ enabled: Bool, item: LaunchItem) async throws {
        guard item.scope.canToggle else { throw ToggleError.needsAdmin }
        let commands = enabled ? enableCommands(label: item.label, plist: item.plist) : disableCommands(label: item.label)
        for (index, args) in commands.enumerated() {
            let result = try await Shell.run("/bin/launchctl", args, timeout: 20)
            // Stopping something that isn't running, or starting something already running, is not a failure.
            if !result.succeeded && index == 0 { throw ToggleError.failed(result.err.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }
    }

    enum ToggleError: LocalizedError {
        case needsAdmin
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .needsAdmin: "This item belongs to all users and needs an administrator to change."
            case .failed(let m): m.isEmpty ? "macOS did not allow the change." : m
            }
        }
    }
}
