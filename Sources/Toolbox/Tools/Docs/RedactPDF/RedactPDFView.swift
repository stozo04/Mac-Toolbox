import SwiftUI
import UniformTypeIdentifiers

struct RedactPDFView: View {
    @State private var model = RedactPDFModel.shared
    @State private var targeted = false
    /// A file dropped or chosen while boxes are on the open one, waiting for the go-ahead to replace it.
    @State private var pendingOpen: URL?
    @State private var confirmClose = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if model.hasDocument { viewer } else { empty }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted, perform: drop)
            VStack(spacing: 14) {
                findCard
                redactionsCard
                summaryCard.frame(height: 156)
            }
            .frame(width: 240)
        }
        .confirmationDialog("Close this PDF?", isPresented: $confirmClose) {
            Button("Close and Discard Boxes", role: .destructive) { model.close() }
        } message: {
            Text("The boxes you made are discarded. The PDF itself is never changed.")
        }
        .confirmationDialog("Open another PDF?", isPresented: Binding(get: { pendingOpen != nil }, set: { if !$0 { pendingOpen = nil } })) {
            Button("Open and Discard Boxes", role: .destructive) {
                if let url = pendingOpen { model.open(url) }
                pendingOpen = nil
            }
        } message: {
            Text("The boxes on the open PDF are discarded.")
        }
    }

    // MARK: Empty state

    private var empty: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(Theme.card)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(targeted ? Theme.accent : Theme.tint.opacity(0.12), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                )
            VStack(spacing: 10) {
                Image(systemName: "eye.slash").font(.system(size: 26))
                    .frame(width: 54, height: 54)
                    .background(Theme.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                Text("Drop a PDF Here").font(.headline)
                Text("Drag over anything to black it out, or find a word and cover every match. What's under the boxes is removed, not just hidden.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                Button("Choose PDF...") { choose() }
                if let notice = model.notice {
                    Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.yellow)
                        .multilineTextAlignment(.center).frame(maxWidth: 360)
                }
                Label("Processed on this Mac. Originals stay untouched.", systemImage: "lock.fill")
                    .font(.caption2).foregroundStyle(.secondary).padding(.top, 4)
            }
        }
    }

    // MARK: Viewer

    private var viewer: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            pages
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground(corner: 24)
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(Theme.accent, lineWidth: targeted ? 2 : 0))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(model.fileName).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
            Text("Page \(min(max(model.currentPage ?? 0, 0), model.pageCount - 1) + 1) of \(model.pageCount)")
                .font(.caption).foregroundStyle(.secondary).fixedSize()
            Spacer(minLength: 8)
            Button { model.zoomOut() } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Zoom out").disabled(!model.canZoomOut)
            Button { model.zoomIn() } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Zoom in").disabled(!model.canZoomIn)
            Button { if model.regions.isEmpty { model.close() } else { confirmClose = true } } label: { Image(systemName: "xmark") }
                .help("Close this PDF").disabled(model.isBusy)
        }
        .buttonStyle(.bordered).buttonBorderShape(.roundedRectangle(radius: 6)).controlSize(.small)
    }

    private var pages: some View {
        GeometryReader { geo in
            // Zoom 1 makes a page as wide as the view; the margins and the scroll bar come off first.
            let fit = max(160, geo.size.width - 36)
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(spacing: 14) {
                    ForEach(0..<model.pageCount, id: \.self) { index in
                        RedactPDFPage(model: model, index: index, width: fit * model.zoom)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
                .padding(.vertical, 12)
                .frame(minWidth: geo.size.width)
            }
            .scrollPosition(id: $model.currentPage, anchor: .top)
            .background(Theme.inset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .id(model.documentID)
    }

    // MARK: Find & Redact

    private var findCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Find & Redact").font(.headline)
            Text("Covers every match on every page.").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("Name, email or number", text: $model.query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.redactAll() }
                Button("Redact All") { model.redactAll() }
                    .fixedSize()
                    .disabled(!model.hasDocument || model.isBusy || model.query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .controlSize(.small)
            .disabled(!model.hasDocument)
            if model.isFinding {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Searching…").font(.caption).foregroundStyle(.secondary) }
            } else if let message = model.findMessage {
                Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16).cardBackground(corner: 24)
    }

    // MARK: Redactions

    private var redactionsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Redactions").font(.headline)
                Spacer()
                if model.regions.count > 1 {
                    Button("Clear All") { model.clearRegions() }.buttonStyle(.borderless).font(.caption).disabled(model.isBusy)
                }
            }
            if model.regions.isEmpty {
                Text("Drag over anything on the page to black it out, or find text above.")
                    .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.sortedRegions) { row($0) }
                    }
                }
                .scrollIndicators(.never)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Keep the rest of the page searchable", isOn: $model.keepSearchable)
                    .toggleStyle(.checkbox).font(.caption).disabled(model.isBusy)
                Text("Pages you redact become images, so what's under the boxes is gone for good. With this on, the text that's still visible is recognized again.")
                    .font(.caption2).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    private func row(_ region: RedactPDFModel.Region) -> some View {
        let selected = region.id == model.selectedRegionID
        return HStack(spacing: 8) {
            Text("p. \(region.page + 1)").font(.caption2.weight(.semibold)).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Theme.inset, in: Capsule())
            Text(region.label ?? "Area").font(.callout).lineLimit(1).truncationMode(.tail)
                .foregroundStyle(region.label == nil ? .secondary : .primary)
            Spacer(minLength: 0)
            Button { model.remove(region.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).help("Remove this box").disabled(model.isBusy)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(selected ? Theme.accent.opacity(0.22) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture { model.reveal(region.id) }
    }

    // MARK: Summary

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Redactions").font(.caption).foregroundStyle(.secondary)
            Text("\(model.regions.count)").font(.system(size: 38, weight: .bold)).monospacedDigit()
            status
            Spacer(minLength: 0)
            HStack {
                Spacer()
                if model.isExporting {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Export Redacted PDF") { model.export() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.regions.isEmpty || model.isBusy)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(16).cardBackground(corner: 24)
    }

    @ViewBuilder private var status: some View {
        if let saved = model.saved {
            HStack(spacing: 6) {
                Label("Saved · \(MediaFormat.bytes(saved.bytes))", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green).lineLimit(1)
                Spacer(minLength: 0)
                RevealButton { model.reveal(saved.url) }
            }
        } else if model.isExporting {
            Text("Writing page \(min(model.exportedPages + 1, model.pageCount)) of \(model.pageCount)…").font(.caption).foregroundStyle(.secondary)
        } else if let notice = model.notice {
            Label(notice, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                .lineLimit(3).fixedSize(horizontal: false, vertical: true)
        } else if model.regions.isEmpty {
            Text("Drag on the page to black out an area.").font(.caption).foregroundStyle(.secondary)
        } else {
            let pages = model.redactedPageCount
            Text("On \(pages) page\(pages == 1 ? "" : "s"), which become images when you export.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Opening

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.pdf]
        if panel.runModal() == .OK, let url = panel.url { request(url) }
    }

    private func drop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first(where: { $0.canLoadObject(ofClass: URL.self) }) else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url { DispatchQueue.main.async { request(url) } }
        }
        return true
    }

    /// Opens `url`, asking first when it would throw away boxes.
    private func request(_ url: URL) {
        if model.regions.isEmpty { model.open(url) } else { pendingOpen = url }
    }
}

/// One page with its boxes on top. Drag over empty space to black something out, drag a box to move it, drag its sides or
/// corners to resize it. What is drawn is what is saved: the boxes are solid black, as they are in the exported picture.
private struct RedactPDFPage: View {
    let model: RedactPDFModel
    let index: Int
    let width: CGFloat

    /// What the current drag is doing, decided where it started.
    private enum Session {
        case create(start: CGPoint, id: UUID?)
        case move(id: UUID, original: CGRect, start: CGPoint)
        /// `grab` is how far inside the side the drag began, so the side does not jump to the pointer.
        case resize(id: UUID, edges: RedactEdges, original: CGRect, grab: CGSize)
    }

    @State private var picture: CGImage?
    @State private var session: Session?

    private var pageSize: CGSize { index < model.pageSizes.count ? model.pageSizes[index] : CGSize(width: 612, height: 792) }
    private var size: CGSize { CGSize(width: width, height: width * pageSize.height / max(pageSize.width, 1)) }
    /// Drawn at the screen's own pixel density, but never huge.
    private var pixelWidth: Int { min(Int(width * (NSScreen.main?.backingScaleFactor ?? 2)), 4096) }
    private var regions: [RedactPDFModel.Region] { model.regions(onPage: index) }
    private var isEnabled: Bool { !model.isBusy }

    var body: some View {
        let regions = self.regions
        let selected = regions.first { $0.id == model.selectedRegionID }
        ZStack {
            if let picture {
                Image(decorative: picture, scale: 1).resizable().interpolation(.high)
            } else {
                Rectangle().fill(.white).overlay(ProgressView().controlSize(.small))
            }
            ForEach(regions) { box($0) }
            if isEnabled, let selected { grips(for: selected.rect) }
            Color.clear
                .contentShape(Rectangle())
                .gesture(drag(regions))
                .onContinuousHover { phase in
                    guard isEnabled else { return }
                    switch phase {
                    case .active(let point): cursor(at: point, regions: regions).set()
                    case .ended: NSCursor.arrow.set()
                    }
                }
        }
        .frame(width: size.width, height: size.height)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
        .task(id: pixelWidth) { picture = await model.image(forPage: index, pixelWidth: pixelWidth) ?? picture }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Page \(index + 1)")
    }

    // MARK: Drawing

    private func box(_ region: RedactPDFModel.Region) -> some View {
        let r = screen(region.rect)
        let selected = region.id == model.selectedRegionID
        return Rectangle()
            .fill(.black)
            .overlay(Rectangle().strokeBorder(Theme.accent, lineWidth: selected ? 2 : 0))
            .frame(width: r.width, height: r.height)
            .position(x: r.midX, y: r.midY)
            .allowsHitTesting(false)
    }

    private func grips(for rect: CGRect) -> some View {
        let r = screen(rect)
        let points = [r.minX, r.midX, r.maxX].flatMap { x in [r.minY, r.midY, r.maxY].map { CGPoint(x: x, y: $0) } }
            .filter { !($0.x == r.midX && $0.y == r.midY) }
        return ZStack {
            ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                    .fill(.white)
                    .overlay(RoundedRectangle(cornerRadius: 2.5, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1.5))
                    .frame(width: 9, height: 9)
                    .position(point)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: Dragging

    private func drag(_ regions: [RedactPDFModel.Region]) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isEnabled, size.width > 0, size.height > 0 else { return }
                if session == nil { begin(at: normalized(value.startLocation), regions: regions) }
                update(to: normalized(value.location), regions: regions)
            }
            .onEnded { _ in session = nil }
    }

    /// A press on a box side resizes it, on a box moves it, and on empty space starts a new one.
    private func begin(at start: CGPoint, regions: [RedactPDFModel.Region]) {
        switch RedactImage.hit(at: start, in: regions.map { ($0.id, $0.rect) }, size: size) {
        case .body(let id):
            model.selectedRegionID = id
            session = .move(id: id, original: rect(of: id, in: regions), start: start)
        case .edge(let id, let edges):
            model.selectedRegionID = id
            let original = rect(of: id, in: regions)
            let grab = CGSize(width: edges.contains(.left) ? start.x - original.minX : edges.contains(.right) ? start.x - original.maxX : 0,
                              height: edges.contains(.top) ? start.y - original.minY : edges.contains(.bottom) ? start.y - original.maxY : 0)
            session = .resize(id: id, edges: edges, original: original, grab: grab)
        case nil:
            model.selectedRegionID = nil
            session = .create(start: start, id: nil)
        }
    }

    private func update(to point: CGPoint, regions: [RedactPDFModel.Region]) {
        switch session {
        case .create(let start, let id)?:
            if let id {
                model.setRect(RedactImage.rect(from: start, to: point), of: id)
            } else if abs(point.x - start.x) * size.width >= 3 || abs(point.y - start.y) * size.height >= 3 {
                // A plain click only deselects; the box appears once the pointer has really moved.
                session = .create(start: start, id: model.addRegion(RedactImage.rect(from: start, to: point), onPage: index))
            }
        case .move(let id, let original, let start)?:
            model.setRect(RedactImage.moved(original, by: CGSize(width: point.x - start.x, height: point.y - start.y)), of: id)
        case .resize(let id, let edges, let original, let grab)?:
            model.setRect(RedactImage.resized(original, edges: edges, to: CGPoint(x: point.x - grab.width, y: point.y - grab.height)), of: id)
        case nil:
            break
        }
    }

    private func cursor(at point: CGPoint, regions: [RedactPDFModel.Region]) -> NSCursor {
        switch RedactImage.hit(at: normalized(point), in: regions.map { ($0.id, $0.rect) }, size: size) {
        case .body?: return .openHand
        case .edge(_, let edges)?:
            let horizontal = edges.contains(.left) || edges.contains(.right), vertical = edges.contains(.top) || edges.contains(.bottom)
            return horizontal && vertical ? .crosshair : horizontal ? .resizeLeftRight : .resizeUpDown
        case nil: return .crosshair
        }
    }

    // MARK: Geometry

    private func rect(of id: UUID, in regions: [RedactPDFModel.Region]) -> CGRect { regions.first { $0.id == id }?.rect ?? .zero }

    private func normalized(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(point.x / size.width, 0), 1), y: min(max(point.y / size.height, 0), 1))
    }

    private func screen(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX * size.width, y: rect.minY * size.height, width: rect.width * size.width, height: rect.height * size.height)
    }
}
