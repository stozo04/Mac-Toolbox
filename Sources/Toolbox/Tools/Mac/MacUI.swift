import SwiftUI

/// Small building blocks shared by the Mac tools so they look like one family.
struct MacCard<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .cardBackground(corner: 24)
    }
}

/// A big number with a unit and a caption, e.g. "72.5 Mbps / How fast you can send files".
struct StatTile: View {
    let icon: String
    let title: String
    let value: String
    var unit = ""
    var caption = ""

    var body: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 4) {
                Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.system(size: 34, weight: value == "–" ? .light : .bold, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
                        .foregroundStyle(value == "–" ? Color.secondary : Color.primary)
                    if !unit.isEmpty { Text(unit).font(.callout.weight(.semibold)).foregroundStyle(.secondary) }
                }
                if !caption.isEmpty { Text(caption).font(.caption).foregroundStyle(.secondary) }
                Spacer(minLength: 0)
            }
        }
    }
}

struct Pill: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text).font(.caption2.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }
}

/// A rounded inset group that rows sit in (the "Options" style groups in the designs).
struct InsetGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

struct OptionRow<Control: View>: View {
    let title: String
    var subtitle: String?
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).lineLimit(2)
                if let subtitle { Text(subtitle).font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 4)
            control
        }
        .padding(.vertical, 8)
    }
}

/// Header + helper text for the 240pt options column.
struct OptionsHeader: View {
    let note: String
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Options").font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Large symbol, message and one action, centred in a card (the idle state of live tools).
struct CenteredState<Action: View>: View {
    let symbol: String
    let message: String
    @ViewBuilder var action: Action

    var body: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: symbol).font(.system(size: 46)).foregroundStyle(.secondary)
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Spacer()
            action
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

enum ByteFormat {
    static func string(_ bytes: Int64) -> String {
        bytes <= 0 ? "Zero KB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Sends the person to the System Settings page for a privacy permission.
enum SystemSettingsLink {
    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}
