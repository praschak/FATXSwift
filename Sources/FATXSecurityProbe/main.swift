// atasec: ATA Security (like hdparm --security-*) for USB-SATA/IDE bridges on macOS.
//
// How: IOUSBHost captures the bridge's USB device (kernel drivers are detached),
// reconfigures it so the mass storage interface comes up in Bulk-Only mode, then we
// speak Bulk-Only Transport ourselves and send SAT "ATA PASS-THROUGH(16)" (0x85)
// carrying the ATA security commands.
//
// Requires root (or the entitlement com.apple.vm.device-access) for the capture.

import CryptoKit
import Foundation
import IOKit
import IOUSBHost
import FATXCore
import FATXService

// MARK: - Helpers

struct ToolError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func put32(_ b: inout [UInt8], _ o: Int, _ v: UInt32) {
    b[o] = UInt8(v & 0xff)
    b[o + 1] = UInt8((v >> 8) & 0xff)
    b[o + 2] = UInt8((v >> 16) & 0xff)
    b[o + 3] = UInt8((v >> 24) & 0xff)
}

func get32(_ b: [UInt8], _ o: Int) -> UInt32 {
    UInt32(b[o]) | UInt32(b[o + 1]) << 8 | UInt32(b[o + 2]) << 16 | UInt32(b[o + 3]) << 24
}

func hexString(_ b: [UInt8]) -> String { b.map { String(format: "%02x", $0) }.joined() }

func regProp(_ s: io_service_t, _ key: String, parents: Bool = false) -> Any? {
    let opts: IOOptionBits = parents
        ? IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents) : 0
    return IORegistryEntrySearchCFProperty(s, kIOServicePlane, key as CFString, kCFAllocatorDefault, opts)
}

// MARK: - Find USB mass storage devices

struct Candidate {
    let service: io_service_t
    let vid: Int, pid: Int, ifNum: Int, proto: Int
    let name: String
    var id: String { String(format: "%04x:%04x", vid, pid) }
    var protoName: String {
        switch proto {
        case 0x50: return "Bulk-Only"
        case 0x62: return "UAS"
        default: return String(format: "0x%02x", proto)
        }
    }
}

func findCandidates() -> [Candidate] {
    var iter: io_iterator_t = 0
    guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostInterface"), &iter) == KERN_SUCCESS
    else { return [] }
    defer { IOObjectRelease(iter) }

    var out: [Candidate] = []
    while case let s = IOIteratorNext(iter), s != 0 {
        guard (regProp(s, "bInterfaceClass") as? Int) == 8 else { IOObjectRelease(s); continue }
        out.append(Candidate(
            service: s,
            vid: regProp(s, "idVendor", parents: true) as? Int ?? 0,
            pid: regProp(s, "idProduct", parents: true) as? Int ?? 0,
            ifNum: regProp(s, "bInterfaceNumber") as? Int ?? 0,
            proto: regProp(s, "bInterfaceProtocol") as? Int ?? 0,
            name: (regProp(s, "USB Product Name", parents: true) as? String)
                ?? (regProp(s, "kUSBProductString", parents: true) as? String) ?? "?"
        ))
    }
    return out
}

// MARK: - Bulk-Only Transport + SAT

final class SATDevice {
    enum Dir { case none, inbound(Int), outbound([UInt8]) }
    enum Proto { case nonData, pioIn, pioOut }

    private let device: IOUSBHostDevice
    private let intf: IOUSBHostInterface
    private let pipeIn: IOUSBHostPipe
    private let pipeOut: IOUSBHostPipe
    private var tag: UInt32 = 1

