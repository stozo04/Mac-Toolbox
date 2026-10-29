import Foundation

/// Helpers that make warning/error/critical events rich enough for someone (or an agent) who was not
/// there to work out what went wrong. File names, error text and the steps just before the failure are
/// allowed; file contents, and the user's account name, are not.
enum LogText {
    /// One line, no account name, at most `limit` characters.
    static func clean(_ text: String, limit: Int) -> String {
        var s = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        s = s.replacingOccurrences(of: "/Users/[^/\\s\"']+", with: "/Users/me", options: .regularExpression)
        if s.count > limit { s = String(s.prefix(max(0, limit - 1))) + "…" }
        return s
    }

    /// A link without its query string or credentials, which is where tokens live.
    static func safeURL(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.host ?? "unknown" }
        parts.query = nil; parts.fragment = nil; parts.user = nil; parts.password = nil
        return clean(parts.string ?? url.host ?? "unknown", limit: 300)
    }
}

extension Log {
    /// Metadata for a failure: what the error is, what was being worked on, and anything else the caller adds.
    ///
    ///     Log.error("Image conversion failed", category: "convert-images",
    ///               Log.details(error, file: item.url, ["to": settings.format.ext]))
    static func details(_ error: Error, file: URL? = nil, _ context: [String: String] = [:]) -> [String: String] {
        let ns = error as NSError
        var m: [String: String] = [
            "error_type": LogText.clean(String(reflecting: type(of: error)), limit: 120),
            "error_domain": ns.domain,
            "error_code": String(ns.code),
            "error_description": LogText.clean(error.localizedDescription, limit: 400),
        ]
        if let reason = ns.localizedFailureReason { m["error_reason"] = LogText.clean(reason, limit: 300) }
        let dump = LogText.clean(String(describing: error), limit: 500)
        if dump != m["error_description"] { m["error_debug"] = dump }
        if let under = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            m["underlying"] = LogText.clean("\(under.domain) \(under.code): \(under.localizedDescription)", limit: 300)
        }
        if let file { m.merge(fileFacts(file)) { _, new in new } }
        m.merge(context) { _, new in new }
        return m
    }

    /// Name, type and size of a file. Never its contents or its folder.
    static func fileFacts(_ url: URL) -> [String: String] {
        var m = ["file_name": LogText.clean(url.lastPathComponent, limit: 200)]
        if !url.pathExtension.isEmpty { m["file_ext"] = url.pathExtension.lowercased() }
        if let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize { m["file_bytes"] = String(size) }
        return m
    }
}

extension LogEvent {
    /// Fits the event inside the limits of the `mactoolkit_app_logs` table. A row that breaks a limit is
    /// rejected, and the sink would drop the whole batch with it, so trim here instead.
    func fitted(metadataBudget: Int = 3500) -> LogEvent {
        var e = self
        e.category = LogText.clean(category, limit: 64)
        e.message = LogText.clean(message, limit: 500)
        var m = metadata.reduce(into: [String: String]()) { $0[LogText.clean($1.key, limit: 64)] = LogText.clean($1.value, limit: 900) }
        func size() -> Int { m.reduce(0) { $0 + $1.key.utf8.count + $1.value.utf8.count + 8 } }
        for key in ["recent", "error_debug", "underlying", "error_reason"] where size() > metadataBudget {
            m[key] = nil
        }
        if size() > metadataBudget {
            m = m.mapValues { LogText.clean($0, limit: 120) }
        }
        while size() > metadataBudget, let last = m.keys.sorted().last { m[last] = nil }
        e.metadata = m
        return e
    }
}
