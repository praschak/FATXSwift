import Foundation
import FATXCore

public enum BrowserCommand: String, Codable {
    case devices, probe, browse, check, preview, importPreview, importItems, exportItems, mkdir, move, delete, recover, eject
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
    public init() {}
}
public struct DeviceAccessReport: Codable {
    public enum Status: String, Codable { case available, blocked, unverified }
    public let status: Status
    public let message: String
    public let checkedDevices: Int
}