    init(service: io_service_t, ifNum: Int) throws {
        // Capture the whole device (macOS refuses a capture on the interface)
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(service, kIOServicePlane, &parent) == KERN_SUCCESS else {
            throw ToolError("USB device for this interface not found.")
        }
        defer { IOObjectRelease(parent) }

        log("Capturing USB device (macOS drivers are being terminated) …")
        let d = try IOUSBHostDevice(__ioService: parent, options: [.deviceCapture],
                                    queue: nil, interestHandler: nil)
        log("Capture ok")
        do {
            var oldID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &oldID)

            // Real configuration cycle: SET_CONFIGURATION(0) then (1) resets the bridge's
            // UAS state, afterwards the interface comes up on alt setting 0.
            log("Unconfigure …")
            do { try SATDevice.configure(d, value: 0, matchInterfaces: false); log("Unconfigure: ok") }
            catch { log("Unconfigure: \(describe(error))") }
            usleep(200_000)

            var cfgError: Error?
            log("Configuring device without driver matching …")
            do { try SATDevice.configure(d, value: 1, matchInterfaces: false) } catch { cfgError = error }
            log("Configure: \(cfgError.map { describe($0) } ?? "ok")")

            guard let found = SATDevice.waitForInterface(parent, ifNum, notID: oldID) else {
                throw ToolError("Interface \(ifNum) not found after capture"
                                + (cfgError.map { " (configure: \(describe($0)))" } ?? "") + ".")
            }
            let ifService = found.service
            defer { IOObjectRelease(ifService) }
            log("Interface \(ifNum) found (\(found.isNew ? "new object" : "OLD object, reconfiguration had no effect")), opening …")

            let i = try IOUSBHostInterface(__ioService: ifService, options: [],
                                           queue: nil, interestHandler: nil)
            log("Interface open")
            do {
                let bot = try SATDevice.findBulkOnly(i.configurationDescriptor, ifNum)
                let cur = Int(i.interfaceDescriptor.pointee.bAlternateSetting)
                log(String(format: "Bulk-Only: alt %d (current %d), EP in 0x%02x, out 0x%02x",
                           bot.alt, cur, bot.epIn, bot.epOut))
                // UAS bridges usually run on alt 1, Bulk-Only is almost always alt 0
                if cur != bot.alt {
                    try i.selectAlternateSetting(bot.alt)
                    log("Alt setting switched")
                }
                pipeIn = try i.copyPipe(withAddress: bot.epIn)
                pipeOut = try i.copyPipe(withAddress: bot.epOut)
                log("Pipes ok")

                // Bulk-Only Mass Storage Reset + Clear Halt on both endpoints
                do { try SATDevice.botReset(i, ifNum); log("BOT reset: ok") }
                catch { log("BOT reset: \(describe(error))") }
                do { try pipeIn.clearStall(); try pipeOut.clearStall(); log("Clear halt: ok") }
                catch { log("Clear halt: \(describe(error))") }
            } catch {
                i.destroy()
                throw error
            }
            intf = i
        } catch {
            d.destroy()
            throw error
        }
        device = d
    }

    /// Release the interface, reconfigure the device with driver matching, end the capture.
    /// macOS then takes over the drive without replugging (no power loss, unlock persists).
    func close() {
        log("Handing device back to macOS …")
        intf.destroy()
        try? SATDevice.configure(device, value: 1, matchInterfaces: true)
        device.destroy()
    }

    /// Waits for a newly created interface object (different registry ID than before).
    /// If none shows up within 3 s, the old one is used.
    static func waitForInterface(_ dev: io_registry_entry_t, _ ifNum: Int, notID: UInt64)
        -> (service: io_service_t, isNew: Bool)?
    {
        usleep(300_000)
        var fallback: io_service_t = 0
        defer { if fallback != 0 { IOObjectRelease(fallback) } }

        for _ in 0..<30 {
            var it: io_iterator_t = 0
            if IORegistryEntryGetChildIterator(dev, kIOServicePlane, &it) == KERN_SUCCESS {
                defer { IOObjectRelease(it) }
                while case let s = IOIteratorNext(it), s != 0 {
                    guard IOObjectConformsTo(s, "IOUSBHostInterface") != 0,
                          (regProp(s, "bInterfaceNumber") as? Int) == ifNum
                    else { IOObjectRelease(s); continue }
                    var id: UInt64 = 0
                    IORegistryEntryGetRegistryEntryID(s, &id)
                    if id != notID { return (s, true) }
                    if fallback == 0 { fallback = s } else { IOObjectRelease(s) }
                }
            }
            usleep(100_000)
        }
        guard fallback != 0 else { return nil }
        let s = fallback
        fallback = 0
        return (s, false)
    }

    // The IOUSBHost methods below are called through their ObjC selectors because the
    // SDK's Swift import does not expose them cleanly.

    private typealias DeviceRequestFn = @convention(c) (
        AnyObject, Selector, IOUSBDeviceRequest, NSMutableData?, UnsafeMutablePointer<UInt>?,
        TimeInterval, AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> ObjCBool
    private static let deviceRequestSel =
        NSSelectorFromString("sendDeviceRequest:data:bytesTransferred:completionTimeout:error:")

    /// Bulk-Only Mass Storage Reset (class request 0xFF to the interface).
    static func botReset(_ i: IOUSBHostInterface, _ ifNum: Int) throws {
        guard i.responds(to: deviceRequestSel), let imp = i.method(for: deviceRequestSel) else {
            throw ToolError("sendDeviceRequest not available.")
        }
        let fn = unsafeBitCast(imp, to: DeviceRequestFn.self)
        var req = IOUSBDeviceRequest()
        req.bmRequestType = 0x21          // Host->Device, Class, Interface
        req.bRequest = 0xFF               // Bulk-Only Mass Storage Reset
        req.wValue = 0
        req.wIndex = UInt16(ifNum)
        req.wLength = 0
        var done: UInt = 0
        var err: NSError?
        guard fn(i, deviceRequestSel, req, nil, &done, 3, &err).boolValue else {
            throw err ?? ToolError("BOT reset failed.")
        }
    }

    private typealias ConfigureFn = @convention(c) (
        AnyObject, Selector, UInt, ObjCBool, AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> ObjCBool
    private static let configureSel = NSSelectorFromString("configureWithValue:matchInterfaces:error:")

    static func configure(_ d: IOUSBHostDevice, value: UInt, matchInterfaces: Bool) throws {
        guard d.responds(to: configureSel), let imp = d.method(for: configureSel) else {
            throw ToolError("IOUSBHostDevice does not respond to configureWithValue:matchInterfaces:.")
        }
        let fn = unsafeBitCast(imp, to: ConfigureFn.self)
        var err: NSError?
        guard fn(d, configureSel, value, ObjCBool(matchInterfaces), &err).boolValue else {
            throw err ?? ToolError("Configure failed.")
        }
    }

    private typealias SendIOFn = @convention(c) (
        AnyObject, Selector, NSMutableData?, UnsafeMutablePointer<UInt>?, TimeInterval,
        AutoreleasingUnsafeMutablePointer<NSError?>?
    ) -> ObjCBool
    private static let sendIOSel =
        NSSelectorFromString("sendIORequestWithData:bytesTransferred:completionTimeout:error:")

    private static func syncIO(_ pipe: IOUSBHostPipe, _ buf: NSMutableData, timeout: TimeInterval) throws -> Int {
        guard pipe.responds(to: sendIOSel), let imp = pipe.method(for: sendIOSel) else {
            throw ToolError("IOUSBHostPipe does not respond to sendIORequestWithData:bytesTransferred:….")
        }
        let fn = unsafeBitCast(imp, to: SendIOFn.self)
        var done: UInt = 0
        var err: NSError?
        guard fn(pipe, sendIOSel, buf, &done, timeout, &err).boolValue else {
            throw err ?? ToolError("USB transfer failed.")
        }
        return Int(done)
    }

    /// Walks the raw configuration descriptor and finds the Bulk-Only alt setting.
    static func findBulkOnly(_ config: UnsafePointer<IOUSBConfigurationDescriptor>, _ ifNum: Int)
        throws -> (alt: Int, epIn: Int, epOut: Int)
    {
        let total = Int(UInt16(littleEndian: config.pointee.wTotalLength))
        let b = UnsafeRawBufferPointer(start: UnsafeRawPointer(config), count: total)

        var i = 0, alt = 0, epIn = 0, epOut = 0
        var inTarget = false
        var found: (Int, Int, Int)?

        while i + 2 <= total {
            let len = Int(b[i]), type = b[i + 1]
            if len < 2 || i + len > total { break }
            if type == 4, len >= 9 {                       // interface descriptor
                if found == nil, inTarget, epIn != 0, epOut != 0 { found = (alt, epIn, epOut) }
                inTarget = Int(b[i + 2]) == ifNum && b[i + 5] == 8 && b[i + 7] == 0x50
                alt = Int(b[i + 3]); epIn = 0; epOut = 0
            } else if type == 5, len >= 7, inTarget, b[i + 3] & 3 == 2 {   // bulk endpoint
                let addr = Int(b[i + 2])
                if addr & 0x80 != 0 { epIn = addr } else { epOut = addr }
            }
            i += len
        }
        if found == nil, inTarget, epIn != 0, epOut != 0 { found = (alt, epIn, epOut) }
        guard let f = found else {
            throw ToolError("No Bulk-Only interface found. The bridge apparently only speaks UAS.")
        }
        return f
    }

    private func transfer(_ pipe: IOUSBHostPipe, out bytes: [UInt8]? = nil, inLength: Int = 0,
                          timeout: TimeInterval) throws -> [UInt8] {
        let n = bytes?.count ?? inLength
        let buf = try intf.ioData(withCapacity: n)   // length is fixed = capacity
        if let bytes { buf.replaceBytes(in: NSRange(location: 0, length: n), withBytes: bytes) }
        let done = try SATDevice.syncIO(pipe, buf, timeout: timeout)
        return [UInt8](Data(bytes: buf.bytes, count: done))
    }

    /// One SCSI command over Bulk-Only (CBW -> data -> CSW).
    func command(cdb: [UInt8], dir: Dir, timeout: TimeInterval = 10) throws -> (status: UInt8, data: [UInt8]) {
        let t = tag; tag &+= 1

        var cbw = [UInt8](repeating: 0, count: 31)
        put32(&cbw, 0, 0x4342_5355)                         // "USBC"
        put32(&cbw, 4, t)
        switch dir {
        case .none: break
        case .inbound(let n): put32(&cbw, 8, UInt32(n)); cbw[12] = 0x80
        case .outbound(let d): put32(&cbw, 8, UInt32(d.count))
        }
        cbw[14] = UInt8(cdb.count)
        for (k, v) in cdb.enumerated() { cbw[15 + k] = v }
        let op = String(format: "0x%02x", cdb[0]) + (cdb[0] == 0x85 ? String(format: "/ATA 0x%02x", cdb[14]) : "")
        log("CBW #\(t) \(op) …")
        guard try transfer(pipeOut, out: cbw, timeout: 3).count == cbw.count else { throw ToolError("Short command transfer") }
        log("CBW #\(t) sent")

        var data: [UInt8] = []
        var phaseFailed = false
        do {
            switch dir {
            case .none: break
            case .inbound(let n):
                data = try transfer(pipeIn, inLength: n, timeout: timeout)
                log("Data in: \(data.count) bytes")
            case .outbound(let d):
                let sent = try transfer(pipeOut, out: d, timeout: timeout)
                if sent.count != d.count { throw ToolError("Short USB data-out transfer") }
                log("Data out: \(d.count) bytes")
            }
        } catch {
            phaseFailed = true
            log("Data phase: \(describe(error))")
            // Stall in the data phase: clear the pipe and still read the CSW
            if case .outbound = dir { try? pipeOut.clearStall() } else { try? pipeIn.clearStall() }
        }

        var csw: [UInt8]
        do {
            csw = try transfer(pipeIn, inLength: 13, timeout: timeout)
        } catch {
            log("CSW: \(describe(error)), clearing stall and retrying")
            try? pipeIn.clearStall()
            csw = try transfer(pipeIn, inLength: 13, timeout: timeout)
        }
        log("CSW #\(t) status \(csw.count == 13 ? String(csw[12]) : "?(\(csw.count) bytes)")")
        guard csw.count == 13, get32(csw, 0) == 0x5342_5355, get32(csw, 4) == t else {
            throw ToolError("Invalid response (CSW) from the bridge.")
        }
        if csw[12] == 0 && (phaseFailed || (cdb[0] != 0x03 && get32(csw, 8) != 0)) { throw ToolError("Incomplete USB data phase despite success status") }
        return (csw[12], data)
    }

    /// TEST UNIT READY: checks the Bulk-Only transport without ATA pass-through.
    func testUnitReady() throws {
        let r = try command(cdb: [0, 0, 0, 0, 0, 0], dir: .none, timeout: 5)
        // A locked ATA disk can report SCSI CHECK CONDITION to TEST UNIT READY.
        // IDENTIFY below determines its real security state; transport failures
        // and phase errors remain fatal, and no ATA security command is retried.
        guard r.status == 0 || r.status == 1 else { throw ToolError("USB bridge transport failed (status \(r.status))") }
    }

    func requestSense() -> [UInt8]? {
        guard let r = try? command(cdb: [0x03, 0, 0, 0, 32, 0], dir: .inbound(32)), r.status == 0
        else { return nil }
        return r.data
    }

    /// ATA command via SAT ATA PASS-THROUGH(16).
    @discardableResult
    func ata(_ cmd: UInt8, count: UInt8 = 0, proto: Proto, data: [UInt8]? = nil,
             timeout: TimeInterval = 10) throws -> [UInt8] {
        if cmd == 0xEC {
            guard case .pioIn = proto, count == 1, data == nil else { throw ToolError("Invalid IDENTIFY request") }
        } else {
            guard [0xF1, 0xF2, 0xF6].contains(cmd), case .pioOut = proto, count == 1, data?.count == 512 else { throw ToolError("Unsupported ATA security request") }
        }
        var cdb = [UInt8](repeating: 0, count: 16)
        cdb[0] = 0x85
        let dir: Dir
        switch proto {
        case .nonData: cdb[1] = 3 << 1; cdb[2] = 0x00; dir = .none
        case .pioIn:   cdb[1] = 4 << 1; cdb[2] = 0x0E; dir = .inbound(512)   // T_DIR=in, BYTE_BLOCK, T_LENGTH=count
        case .pioOut:  cdb[1] = 5 << 1; cdb[2] = 0x06; dir = .outbound(data ?? [])
        }
        cdb[6] = count
        cdb[13] = 0x40
        cdb[14] = cmd

        let r = try command(cdb: cdb, dir: dir, timeout: timeout)
        switch r.status {
        case 0: return r.data
        case 2: throw ToolError("Phase error from the bridge. Replug the drive.")
        default: throw ToolError(describeSense(requestSense()))
        }
    }
}

func describeSense(_ s: [UInt8]?) -> String {
    guard let s, s.count >= 8 else { return "Command failed (no sense data)." }
    var key = 0, asc = 0, ascq = 0
    var ataErr: UInt8 = 0
    let code = s[0] & 0x7f
    if code == 0x72 || code == 0x73 {                       // descriptor format
        key = Int(s[1] & 0x0f); asc = Int(s[2]); ascq = Int(s[3])
        var i = 8
        let end = min(s.count, 8 + Int(s[7]))
        while i + 1 < end {
            if s[i] == 0x09, i + 3 < s.count { ataErr = s[i + 3] }   // ATA Status Return
            i += Int(s[i + 1]) + 2
        }
    } else if s.count >= 14 {                               // fixed format
        key = Int(s[2] & 0x0f); asc = Int(s[12]); ascq = Int(s[13])
        if asc == 0x00, ascq == 0x1d { ataErr = s[3] }
    }
    let raw = String(format: "Sense %X/%02X/%02X", key, asc, ascq)
    if key == 0x5 {
        return "\(raw): The bridge rejected the command (no ATA pass-through for security?)."
    }
    if key == 0xB || ataErr & 0x04 != 0 {
        return "\(raw): Drive aborted the command (ABRT). Typical causes: wrong password, frozen/locked state, or attempt counter expired."
    }
    return "\(raw): Command failed."
}

// MARK: - IDENTIFY

struct Identify {
    let w: [UInt16]
    init(_ b: [UInt8]) { w = (0..<256).map { UInt16(b[2 * $0]) | UInt16(b[2 * $0 + 1]) << 8 } }

    /// ATA string field, byte-swapped into reading order, untrimmed.
    func rawString(_ a: Int, _ e: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        for x in w[a...e] { bytes += [UInt8(x >> 8), UInt8(x & 0xff)] }
        return bytes
    }

    func str(_ a: Int, _ e: Int) -> String {
        String(decoding: rawString(a, e), as: UTF8.self)
            .trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.controlCharacters))
    }

    var model: String { str(27, 46) }
    var serial: String { str(10, 19) }
    var firmware: String { str(23, 26) }

    var sec: UInt16 { w[128] }
    var supported: Bool { sec & 0x001 != 0 }
    var enabled: Bool { sec & 0x002 != 0 }
    var locked: Bool { sec & 0x004 != 0 }
    var frozen: Bool { sec & 0x008 != 0 }
    var expired: Bool { sec & 0x010 != 0 }
    var enhancedErase: Bool { sec & 0x020 != 0 }
    var maximumLevel: Bool { sec & 0x100 != 0 }
    var masterRevision: UInt16 { w[92] }

    func eraseTime(_ word: Int) -> String {
        let v = Int(w[word] & 0x7fff)
        return v == 0 ? "?" : "approx. \(v * 2) min"
    }
}

