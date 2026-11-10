import SwiftUI

/// The version in the bottom-right corner of the window. Click it for the release history.
struct VersionBadge: View {
    @State private var showsNotes = false

    var body: some View {
        Button { showsNotes.toggle() } label: {
            Text("v\(AppVersion.current)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().strokeBorder(Theme.stroke))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("What's new in Toolbox")
        .popover(isPresented: $showsNotes, arrowEdge: .top) {
            ReleaseNotesView()
        }
        .task {
            // Debug: `--release-notes` opens the history at launch, for screenshots.
            guard CommandLine.arguments.contains("--release-notes") else { return }
            try? await Task.sleep(for: .milliseconds(600))
            showsNotes = true
        }
    }
}

struct ReleaseNotesView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("What's New").font(.title3.weight(.semibold))
                .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 10)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    ForEach(ReleaseNotes.all) { release in
                        section(release)
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 440, height: 480)
    }

    private func section(_ release: Release) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Version \(release.version)").font(.headline)
                if release.version == AppVersion.current {
                    Text("Current").font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundStyle(.white)
                }
                Spacer()
                Text(Self.displayDate(release.date)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(release.changes, id: \.self) { change in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    HStack(spacing: 5) {
                        Circle().fill(color(change.kind)).frame(width: 6, height: 6)
                        Text(change.kind.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                    .frame(width: 78, alignment: .leading)
                    Text(change.text).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func color(_ kind: Release.Kind) -> Color {
        switch kind {
        case .new: .green
        case .improved: .blue
        case .fixed: .orange
        case .removed: .secondary
        }
    }

    static func displayDate(_ iso: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: iso) else { return iso }
        return date.formatted(date: .abbreviated, time: .omitted)
    }
}
