import SwiftUI

struct KeepAwakeView: View {
    @State private var model = KeepAwakeModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            options.frame(width: 240)
            status
        }
    }

    private var options: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 12) {
                OptionsHeader(note: "Changes apply right away.")
                InsetGroup {
                    OptionRow(title: "Keep awake for") {
                        Picker("", selection: $model.duration) {
                            ForEach(KeepAwakeModel.Duration.allCases) { Text($0.label).tag($0) }
                        }.labelsHidden().fixedSize()
                    }
                }
                Text("Starting again replaces the current timer.").font(.caption2).foregroundStyle(.secondary)
                InsetGroup {
                    OptionRow(title: "Keep the display on") { Toggle("", isOn: $model.keepDisplayOn).labelsHidden().toggleStyle(.switch) }
                    Divider()
                    OptionRow(title: "Only while on power adapter") { Toggle("", isOn: $model.onlyOnPowerAdapter).labelsHidden().toggleStyle(.switch) }
                }
                Text(model.keepDisplayOn
                     ? "The screen stays on and the Mac does not sleep. Closing the lid of a MacBook still puts it to sleep unless a display is connected."
                     : "With the display allowed to sleep, the screen turns off as usual but downloads and renders keep running. Closing the lid of a MacBook still puts it to sleep unless a display is connected.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var status: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 0) {
                Label(statusTitle, systemImage: model.isOn ? "cup.and.saucer.fill" : "moon.zzz.fill")
                    .font(.caption.weight(.semibold)).foregroundStyle(model.isOn ? Color.green : .secondary)
                Spacer()
                centre.frame(maxWidth: .infinity)
                Spacer()
                HStack {
                    Spacer()
                    if model.isOn {
                        Button("Restart Timer") { model.start() }
                        Button("Stop") { model.stop() }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Keep Awake") { model.start() }.buttonStyle(.borderedProminent).controlSize(.large)
                    }
                    Spacer()
                }
            }
        }
    }

    private var statusTitle: String {
        switch model.state {
        case .off: "Not keeping awake"
        case .awake: "Awake"
        case .waitingForPower: "Waiting for the power adapter"
        }
    }

    @ViewBuilder private var centre: some View {
        switch model.state {
        case .off:
            VStack(spacing: 12) {
                Image(systemName: "moon.zzz").font(.system(size: 46)).foregroundStyle(.secondary)
                Text("Your Mac sleeps as usual.").font(.callout).foregroundStyle(.secondary)
            }
        case .awake(let until), .waitingForPower(let until):
            VStack(spacing: 10) {
                Image(systemName: "cup.and.saucer").font(.system(size: 46))
                if until != nil {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(KeepAwakeModel.format(model.remaining(at: context.date) ?? 0))
                            .font(.system(size: 44, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                } else {
                    Text("No timer").font(.system(size: 30, weight: .bold, design: .rounded))
                }
                Text(model.state == .awake(until: until) ? "Sleep paused" : "Sleep is allowed while on battery")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}
