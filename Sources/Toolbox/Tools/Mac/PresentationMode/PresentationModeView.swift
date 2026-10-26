import SwiftUI

struct PresentationModeView: View {
    @State private var model = PresentationModeModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            MacCard {
                VStack(alignment: .leading, spacing: 12) {
                    OptionsHeader(note: "One switch turns all of these on or off.")
                    InsetGroup {
                        line("Hide desktop icons", "Files on the Desktop stay where they are.", "menubar.dock.rectangle")
                        Divider()
                        line("Hide the Dock", "It slides back when you point at the edge.", "dock.rectangle")
                        Divider()
                        line("Stay awake", "No sleep and no screen saver while presenting.", "cup.and.saucer")
                    }
                    Text("Turning it off puts every setting back the way it was. Finder and the Dock restart for a moment when you switch.")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .frame(width: 240)
            MacCard {
                CenteredState(symbol: model.isOn ? "rectangle.on.rectangle.fill" : "rectangle.on.rectangle",
                              message: model.isOn ? "Presentation mode is on. Your Mac is ready to share." : "Presentation mode is off.") {
                    Button(model.isOn ? "Turn Off" : "Turn On") { model.toggle() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            }
        }
    }

    private func line(_ title: String, _ detail: String, _ symbol: String) -> some View {
        OptionRow(title: title, subtitle: detail) {
            Image(systemName: model.isOn ? "checkmark.circle.fill" : symbol)
                .foregroundStyle(model.isOn ? Color.green : .secondary)
        }
    }
}
