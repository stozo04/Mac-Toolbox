import SwiftUI

struct NetworkSpeedTestView: View {
    @State private var model = NetworkSpeedTestModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                gaugeCard
                historyCard.frame(height: 150)
            }
            VStack(spacing: 14) {
                StatTile(icon: "arrow.up", title: "Upload", value: model.latest.map { format($0.uploadMbps) } ?? "–", unit: "Mbps",
                         caption: "How fast you can send files and video")
                StatTile(icon: "arrow.left.arrow.right", title: "Responsiveness", value: model.latest?.responsivenessLevel?.rawValue ?? "–",
                         caption: "How well calls hold up while the line is busy")
                StatTile(icon: "timer", title: "Latency", value: model.latest?.latencyMs.map { String(Int($0.rounded())) } ?? "–", unit: "ms",
                         caption: model.connection.map { "Delay on a quiet line, over \($0)" } ?? "Delay on a quiet line")
                testCard.frame(height: 150)
            }
            .frame(width: 240)
        }
    }

    // MARK: Gauge

    private var gaugeCard: some View {
        MacCard {
            VStack(spacing: 0) {
                Label("Download", systemImage: "arrow.down").font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Spacer()
                Gauge(fraction: model.isRunning ? 0 : SpeedResult.gaugeFraction(model.latest?.downloadMbps ?? 0),
                      value: model.latest.map { format($0.downloadMbps) } ?? "–", running: model.isRunning)
                    .frame(width: 190, height: 190)
                Spacer()
                Text(message).font(.callout.weight(.medium)).multilineTextAlignment(.center).frame(maxWidth: 420)
                    .foregroundStyle(isFailure ? Color.red : .primary)
                HStack {
                    if model.isRunning {
                        Button("Cancel") { model.cancel() }
                    } else {
                        Button(model.latest == nil ? "Start Test" : "Test Again") { model.start() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    }
                }
                .padding(.top, 10)
            }
        }
    }

    private var isFailure: Bool { if case .failed = model.state { true } else { false } }

    private var message: String {
        switch model.state {
        case .running: "Testing your connection. This takes about 30 seconds."
        case .failed(let m): m
        case .idle: model.latest?.advice ?? "Measure your download and upload speed and how well the line holds up under load."
        }
    }

    // MARK: History and options

    private var historyCard: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("History").font(.headline)
                    Text(model.history.count == 1 ? "1 test" : "\(model.history.count) tests").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if !model.history.isEmpty { Button("Clear") { model.clearHistory() }.buttonStyle(.borderless).font(.caption) }
                }
                if model.history.isEmpty {
                    Spacer()
                    Text("Run a test, then run another, say in a different room, to compare.")
                        .font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 6) { ForEach(model.history) { historyRow($0) } }
                    }
                }
            }
        }
    }

    private func historyRow(_ r: SpeedResult) -> some View {
        HStack {
            Text(r.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Label("\(format(r.downloadMbps)) Mbps", systemImage: "arrow.down").font(.caption.monospacedDigit())
            Label("\(format(r.uploadMbps)) Mbps", systemImage: "arrow.up").font(.caption.monospacedDigit()).frame(width: 110, alignment: .trailing)
            Text(r.responsivenessLevel?.rawValue ?? "—").font(.caption).frame(width: 60, alignment: .trailing)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var testCard: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 6) {
                Text("Test").font(.headline)
                Text("Uses Apple's networkQuality, built into macOS.").font(.caption2).foregroundStyle(.secondary)
                InsetGroup {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mode").font(.caption).foregroundStyle(.secondary)
                        Picker("", selection: $model.mode) {
                            ForEach(NetworkQuality.Mode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.radioGroup).labelsHidden().font(.caption2)
                    }
                    .padding(.vertical, 6).frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(model.isRunning)
            }
        }
    }

    private func format(_ mbps: Double) -> String {
        mbps >= 100 ? String(Int(mbps.rounded())) : String(format: "%.1f", mbps)
    }
}

private struct Gauge: View {
    let fraction: Double
    let value: String
    let running: Bool
    @State private var spin = false

    var body: some View {
        ZStack {
            Circle().trim(from: 0, to: 0.75).rotation(.degrees(135))
                .stroke(Theme.tint.opacity(0.14), style: StrokeStyle(lineWidth: 12, lineCap: .round))
            if running {
                Circle().trim(from: 0, to: 0.12).rotation(.degrees(spin ? 495 : 135))
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .onAppear { withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { spin = true } }
            } else {
                Circle().trim(from: 0, to: 0.75 * fraction).rotation(.degrees(135))
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 12, lineCap: .round))
                    .animation(.easeOut(duration: 0.6), value: fraction)
            }
            VStack(spacing: 0) {
                Text(running ? "…" : value).font(.system(size: 44, weight: value == "–" ? .light : .bold, design: .rounded)).minimumScaleFactor(0.5)
                    .foregroundStyle(value == "–" && !running ? Color.secondary : Color.primary)
                Text("Mbps").font(.caption).foregroundStyle(.secondary)
            }
            scaleLabel("1", x: -0.62, y: 0.78)
            scaleLabel("10", x: -0.92, y: -0.18)
            scaleLabel("100", x: 0.92, y: -0.18)
            scaleLabel("1G", x: 0.62, y: 0.78)
        }
    }

    private func scaleLabel(_ text: String, x: Double, y: Double) -> some View {
        Text(text).font(.system(size: 9)).foregroundStyle(.secondary).offset(x: x * 95, y: y * 95)
    }
}
