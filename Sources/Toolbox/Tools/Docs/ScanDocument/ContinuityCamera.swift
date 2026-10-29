import AppKit
import SwiftUI

/// Lets the view pop up the "Import from iPhone" menu. Continuity Camera is offered by AppKit to the window's first responder:
/// the menu item with the import identifier lists the nearby iPhones and iPads (Take Photo, Scan Documents), and the result
/// comes back through `readSelection(from:)` as a PDF (scans) or an image (photos).
@MainActor
final class ContinuityBridge {
    fileprivate weak var view: ContinuityView?

    /// Shows the menu at the pointer. `choosePhotos` is the fallback entry for a Mac with no iPhone nearby.
    func showMenu(choosePhotos: @escaping () -> Void) { view?.showMenu(choosePhotos: choosePhotos) }
}

struct ContinuityAnchor: NSViewRepresentable {
    let bridge: ContinuityBridge
    let onScan: ([ScanInput]) -> Void

    func makeNSView(context: Context) -> ContinuityView {
        let view = ContinuityView()
        view.onScan = onScan
        bridge.view = view
        return view
    }

    func updateNSView(_ view: ContinuityView, context: Context) {
        view.onScan = onScan
        bridge.view = view
    }
}

final class ContinuityView: NSView, NSServicesMenuRequestor {
    var onScan: (([ScanInput]) -> Void)?
    private var choosePhotos: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    /// Never in the way of a click on what is drawn over it.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func showMenu(choosePhotos: @escaping () -> Void) {
        self.choosePhotos = choosePhotos
        window?.makeFirstResponder(self)
        let menu = NSMenu()
        let item = NSMenuItem(title: "Import from iPhone or iPad", action: nil, keyEquivalent: "")
        item.identifier = NSMenuItem.importFromDeviceIdentifier
        menu.addItem(item)
        menu.addItem(.separator())
        let photos = NSMenuItem(title: "Add Photos…", action: #selector(addPhotos), keyEquivalent: "")
        photos.target = self
        menu.addItem(photos)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func addPhotos() { choosePhotos?() }

    // MARK: NSServicesMenuRequestor

    override func validRequestor(forSendType sendType: NSPasteboard.PasteboardType?, returnType: NSPasteboard.PasteboardType?) -> Any? {
        if sendType == nil, let returnType, returnType == .pdf || NSImage.imageTypes.contains(returnType.rawValue) { return self }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        let inputs = Self.inputs(from: pasteboard)
        guard !inputs.isEmpty else { return false }
        onScan?(inputs)
        return true
    }

    /// A scan arrives as a PDF with one page per sheet; a photo arrives as an image.
    static func inputs(from pasteboard: NSPasteboard) -> [ScanInput] {
        if let pdf = pasteboard.data(forType: .pdf) { return [.pdf(pdf)] }
        let images = (pasteboard.readObjects(forClasses: [NSImage.self]) as? [NSImage]) ?? []
        return images.compactMap { $0.cgImage(forProposedRect: nil, context: nil, hints: nil) }.map { .photo($0) }
    }
}