func identify(_ d: SATDevice) throws -> Identify {
    let data = try d.ata(0xEC, count: 1, proto: .pioIn)
    guard data.count == 512 else { throw ToolError("IDENTIFY returned \(data.count) instead of 512 bytes.") }
    return Identify(data)
}

func printInfo(_ id: Identify) {
    func yn(_ b: Bool) -> String { b ? "yes" : "no" }
    print("Model:     \(id.model)")
    print("Serial:    \(id.serial)")
    print("Firmware:  \(id.firmware)")
    print("Security:")
    print("  supported:        \(yn(id.supported))")
    print("  password set:     \(yn(id.enabled))")
    print("  locked:           \(yn(id.locked))")
    print("  frozen:           \(yn(id.frozen))")
    print("  count expired:    \(yn(id.expired))")
    print("  level:            \(id.enabled ? (id.maximumLevel ? "maximum" : "high") : "-")")
    print("  master revision:  " + String(format: "0x%04x", id.masterRevision))
    print("  erase time:       \(id.eraseTime(89)), enhanced: \(id.enhancedErase ? id.eraseTime(90) : "n/a")")
}


// The caller unmounts the selected disk. Secrets are accepted through stdin,
// never in command-line arguments or logs.
func log(_ text: String) { }
func describe(_ error: Error) -> String { String(describing: error) }

