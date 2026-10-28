import Foundation

enum MoveError: LocalizedError, Equatable {
    case notMovable(String)
    case downloading(String)
    case alreadyThere
    case appRunning(String)
    case failed(String)
    case noOriginalPlace

    var errorDescription: String? {
        switch self {
        case .notMovable(let reason): reason
        case .downloading(let app): "\(app) is still downloading this model. Try again when it has finished."
        case .alreadyThere: "A file with that name is already in the central folder."
        case .appRunning(let app): "\(app) is open. Quit it first, because this model is on another disk and moving it takes a while."
        case .failed(let what): what
        case .noOriginalPlace: "Toolbox doesn't know where this model was before, so it can't move it back."
        }
    }
}

/// Gathers model files into one folder. The app that used the file keeps finding it: a link stays at the old place.
struct ModelMover {
    var central: URL
    /// Whether an app (by name) is running; only matters for moves between disks.
    var isRunning: (String) -> Bool = { _ in false }

    /// central/<app>/<file>; loose files go in central/Other.
    func destination(for model: InstalledModel) -> URL {
        let folder = (model.owner ?? ModelScanner.looseFolderName).replacingOccurrences(of: "/", with: "-")
        return central.appendingPathComponent(folder).appendingPathComponent(model.url.lastPathComponent)
    }

    @discardableResult
    func move(_ model: InstalledModel) throws -> URL {
        if case .managed(let reason) = model.movability { throw MoveError.notMovable(reason) }
        guard model.movability == .movable else { throw MoveError.notMovable("It is already in the central folder.") }
        let fm = FileManager.default
        let original = model.url
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: original.path, isDirectory: &isDirectory), !isDirectory.boolValue else { throw MoveError.failed("The file is no longer there.") }
        if fm.fileExists(atPath: original.path + ".partial") { throw MoveError.downloading(model.owner ?? "An app") }

        let target = destination(for: model)
        guard !fm.fileExists(atPath: target.path) else { throw MoveError.alreadyThere }
        let size = try fileSize(original)
        do { try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true) } catch { throw MoveError.failed("Could not create the central folder.") }

        if sameDisk(original, target.deletingLastPathComponent()) {
            do { try fm.moveItem(at: original, to: target) } catch { throw MoveError.failed("The file could not be moved.") }
        } else {
            if let owner = model.owner, isRunning(owner) { throw MoveError.appRunning(owner) }
            try copyAcrossDisks(original, to: target, size: size)
            do { try fm.removeItem(at: original) } catch { try? fm.removeItem(at: target); throw MoveError.failed("The original could not be removed.") }
        }

        do {
            try fm.createSymbolicLink(at: original, withDestinationURL: target)
            try verify(link: original, target: target, size: size)
        } catch {
            // Put everything back as it was.
            try? fm.removeItem(at: original)
            try? fm.moveItem(at: target, to: original)
            throw (error as? MoveError) ?? MoveError.failed("The link could not be made, so the file was put back.")
        }
        return target
    }

    /// Undoes `move`: the file goes back where the link is.
    func moveBack(_ model: InstalledModel) throws {
        let fm = FileManager.default
        guard let link = model.linkedFrom.first(where: { (try? fm.destinationOfSymbolicLink(atPath: $0.path)).map { URL(fileURLWithPath: $0).standardizedFileURL == model.url.standardizedFileURL } ?? false })
        else { throw MoveError.noOriginalPlace }
        let size = try fileSize(model.url)
        try fm.removeItem(at: link)
        do {
            if sameDisk(model.url, link.deletingLastPathComponent()) {
                try fm.moveItem(at: model.url, to: link)
            } else {
                try copyAcrossDisks(model.url, to: link, size: size)
                try fm.removeItem(at: model.url)
            }
        } catch {
            try? fm.createSymbolicLink(at: link, withDestinationURL: model.url)
            throw (error as? MoveError) ?? MoveError.failed("The file could not be moved back.")
        }
    }

    // MARK: Safety

    /// The link leads to a file of the same size that can be read from the old place.
    private func verify(link: URL, target: URL, size: Int64) throws {
        let fm = FileManager.default
        guard (try? fm.destinationOfSymbolicLink(atPath: link.path)) == target.path, try fileSize(link) == size else { throw MoveError.failed("The moved file did not check out.") }
        guard let handle = try? FileHandle(forReadingFrom: link) else { throw MoveError.failed("The moved file can't be read from its old place.") }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 4)) ?? Data()
        if link.pathExtension.lowercased() == "gguf", head != Data("GGUF".utf8) { throw MoveError.failed("The moved file did not check out.") }
    }

    private func copyAcrossDisks(_ source: URL, to target: URL, size: Int64) throws {
        let fm = FileManager.default
        let partial = target.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        do {
            try fm.copyItem(at: source, to: partial)
            guard try fileSize(partial) == size else { throw MoveError.failed("The copy came out a different size.") }
            try fm.moveItem(at: partial, to: target)
        } catch {
            try? fm.removeItem(at: partial)
            throw (error as? MoveError) ?? MoveError.failed("The file could not be copied.")
        }
    }

    /// The size of the file itself, through any link. (Not through URL resource values: a URL keeps the first size it read,
    /// which would make a check after the move agree with the one before it whatever happened in between.)
    private func fileSize(_ url: URL) throws -> Int64 {
        guard let size = (try? FileManager.default.attributesOfItem(atPath: url.resolvingSymlinksInPath().path))?[.size] as? NSNumber else {
            throw MoveError.failed("The file could not be read.")
        }
        return size.int64Value
    }

    private func sameDisk(_ a: URL, _ b: URL) -> Bool {
        let first = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        let second = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier as? NSObject
        return first != nil && first == second
    }
}
