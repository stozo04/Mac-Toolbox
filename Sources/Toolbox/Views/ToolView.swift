import SwiftUI

/// Shell shared by every tool: header with favorite star, then the tool's workspace.
/// Real tool UIs replace `ToolWorkspace` per tool; see features/<Category>/<Tool>/README.md.
struct ToolView: View {
    @Environment(AppState.self) private var state
    let tool: Tool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: tool.symbol).font(.title3)
                    .frame(width: 40, height: 40)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(tool.category.rawValue) · \(tool.tagline)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    HStack {
                        Text(tool.name).font(.system(size: 26, weight: .bold))
                        Button { state.toggleFavorite(tool) } label: {
                            Image(systemName: state.favorites.contains(tool.id) ? "star.fill" : "star")
                                .foregroundStyle(state.favorites.contains(tool.id) ? .yellow : .secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !tool.isImplemented { NotImplementedBanner() }
            ToolWorkspace(tool: tool)
        }
        .padding(16)
    }
}

/// Shown above every tool that still has only a generic placeholder workspace.
struct NotImplementedBanner: View {
    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 40))
            VStack(alignment: .leading, spacing: 4) {
                Text("Feature not implemented").font(.system(size: 22, weight: .bold))
                Text("This tool is not built yet, so nothing here will work.").font(.system(size: 14, weight: .medium))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 20).padding(.vertical, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.warning, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("notImplementedBanner")
    }
}

struct ToolWorkspace: View {
    let tool: Tool

    var body: some View {
        switch tool.input {
        case .dropFiles(let title, let hint, let symbol):
            DropZone(title: title, hint: hint, symbol: symbol)
        case .link:
            DownloadVideoView()
        case .recordScreen:
            RecordScreenView()
        case .trimVideo:
            TrimVideoView()
        case .resizeVideo:
            ResizeVideoView()
        case .compressVideo:
            CompressVideoView()
        case .convertImages:
            ConvertImagesView()
        case .compressImages:
            CompressImagesView()
        case .resizeImages:
            ResizeImagesView()
        case .rotateImages:
            RotateImagesView()
        case .removeMetadata:
            RemoveMetadataView()
        case .colorPicker:
            ColorPickerView()
        case .blurFaces:
            BlurFacesView()
        case .redactImage:
            RedactImageView()
        case .annotateScreenshot:
            AnnotateScreenshotView()
        case .beautifyScreenshot:
            BeautifyScreenshotView()
        case .removeBackground:
            RemoveBackgroundView()
        case .scanDocument:
            ScanDocumentView()
        case .redactPDF:
            RedactPDFView()
        case .burnInSubtitles:
            BurnInSubtitlesView()
        case .muteVideo:
            MuteVideoView()
        case .mediaInfo:
            MediaInfoView()
        case .mac(let tool):
            MacToolView(tool: tool)
        case .videoToGif:
            VideoToGifView()
        case .extractFrames:
            ExtractFramesView()
        case .live(let symbol, let idle, let action):
            LiveWorkspace(symbol: symbol, idle: idle, action: action)
        case .text:
            TextWorkspace()
        }
    }
}
