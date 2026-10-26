import SwiftUI
import UniformTypeIdentifiers

struct DropZone: View {
    let title: String
    let hint: String
    let symbol: String
    @State private var targeted = false
    @State private var files: [URL] = []

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(targeted ? Theme.accent : Theme.tint.opacity(0.12),
                                      style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
            VStack(spacing: 10) {
                Image(systemName: symbol).font(.system(size: 26))
                    .frame(width: 54, height: 54)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text(files.isEmpty ? title : "\(files.count) file(s) selected").font(.headline)
                Text(hint).font(.caption).foregroundStyle(.secondary)
                Button("Choose File...") { chooseFiles() }
                Label("Processed on this Mac. Originals stay untouched.", systemImage: "lock.fill")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { files.append(url) } }
                }
            }
            return true
        }
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { files = panel.urls }
    }
}

struct LinkWorkspace: View {
    @State private var link = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 12) {
                HStack {
                    Image(systemName: "link").foregroundStyle(Theme.accent)
                    TextField("Paste a video link", text: $link).textFieldStyle(.plain)
                    Button("Paste") {
                        link = NSPasteboard.general.string(forType: .string) ?? link
                    }
                    Button("Download") {}.disabled(link.isEmpty)
                }
                .padding(12).cardBackground(corner: 16)
                placeholder("Paste a Link", "Works with YouTube, X, TikTok, Instagram, Vimeo and more.", "link")
            }
            OptionsPanel(note: "Applies to every download.")
                .frame(width: 240)
        }
    }
}

struct LiveWorkspace: View {
    let symbol: String
    let idle: String
    let action: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            OptionsPanel(note: "Changes apply right away.").frame(width: 240)
            VStack(spacing: 14) {
                Spacer()
                Image(systemName: symbol).font(.system(size: 44)).foregroundStyle(.secondary)
                Text(idle).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button(action) {}.controlSize(.large)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16).cardBackground(corner: 24)
        }
    }
}

struct TextWorkspace: View {
    @State private var input = ""

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            OptionsPanel(note: "The result updates as you type.").frame(width: 240)
            VStack(alignment: .leading, spacing: 8) {
                Text("Input").font(.headline)
                TextEditor(text: $input)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                Text("Output").font(.headline)
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.inset)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(16).cardBackground(corner: 24)
        }
    }
}

struct OptionsPanel: View {
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Options").font(.headline)
            Text(note).font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }
}

@ViewBuilder
private func placeholder(_ title: String, _ hint: String, _ symbol: String) -> some View {
    VStack(spacing: 8) {
        Image(systemName: symbol).font(.system(size: 30)).foregroundStyle(.secondary)
        Text(title).font(.headline)
        Text(hint).font(.caption).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .cardBackground(corner: 24)
}
