import SwiftUI

struct DownloadVideoView: View {
    @State private var model = DownloadVideoModel.shared

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 12) {
                linkBar
                if model.toolStatus != .ready && model.toolStatus != .checking { toolBanner }
                VStack(spacing: 0) {
                    Group {
                        if model.items.isEmpty { emptyState } else { itemList }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider().overlay(Theme.stroke)
                    footer
                }
                .cardBackground(corner: 24)
            }
            options.frame(width: 240)
        }
        .alert(item: $model.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message),
                  primaryButton: .default(Text("Update yt-dlp")) { model.installTool() },
                  secondaryButton: .cancel(Text("OK")))
        }
    }

    // MARK: Link bar

    private var linkBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "link").foregroundStyle(Theme.accent)
                .frame(width: 30, height: 30)
                .background(Theme.accent.opacity(0.15), in: Circle())
            TextField("Paste a video link", text: $model.linkText, axis: .vertical)
                .textFieldStyle(.plain).lineLimit(1...4)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .onSubmit { model.start() }
            Button { model.paste() } label: { Label("Paste", systemImage: "doc.on.clipboard") }
            Button("Download") { model.start() }
                .buttonStyle(.borderedProminent).disabled(!model.canStart)
        }
        .padding(10).cardBackground(corner: 20)
    }

    private var toolBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloader not installed").font(.callout.weight(.semibold))
                Text(bannerDetail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.toolStatus == .installing {
                ProgressView().controlSize(.small)
            } else {
                Button("Install yt-dlp") { model.installTool() }
            }
        }
        .padding(12).cardBackground(corner: 16)
    }

    private var bannerDetail: String {
        switch model.toolStatus {
        case .installing: "Downloading yt-dlp from GitHub..."
        case .installFailed(let why): "\(why) You can also run: brew install yt-dlp"
        default: "Toolbox uses the open-source yt-dlp to save videos. It is a one-time download from GitHub."
        }
    }

    // MARK: Empty state / list

    private static let sites: [(symbol: String, color: Color)] = [
        ("play.rectangle.fill", .red), ("xmark", .primary), ("music.note", .primary),
        ("camera.fill", .pink), ("play.circle.fill", .cyan), ("bubble.left.fill", .orange),
        ("tv.fill", .purple), ("cloud.fill", .orange),
    ]

    private var emptyState: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(Self.sites.indices, id: \.self) { i in
                    Image(systemName: Self.sites[i].symbol)
                        .foregroundStyle(Self.sites[i].color)
                        .frame(width: 38, height: 38)
                        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            Text("Paste a Link").font(.headline).padding(.top, 6)
            Text("Works with YouTube, X, TikTok, Instagram, Vimeo, Reddit, Twitch, SoundCloud and over a thousand other sites. Paste one or more links above.")
                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
    }

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(model.items) { item in DownloadRow(item: item, model: model) }
            }
            .padding(14)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(footerText).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if !model.items.isEmpty && !model.isRunning {
                Button("Clear") { model.clearFinished() }
                    .help("Clears the list and moves the downloaded files to the Trash")
                Button { model.sendToGoogle() } label: { Label("Send to Google", systemImage: "icloud.and.arrow.up") }
                    .disabled(!model.canSend)
                if model.folder != nil { Button("Open Folder") { model.openFolder() } }
            }
            if model.isRunning {
                Button("Cancel", role: .cancel) { model.cancel() }
            } else {
                Button("Download") { model.start() }.disabled(!model.canStart)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    private var footerText: String {
        if model.items.isEmpty { return "" }
        switch model.sendState {
        case .idle: break
        case .sending: return "Sending to Google Drive…"
        case .sent(let copied, let skipped):
            return skipped == 0 ? "Sent \(copied) to Google Drive"
                                : "Sent \(copied) to Google Drive, \(skipped) already there"
        case .failed(let message): return message
        }
        return "\(model.finishedCount) of \(model.items.count) saved"
    }

    // MARK: Options

    private var options: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Options").font(.headline)
            Text("Applies to every download.").font(.caption).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                HStack {
                    Text("Format").font(.callout)
                    Spacer()
                    Picker("Format", selection: $model.options.format) {
                        ForEach(DownloadFormat.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                .padding(10)
                Divider().overlay(Theme.stroke)
                Toggle("Prefer H.264", isOn: $model.options.preferH264)
                    .toggleStyle(.switch).font(.callout)
                    .disabled(model.options.format == .audio)
                    .padding(10)
            }
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text("H.264 plays everywhere, including QuickTime Player and iPhone. Turn this off for the highest resolution, which may need another player.")
                .font(.caption2).foregroundStyle(.secondary)
            if !model.hasFFmpeg && model.toolStatus == .ready {
                Text("ffmpeg was not found, so only ready-made MP4 files can be saved. Install it with: brew install ffmpeg")
                    .font(.caption2).foregroundStyle(.yellow)
            }
            Text("Download only videos you own or have permission to save.")
                .font(.caption2).foregroundStyle(.secondary).padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }
}

private struct DownloadRow: View {
    let item: DownloadItem
    let model: DownloadVideoModel

    var body: some View {
        HStack(spacing: 12) {
            icon.frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title ?? item.url.absoluteString).font(.callout).lineLimit(1).truncationMode(.middle)
                detail
            }
            Spacer(minLength: 0)
            if case .done = item.state {
                Button { model.reveal(item) } label: { Image(systemName: "magnifyingglass.circle") }
                    .buttonStyle(.plain).help("Show in Finder")
            }
        }
        .padding(12)
        .background(Theme.inset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .queued: Image(systemName: "clock").foregroundStyle(.secondary)
        case .downloading: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var detail: some View {
        switch item.state {
        case .queued:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        case .downloading(let fraction, let speed, let eta):
            if let fraction { ProgressView(value: fraction) } else { ProgressView().progressViewStyle(.linear) }
            Text(Self.progressText(fraction, speed, eta)).font(.caption).foregroundStyle(.secondary)
        case .done(let file):
            Text("Saved as \(file.lastPathComponent)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .failed(let message):
            Text(message).font(.caption).foregroundStyle(.red).lineLimit(3)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        }
    }

    private static func progressText(_ fraction: Double?, _ speed: Double?, _ eta: Int?) -> String {
        var parts: [String] = []
        if let fraction { parts.append("\(Int(fraction * 100))%") } else { parts.append("Starting...") }
        if let speed { parts.append(ByteCountFormatter.string(fromByteCount: Int64(speed), countStyle: .file) + "/s") }
        if let eta { parts.append("\(eta)s left") }
        return parts.joined(separator: " · ")
    }
}