func usbParentID(_ disk: String) throws -> UInt64 {
    guard disk.range(of: "^/dev/rdisk[0-9]+$", options: .regularExpression) != nil else { throw ToolError("Choose an external whole raw disk") }
    let bsd = String(disk.dropFirst(6)) // rdisk4 -> disk4
    let name = bsd.hasPrefix("r") ? String(bsd.dropFirst()) : bsd
    guard let match = IOBSDNameMatching(kIOMainPortDefault, 0, name) else { throw ToolError("Cannot look up disk in IOKit") }
    var entry: io_registry_entry_t = IOServiceGetMatchingService(kIOMainPortDefault, match)
    guard entry != 0 else { throw ToolError("Disk not found in IOKit") }
    defer { if entry != 0 { IOObjectRelease(entry) } }
    for _ in 0..<32 {
        if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &id) == KERN_SUCCESS, id != 0 else { throw ToolError("Cannot identify USB device") }
            return id
        }
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent) == KERN_SUCCESS, parent != 0 else { break }
        IOObjectRelease(entry); entry = parent
    }
    throw ToolError("Selected disk is not attached through a supported USB device")
}

func perform(_ request: SecurityOperation) throws -> SecurityProbe {
    let disk = request.disk
    guard geteuid() == 0 else { throw ToolError("Administrator authorization is required") }
    try DeviceTools.validateFormatTarget(disk, unmount: false)
    let parentID = try usbParentID(disk)
    // Capturing the USB device disconnects all its storage interfaces. Refuse
    // enclosures that expose another whole disk through the same USB parent.
    for other in try DeviceTools.devices() where other.path != disk {
        guard let otherParent = try? usbParentID(other.path) else {
            throw ToolError("Cannot verify the USB relationship of another external disk. Disconnect it before changing security.")
        }
        if otherParent == parentID {
            throw ToolError("USB adapter exposes multiple disks; disconnect other media before changing security")
        }
    }
    let candidates = findCandidates()
    defer { for candidate in candidates { IOObjectRelease(candidate.service) } }
    let matching = candidates.filter { candidate in
        var parent: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(candidate.service, kIOServicePlane, &parent) == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(parent) }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(parent, &id) == KERN_SUCCESS && id == parentID
    }
    guard matching.count == 1, let candidate = matching.first else { throw ToolError("Could not uniquely match the selected disk to one USB storage interface") }
    let device = try SATDevice(service: candidate.service, ifNum: candidate.ifNum)
    defer { device.close() }
    try device.testUnitReady()
    var id = try identify(device)
    guard id.w[0] != 0 && id.w[0] != 0xffff && id.w[0] & 0x8000 == 0 else { throw ToolError("Invalid ATA IDENTIFY response") }
    func identity(_ value: Identify) throws -> String {
        let model = value.rawString(27, 46), serial = value.rawString(10, 19)
        guard model.contains(where: { $0 != 0 && $0 != 32 }), serial.contains(where: { $0 != 0 && $0 != 32 }) else { throw ToolError("Drive model or serial is empty") }
        return SHA256.hash(data: Data(model + serial)).map { String(format: "%02x", $0) }.joined()
    }
    func flags(_ value: Identify) -> ATASecurityFlags {
        ATASecurityFlags(supported: value.supported, enabled: value.enabled, locked: value.locked, frozen: value.frozen, expired: value.expired, maximum: value.maximumLevel)
    }
    let initialIdentity = try identity(id)
    var derivedPassword: Data?
    if request.action != .inspect {
        guard let expected = request.expected, expected.disk == disk, expected.identity == initialIdentity else { throw ToolError("Drive identity changed. Inspect the disk again before changing security.") }
        guard [request.rawPassword, request.hddKey].compactMap({ $0 }).count == 1 else { throw ToolError("Provide exactly one credential") }
        let password: Data
        if let key = request.hddKey {
            guard !request.master else { throw ToolError("HDD key creates a user password, not a master password") }
            let raw = Data(id.w.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] })
            password = try DrivePassword.derive(key: key, identify: raw, serialFirst: request.serialFirst ?? false)
        } else { password = request.rawPassword! }
        if request.action == .derive {
            guard request.rawPassword == nil else { throw ToolError("Derivation requires an HDD key") }
            derivedPassword = password
        }
        _ = try ATASecurityExecutor.run(action: request.action, initial: flags(id), password: password,
                                        master: request.master, maximum: request.maximum,
            send: { command, block in
                _ = try device.ata(command, count: 1, proto: .pioOut, data: Array(block))
            }, refresh: {
                let next = try identify(device)
                guard try identity(next) == initialIdentity else { throw ToolError("Drive identity changed") }
                id = next
                return flags(next)
            })
    }
    return SecurityProbe(disk: disk, adapter: candidate.name, usbID: candidate.id,
                         model: id.model, serial: id.serial, supported: id.supported,
                         enabled: id.enabled, locked: id.locked, frozen: id.frozen, expired: id.expired,
                         maximum: id.maximumLevel, identity: initialIdentity, derivedPassword: derivedPassword)
}

do {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard input.count <= 65536 else { throw ToolError("Oversized security request") }
    let request = try JSONDecoder().decode(SecurityOperation.self, from: input)
    let value = try perform(request)
    FileHandle.standardOutput.write(try JSONEncoder().encode(value))
} catch {
    FileHandle.standardError.write(Data((String(describing: error) + "\n").utf8))
    exit(1)
}
