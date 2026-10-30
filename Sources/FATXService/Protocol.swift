import Foundation
import FATXCore

public enum BrowserCommand: String, Codable {
    case devices, probe, browse, check, preview, importPreview, importItems, exportItems, mkdir, move, delete, recover, eject, formatPlan, formatDisk, securityProbe, securityOperation
}
public struct BrowserRequest: Codable {
    public var command: BrowserCommand
    public var source = ""
    public var offset: UInt64 = 0
    public var length: UInt64?
    public var sectorSize = 512
    public var directory = "/"
    public var paths: [String] = []
    public var localPaths: [String] = []
    public var destination = ""
    public var journal: String?
    public var replace = false
    public var unmount = false
    public var ownerUID: UInt32?
    public var ownerGID: UInt32?
    public var formatProfile: FormatProfile?
    public var approvedFormat: FormatPlan?
    public var formatConfirmation: String?
    public var securityRequest: SecurityOperation?
    public init(_ command: BrowserCommand) { self.command = command }
}
public struct BrowserItem: Codable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let directory: Bool
    public let size: UInt32
    public let attributes: UInt8
    public let firstCluster: UInt32
    public init(entry: Entry, parent: String) {
        path = (parent == "/" ? "" : parent) + "/" + entry.name
        name = entry.name; directory = entry.isDirectory; size = entry.size
        attributes = entry.attributes; firstCluster = entry.firstCluster
    }
}
public struct BrowserDevice: Codable, Identifiable, Hashable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let size: UInt64
    public init(path: String, name: String, size: UInt64) { self.path = path; self.name = name; self.size = size }
}
public struct BrowserCandidate: Codable, Identifiable, Hashable {
    public var id: String { "\(offset)-\(length)-\(sectorSize)" }
    public let name: String
    public let offset: UInt64
    public let length: UInt64
    public let sectorSize: Int
    public init(name: String, offset: UInt64, length: UInt64, sectorSize: Int) { self.name = name; self.offset = offset; self.length = length; self.sectorSize = sectorSize }
}
public struct BrowserReply: Codable {
    public var success = true
    public var message = ""
    public var items: [BrowserItem] = []
    public var devices: [BrowserDevice] = []
    public var candidates: [BrowserCandidate] = []
    public var info: VolumeInfo?
    public var check: CheckResult?
    public var importPreview: ImportPreview?
    public var preview: String?
    public var deviceAccess: DeviceAccessReport?
    public var formatPlan: FormatPlan?
    public var securityProbe: SecurityProbe?
    public init() {}
}
public struct DeviceAccessReport: Codable {
    public enum Status: String, Codable { case available, blocked, unverified }
    public let status: Status
    public let message: String
    public let checkedDevices: Int
}

public struct SecurityProbe: Codable {
    public let disk: String
    public let adapter: String
    public let usbID: String
    public let model: String
    public let serial: String
    public let supported: Bool
    public let enabled: Bool
    public let locked: Bool
    public let frozen: Bool
    public let expired: Bool
    public let maximum: Bool
    public let identity: String
    public let derivedPassword: Data?
    public init(disk: String, adapter: String, usbID: String, model: String, serial: String, supported: Bool, enabled: Bool, locked: Bool, frozen: Bool, expired: Bool, maximum: Bool, identity: String, derivedPassword: Data? = nil) {
        self.disk = disk; self.adapter = adapter; self.usbID = usbID; self.model = model; self.serial = serial
        self.supported = supported; self.enabled = enabled; self.locked = locked; self.frozen = frozen; self.expired = expired; self.maximum = maximum; self.identity = identity; self.derivedPassword = derivedPassword
    }
    public var withoutSecret: SecurityProbe {
        SecurityProbe(disk: disk, adapter: adapter, usbID: usbID, model: model, serial: serial, supported: supported, enabled: enabled, locked: locked, frozen: frozen, expired: expired, maximum: maximum, identity: identity)
    }
}

public struct SecurityOperation: Codable {
    public var action: ATASecurityAction
    public var disk: String
    public var expected: SecurityProbe?
    public var rawPassword: Data?
    public var hddKey: Data?
    public var serialFirst: Bool?
    public var master: Bool
    public var maximum: Bool
    public init(action: ATASecurityAction, disk: String, expected: SecurityProbe? = nil, rawPassword: Data? = nil, hddKey: Data? = nil, serialFirst: Bool? = nil, master: Bool = false, maximum: Bool = true) {
        self.action = action; self.disk = disk; self.expected = expected; self.rawPassword = rawPassword; self.hddKey = hddKey; self.serialFirst = serialFirst; self.master = master; self.maximum = maximum
    }
}
