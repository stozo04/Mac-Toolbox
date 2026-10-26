import CoreGraphics
import Foundation
import IOKit

/// Talks to one monitor over the Apple-silicon display connection. The calls come from a private part of IOKit,
/// so they are looked up at run time: on a Mac without them, monitors simply show as not controllable.
final class AVServiceBus: @unchecked Sendable {
    private typealias CreateFn = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias WriteFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn
    private typealias ReadFn = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private static let create = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceCreateWithService").map { unsafeBitCast($0, to: CreateFn.self) }
    private static let write = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceWriteI2C").map { unsafeBitCast($0, to: WriteFn.self) }
    private static let read = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOAVServiceReadI2C").map { unsafeBitCast($0, to: ReadFn.self) }

    static var isAvailable: Bool { create != nil && write != nil && read != nil }

    private let service: CFTypeRef
    /// One conversation at a time per monitor.
    private let queue = DispatchQueue(label: "toolbox.ddc")

    private init(service: CFTypeRef) { self.service = service }

    /// The EDID UUID of each external monitor, paired with the connection that reaches it. The registry lists a
    /// monitor and then its connection, so the pairing follows that order.
    static func externalBuses() -> [(edidUUID: String?, bus: AVServiceBus)] {
        guard let create else { return [] }
        var iterator: io_iterator_t = 0
        guard IORegistryCreateIterator(kIOMainPortDefault, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [(String?, AVServiceBus)] = []
        var lastUUID: String?
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            if let uuid = IORegistryEntryCreateCFProperty(entry, "EDID UUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String {
                lastUUID = uuid
            }
            guard IOObjectConformsTo(entry, "DCPAVServiceProxy") != 0,
                  let location = IORegistryEntryCreateCFProperty(entry, "Location" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
                  location == "External",
                  let service = create(kCFAllocatorDefault, entry)?.takeRetainedValue() else { continue }
            found.append((lastUUID, AVServiceBus(service: service)))
            lastUUID = nil
        }
        return found
    }

    /// Current and maximum value of a control, or nil when the monitor doesn't answer.
    func read(_ control: DDC.Control) async -> (current: Int, max: Int)? {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.readNow(control)) }
        }
    }

    func write(_ control: DDC.Control, raw: UInt16) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: self.writeNow(control, raw: raw)) }
        }
    }

    private func readNow(_ control: DDC.Control) -> (current: Int, max: Int)? {
        guard let write = Self.write, let read = Self.read else { return nil }
        for _ in 0..<4 {
            var request = DDC.getRequestPacket(vcp: control.vcp)
            guard write(service, DDC.chipAddress, DDC.sourceAddress, &request, UInt32(request.count)) == kIOReturnSuccess else { usleep(20_000); continue }
            usleep(50_000) // the monitor needs a moment to prepare its answer
            var reply = [UInt8](repeating: 0, count: 12)
            // Replies are read from address 0, unlike requests which are written to the host source address 0x51.
            if read(service, DDC.chipAddress, DDC.replyAddress, &reply, UInt32(reply.count)) == kIOReturnSuccess,
               let value = DDC.parseReply(reply, vcp: control.vcp) { return value }
            usleep(20_000)
        }
        return nil
    }

    private func writeNow(_ control: DDC.Control, raw: UInt16) -> Bool {
        guard let write = Self.write else { return false }
        for _ in 0..<2 {
            var packet = DDC.setPacket(vcp: control.vcp, value: raw)
            if write(service, DDC.chipAddress, DDC.sourceAddress, &packet, UInt32(packet.count)) == kIOReturnSuccess { return true }
            usleep(20_000)
        }
        return false
    }
}
