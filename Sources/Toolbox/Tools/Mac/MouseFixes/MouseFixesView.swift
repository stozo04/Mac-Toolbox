import SwiftUI

struct MouseFixesView: View {
    @State private var model = MouseFixesModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            options.frame(width: 260)
            VStack(spacing: 14) {
                statusCard.frame(height: 150)
                tryIt
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.recheckPermission() }
    }

    private var options: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Mouse Wheel").font(.headline)
                Text("Trackpads and the Magic Mouse aren't changed.").font(.caption).foregroundStyle(.secondary)
                InsetGroup {
                    OptionRow(title: "Reverse scroll direction") { Toggle("", isOn: $model.settings.reverse).labelsHidden().toggleStyle(.switch) }
                }
                Text("Your trackpad uses natural scrolling. With this on, the mouse wheel scrolls the classic way: down moves the page down.")
                    .font(.caption2).foregroundStyle(.secondary)
                InsetGroup {
                    OptionRow(title: "Speed") {
                        HStack(spacing: 6) {
                            Slider(value: $model.settings.speed, in: ScrollSettings.speedRange).frame(width: 90)
                            Text(String(format: "%.1f×", model.settings.speed).replacingOccurrences(of: ".0×", with: "×"))
                                .font(.caption.monospacedDigit()).frame(width: 32, alignment: .trailing)
                        }
                    }
                    Divider()
                    OptionRow(title: "Smooth scrolling") { Toggle("", isOn: $model.settings.smooth).labelsHidden().toggleStyle(.switch) }
                }
                Text("Smooth scrolling turns each click of the wheel into a short glide, like a trackpad.").font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var statusCard: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Status").font(.headline)
                    Spacer()
                    Pill(text: model.status == .on ? "On" : "Off", color: model.status == .on ? .green : .secondary)
                }
                Spacer()
                switch model.status {
                case .off: Text("Your mouse scrolls the way macOS sets it. Turn on a fix to change it.").font(.callout)
                case .on: Text("Active: \(model.settings.summary). This works while Toolbox is open.").font(.callout)
                case .needsPermission:
                    Text("Toolbox needs permission to adjust scrolling. Turn it on under Privacy & Security › Accessibility.").font(.callout)
                    Button("Open Accessibility Settings") { SystemSettingsLink.open("Privacy_Accessibility") }.controlSize(.small)
                }
            }
        }
    }

    private var tryIt: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Try It").font(.headline)
                    Text("Scroll here with your mouse, then your trackpad").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(1...60, id: \.self) { n in
                            HStack(spacing: 12) {
                                Text("\(n)").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 22, alignment: .trailing)
                                Capsule().fill(Theme.tint.opacity(0.12)).frame(width: CGFloat(60 + (n * 53) % 180), height: 5)
                            }
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }
}
