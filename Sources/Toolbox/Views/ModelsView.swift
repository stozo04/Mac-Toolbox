import SwiftUI

struct ModelsView: View {
    private let columns = [GridItem(.adaptive(minimum: 300), spacing: 16)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(AIModel.samples.count) models · Download once, run privately on your Mac")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("AI Models").font(.system(size: 34, weight: .bold))
                }
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(AIModel.samples) { ModelCard(model: $0) }
                }
            }
            .padding(20)
        }
    }
}

private struct ModelCard: View {
    let model: AIModel
    @State private var installed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: model.symbol).font(.title2).foregroundStyle(Theme.accent)
                    .frame(width: 48, height: 48)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name).font(.headline)
                    Text(model.publisher).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            Text(model.summary).font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                ForEach(model.tags, id: \.self) { tag in
                    Text(tag).font(.caption2)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.tint.opacity(0.08)))
                }
            }
            Spacer(minLength: 0)
            HStack {
                Text(model.size).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(installed ? "Installed" : "Download") { installed.toggle() }
                    .buttonStyle(.borderedProminent)
                    .tint(installed ? .gray : Theme.accent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 200, alignment: .topLeading)
        .padding(16)
        .cardBackground()
    }
}
