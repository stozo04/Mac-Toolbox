import SwiftUI

/// Everything one event recorded, what the log fixer decided about its signature, and a Markdown copy for an issue.
struct LogDetailView: View {
    let row: LogRow?
    let copy: (LogRow) -> Void
    let toggleArchived: (LogRow) -> Void
    @State private var copiedID: Int64?

    var body: some View {
        Group {
            if let row {
                ScrollView { content(row).padding(18) }
            } else {
                CenteredState(symbol: "sidebar.right", message: "Pick a log to see everything it recorded.") { EmptyView() }
            }
        }
        .frame(maxHeight: .infinity)
        .cardBackground()
    }

    private func content(_ row: LogRow) -> some View {
        let event = row.event
        return VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(event.level.rawValue.capitalized, systemImage: event.level.symbol)
                    .font(.caption.weight(.semibold)).foregroundStyle(event.level.color)
                Spacer()
                Text(event.timestamp.formatted(LogDisplay.time)).font(.caption).foregroundStyle(.secondary)
            }
            Text(event.message).font(.headline).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            if let status = row.status { statusSection(status, row.resolution) }
            InsetGroup {
                fact("Area", event.category)
                fact("Version", event.versionLabel)
                fact("macOS", event.osVersion)
                fact("Launch", String(event.sessionID.prefix(8)))
            }
            section("Signature") {
                Text(row.log.signature).font(.caption.monospaced()).textSelection(.enabled)
            }
            if !event.metadata.isEmpty {
                section("Details") {
                    ForEach(event.metadata.sorted { $0.key < $1.key }, id: \.key) { key, value in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(key).font(.caption2).foregroundStyle(.secondary)
                            Text(value).font(.caption.monospaced()).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    copy(row)
                    copiedID = row.id
                } label: {
                    Label(copiedID == row.id ? "Copied" : "Copy as Markdown", systemImage: copiedID == row.id ? "checkmark" : "doc.on.doc")
                }
                if row.status?.alreadyTracked != true, let issue = LogsModel.newIssueURL(for: row) {
                    Link(destination: issue) { Label("Create GitHub Issue", systemImage: "exclamationmark.bubble") }
                        .buttonStyle(.bordered)
                        .help("Opens a new issue on GitHub filled in with this event. You can edit it before you submit.")
                }
            }
            Button { toggleArchived(row) } label: {
                Label(row.log.archivedAt == nil ? "Archive" : "Unarchive",
                      systemImage: row.log.archivedAt == nil ? "archivebox" : "tray.and.arrow.up")
            }
            .help(row.log.archivedAt == nil
                  ? "Keeps this log but hides it from the list and the counts. Turn on Show archived to see it again."
                  : "Shows this log in the list and the counts again.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusSection(_ status: LogStatus, _ resolution: LogResolution?) -> some View {
        section("Status") {
            HStack(spacing: 8) {
                Pill(text: status.rawValue, color: status.color)
                if let version = resolution?.fixedInVersion { Text("shipped in v\(version)").font(.caption).foregroundStyle(.secondary) }
            }
            Text(status.explanation).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let note = resolution?.note, !note.isEmpty {
                Text(note).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(resolution?.shownLinks ?? [], id: \.self) { url in
                Link(destination: url) { Label(Self.linkTitle(url), systemImage: "arrow.up.right.square") }
            }
        }
    }

    static func linkTitle(_ url: URL) -> String {
        let number = url.lastPathComponent
        return url.path.contains("/pull/") ? "Pull request #\(number)" : "Issue #\(number)"
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.caption).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 6)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }
}

extension LogStatus {
    var explanation: String {
        switch self {
        case .open: "The log fixer has not looked at this problem yet."
        case .issueOpen: "You opened a GitHub issue for it. The log fixer works on it next and links its pull request to the issue."
        case .fixProposed: "A pull request with a fix is open. It is not in the app until that is merged and installed."
        case .fixed: "Fixed, and this event came from a version before the fix."
        case .cameBack: "This happened again in a version that has the fix, so the fix did not hold."
        case .loggingImproved: "The cause was unclear, so the log fixer made this event record more. The next one will say more."
        case .watching: "A watch issue is collecting more cases before anyone changes code."
        case .needsHuman: "The log fixer could not fix this on its own."
        }
    }
}
