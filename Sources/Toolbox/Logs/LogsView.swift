import AppKit
import SwiftUI

/// Every event the app logged on this Mac, newest first, with the log fixer's verdict on each problem.
struct LogsView: View {
    @State private var model = LogsModel.forLaunch()
    private static let refreshEvery: Duration = .seconds(5)

    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 16) {
            header
            HStack(spacing: 12) {
                Picker("Range", selection: $model.range) {
                    ForEach(LogRange.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 620)
                Spacer()
                Picker("Status", selection: $model.status) {
                    Text("Any status").tag(LogStatus?.none)
                    Divider()
                    ForEach(LogStatus.allCases) { Text($0.rawValue).tag(LogStatus?.some($0)) }
                }
                .frame(width: 200)
            }
            tiles
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(Theme.warning)
            }
            HStack(alignment: .top, spacing: 16) {
                list
                LogDetailView(row: model.selected) { row in model.copyMarkdown(of: row, to: .general) }
                    .frame(width: 400)
            }
        }
        .padding(20)
        .task {
            while !Task.isCancelled {
                model.reload()
                try? await Task.sleep(for: Self.refreshEvery)
            }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 4) {
                Text(summaryLine).font(.caption).foregroundStyle(.secondary)
                Text("Logs").font(.system(size: 34, weight: .bold))
            }
            Spacer()
            Label("Updates on its own", systemImage: "checkmark.circle").font(.caption).foregroundStyle(.secondary)
            Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Look again")
        }
    }

    private var summaryLine: String {
        let total = model.totalInRange
        var line = "\(total.formatted()) event\(total == 1 ? "" : "s") in \(rangeWords) · kept on this Mac for 90 days"
        if model.reachedLimit { line += " · showing the newest \(LogsModel.rowLimit.formatted())" }
        return line
    }

    private var rangeWords: String {
        model.range == .all ? "all" : "the last \(model.range.rawValue.replacingOccurrences(of: "Week", with: "week"))"
    }

    // MARK: Counts

    private var tiles: some View {
        HStack(spacing: 12) {
            ForEach(LogLevel.allCases.reversed(), id: \.self) { level in
                let focused = !model.showsEveryLevel && model.levels.contains(level)
                Button { model.toggle(level) } label: {
                    StatTile(icon: level.symbol, title: level.title, value: (model.counts[level] ?? 0).formatted(),
                             caption: model.range == .all ? "All time" : "Last \(model.range.rawValue)")
                        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .strokeBorder(focused ? level.color : .clear, lineWidth: 2))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(focused ? "Click to stop showing \(level.title.lowercased())" : "Show \(level.title.lowercased())")
            }
            if !model.showsEveryLevel {
                Button("Show every level") { model.showEveryLevel() }.buttonStyle(.link)
            }
        }
        .frame(height: 104)
    }

    // MARK: List

    private var list: some View {
        Group {
            if model.rows.isEmpty {
                CenteredState(symbol: "list.bullet.rectangle", message: "No logs match these filters.") { EmptyView() }
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.rows) { row in
                            Button { model.selectedID = row.id } label: {
                                LogRowView(row: row, selected: row.id == model.selectedID)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(8)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }
}

private struct LogRowView: View {
    let row: LogRow
    let selected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: row.event.level.symbol).foregroundStyle(row.event.level.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(row.event.message).font(.callout).lineLimit(2)
                Text("\(row.event.category) · \(row.event.timestamp.formatted(LogDisplay.time)) · \(row.event.versionLabel)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            if let status = row.status { Pill(text: status.rawValue, color: status.color) }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(selected ? Theme.tint.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }
}

enum LogDisplay {
    static let time = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute().second()
}

extension LogLevel {
    var title: String {
        switch self {
        case .critical: "Critical"
        case .error: "Errors"
        case .warning: "Warnings"
        case .info: "Info"
        }
    }

    var symbol: String {
        switch self {
        case .critical: "xmark.octagon.fill"
        case .error: "exclamationmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .info: "info.circle"
        }
    }

    var color: Color {
        switch self {
        case .critical: Theme.warning
        case .error: .orange
        case .warning: .yellow
        case .info: .secondary
        }
    }
}

extension LogStatus {
    var color: Color {
        switch self {
        case .open: .orange
        case .issueOpen: .indigo
        case .fixProposed: .blue
        case .fixed: .green
        case .cameBack: Theme.warning
        case .loggingImproved: .teal
        case .watching: .purple
        case .needsHuman: .pink
        }
    }
}
