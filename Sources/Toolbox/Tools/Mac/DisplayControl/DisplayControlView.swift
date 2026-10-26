import SwiftUI

struct DisplayControlView: View {
    @State private var model = DisplayControlModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            list.frame(width: 240)
            detail
        }
        .onAppear { if model.monitors.isEmpty { model.refresh() } }
    }

    private var list: some View {
        MacCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Displays").font(.headline)
                    Text(model.monitors.isEmpty ? "" : "\(model.monitors.count) connected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless).disabled(model.isLoading)
                }
                if model.isLoading && model.monitors.isEmpty {
                    ProgressView("Looking for displays…").controlSize(.small).frame(maxWidth: .infinity).padding(.top, 20)
                } else if model.monitors.isEmpty {
                    Text("No external displays found.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.monitors) { m in
                        Button { model.selectedID = m.id } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "display").foregroundStyle(.black).frame(width: 30, height: 30)
                                    .background(Color.cyan, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(m.name).font(.callout.weight(.semibold)).lineLimit(1)
                                    Text(m.detail).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                }
                                Spacer(minLength: 0)
                                if m.isControllable { Pill(text: "DDC/CI") }
                            }
                            .padding(8)
                            .background(model.selected?.id == m.id ? Theme.accent.opacity(0.2) : Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Spacer()
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let m = model.selected {
            MacCard {
                VStack(alignment: .leading, spacing: 14) {
                    Text(m.name).font(.title3.weight(.bold))
                    Text("External · \(m.isControllable ? "controlled over DDC/CI · " : "")\(m.detail)").font(.caption).foregroundStyle(.secondary)
                    if m.isControllable {
                        InsetGroup {
                            ForEach(Array(DDC.Control.allCases.filter { m.maxima[$0] != nil }.enumerated()), id: \.element.id) { index, control in
                                if index > 0 { Divider() }
                                slider(control, m)
                            }
                        }
                        .frame(maxWidth: 520)
                        Text("Changes go straight to the monitor, the same as its own buttons.").font(.caption2).foregroundStyle(.secondary)
                        InsetGroup {
                            OptionRow(title: "Restore these settings when Toolbox opens") {
                                Toggle("", isOn: $model.restoreOnOpen).labelsHidden().toggleStyle(.switch)
                            }
                        }
                        .frame(maxWidth: 520)
                        Text("Toolbox remembers each monitor separately, even when you plug it into another port.").font(.caption2).foregroundStyle(.secondary)
                    }
                    if let problem = m.problem { Label(problem, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(.orange) }
                    Spacer()
                }
            }
        } else {
            MacCard {
                CenteredState(symbol: "display", message: model.isLoading ? "Looking for external displays…" : "Connect an external monitor to change its brightness, contrast and volume.") { EmptyView() }
            }
        }
    }

    private func slider(_ control: DDC.Control, _ m: DisplayControlModel.Monitor) -> some View {
        HStack(spacing: 12) {
            Label(control.title, systemImage: control.symbol).font(.callout).frame(width: 110, alignment: .leading)
            Slider(value: Binding(get: { m.values[control] ?? 0 }, set: { model.set(control, percent: $0, on: m.id) }), in: 0...100)
            Text("\(Int((m.values[control] ?? 0).rounded()))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }
}
