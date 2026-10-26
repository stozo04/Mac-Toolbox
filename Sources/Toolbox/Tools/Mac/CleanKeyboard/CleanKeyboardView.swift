import SwiftUI

struct CleanKeyboardView: View {
    @State private var model = CleanKeyboardModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            options.frame(width: 240)
            MacCard {
                VStack(spacing: 0) {
                    Spacer()
                    illustration
                    Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380).padding(.top, 18)
                    if model.state == .needsPermission { permission }
                    Spacer()
                    Button("Start Cleaning") { model.start() }.buttonStyle(.borderedProminent).controlSize(.large).disabled(model.isCleaning)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.recheckPermission() }
    }

    private var options: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 12) {
                OptionsHeader(note: "The mouse and trackpad keep working.")
                InsetGroup {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Pause for").font(.callout)
                        Picker("", selection: $model.seconds) {
                            Text("30 seconds").tag(30)
                            Text("1 minute").tag(60)
                            Text("2 minutes").tag(120)
                        }
                        .pickerStyle(.radioGroup).labelsHidden()
                    }
                    .padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.isCleaning)
                Text("Click Done on screen to stop early. The power button and Touch ID can't be paused, so avoid pressing them.")
                    .font(.caption2).foregroundStyle(.secondary)
                Spacer()
            }
        }
    }

    private var message: String {
        switch model.state {
        case .needsPermission: "Toolbox needs permission to pause the keyboard."
        default: "Your screen dims and shows a countdown. Wipe the keys, then click Done."
        }
    }

    private var permission: some View {
        VStack(spacing: 8) {
            Text("Turn on Toolbox under Privacy & Security › Accessibility, then come back and click Start Cleaning.").font(.caption).foregroundStyle(.secondary)
            Button("Open Accessibility Settings") { SystemSettingsLink.open("Privacy_Accessibility") }
        }
        .padding(.top, 8).frame(maxWidth: 380)
    }

    private var illustration: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 6) {
                ForEach(["QWERT", "ASDFG", "ZXCVB"], id: \.self) { row in
                    HStack(spacing: 6) {
                        ForEach(Array(row), id: \.self) { key in
                            Text(String(key)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                                .frame(width: 34, height: 34)
                                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.stroke))
                        }
                    }
                    .padding(.leading, row == "ASDFG" ? 14 : (row == "ZXCVB" ? 28 : 0))
                }
            }
            .overlay(
                Capsule().fill(Color.teal.opacity(0.5)).frame(width: 190, height: 26).rotationEffect(.degrees(-14)).offset(x: -10, y: 4)
            )
            Text(pillText).font(.caption.weight(.bold)).monospacedDigit().foregroundStyle(.black)
                .padding(.horizontal, 10).padding(.vertical, 5).background(Color.cyan, in: Capsule()).offset(x: 14, y: -16)
        }
    }

    private var pillText: String {
        guard model.isCleaning else { return "⏸ \(KeepAwakeModel.format(TimeInterval(model.seconds)))" }
        return "⏸ cleaning"
    }
}
