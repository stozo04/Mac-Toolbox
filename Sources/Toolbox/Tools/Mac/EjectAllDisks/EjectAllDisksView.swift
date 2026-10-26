import SwiftUI

struct EjectAllDisksView: View {
    @State private var model = EjectAllDisksModel.shared

    var body: some View {
        MacCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("External disks").font(.headline)
                    Text(model.volumes.isEmpty ? "" : "\(model.volumes.count) connected").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }.buttonStyle(.borderless)
                }
                if model.volumes.isEmpty {
                    CenteredState(symbol: "externaldrive", message: model.isScanning ? "Looking for external disks…" : "No external drives, cards or disk images are connected.") { EmptyView() }
                } else {
                    ScrollView {
                        VStack(spacing: 8) { ForEach(model.volumes) { row($0) } }
                    }
                    HStack {
                        Text("Network shares, the startup disk and Time Machine are never ejected.").font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button(model.remaining.isEmpty ? "All Ejected" : "Eject All") { model.ejectAll() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(model.remaining.isEmpty || model.isEjecting)
                    }
                }
            }
        }
        .onAppear { model.startWatching(); model.refresh() }
    }

    private func row(_ v: VolumeInfo) -> some View {
        let status = model.status[v.id] ?? .ready
        return HStack(spacing: 12) {
            Image(systemName: v.symbol).font(.title2).frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(v.name).font(.callout.weight(.semibold)).lineLimit(1)
                Text([v.kind.rawValue, v.capacity.map { ByteFormat.string($0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary)
                if case .failed(let message) = status { Text(message).font(.caption).foregroundStyle(.red) }
            }
            Spacer()
            switch status {
            case .ready: EmptyView()
            case .ejecting: ProgressView().controlSize(.small)
            case .ejected: Label("Ejected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            }
        }
        .padding(12)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
