import AppKit

struct VolumeInfo: Identifiable, Equatable {
    enum Kind: String { case drive = "External drive", card = "Memory card", diskImage = "Disk image" }

    let url: URL
    let name: String
    let kind: Kind
    let capacity: Int64?
    var id: String { url.path }

    var symbol: String {
        switch kind {
        case .drive: "externaldrive"
        case .card: "sdcard"
        case .diskImage: "opticaldiscdrive"
        }
    }
}

enum VolumeScanner {
    /// Whether a mounted volume is something a person plugged in or mounted, as opposed to the startup disk,
    /// system volumes, network shares and Time Machine backups.
    static func isEjectCandidate(path: String, isLocal: Bool, isBrowsable: Bool, isInternal: Bool, isEjectable: Bool,
                                 isRemovable: Bool, isDiskImage: Bool) -> Bool {
        guard isLocal, isBrowsable, path != "/", !path.hasPrefix("/System"), !path.hasPrefix("/private") else { return false }
        return isDiskImage || isEjectable || isRemovable || !isInternal
    }

    /// Mount points of attached disk images, from `hdiutil info -plist`.
    static func diskImageMountPoints(fromPlist data: Data) -> Set<String> {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = plist["images"] as? [[String: Any]] else { return [] }
        var points: Set<String> = []
        for image in images {
            for entity in image["system-entities"] as? [[String: Any]] ?? [] {
                if let mount = entity["mount-point"] as? String { points.insert(mount) }
            }
        }
        return points
    }

    static func diskImages() async -> Set<String> {
        guard let result = try? await Shell.run("/usr/bin/hdiutil", ["info", "-plist"]), result.succeeded else { return [] }
        return diskImageMountPoints(fromPlist: Data(result.out.utf8))
    }

    static func ejectableVolumes(diskImages: Set<String>) -> [VolumeInfo] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsBrowsableKey, .volumeIsInternalKey,
                                      .volumeIsEjectableKey, .volumeIsRemovableKey, .volumeTotalCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            let image = diskImages.contains(url.path)
            guard isEjectCandidate(path: url.path, isLocal: v.volumeIsLocal ?? false, isBrowsable: v.volumeIsBrowsable ?? false,
                                   isInternal: v.volumeIsInternal ?? true, isEjectable: v.volumeIsEjectable ?? false,
                                   isRemovable: v.volumeIsRemovable ?? false, isDiskImage: image) else { return nil }
            let kind: VolumeInfo.Kind = image ? .diskImage : ((v.volumeIsRemovable ?? false) ? .card : .drive)
            return VolumeInfo(url: url, name: v.volumeName ?? url.lastPathComponent, kind: kind, capacity: v.volumeTotalCapacity.map(Int64.init))
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
