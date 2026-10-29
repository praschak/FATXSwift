import Foundation
import FATXCore

public enum DeviceTools {
    public static func run(_ path: String, _ args: [String]) throws -> Data {
        let p = Process(), output = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = args
        p.standardOutput = output; p.standardError = FileHandle.standardError
        try p.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FATXError("\(URL(fileURLWithPath: path).lastPathComponent) exited with status \(p.terminationStatus)") }
        return bytes
    }
    static func plist(_ args: [String]) throws -> [String: Any] {
        let bytes = try run("/usr/sbin/diskutil", args)
        guard let object = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any] else { throw FATXError("Invalid diskutil response") }
        return object
    }
    public static func devices() throws -> [BrowserDevice] {
        #if os(macOS)
        let result = try plist(["list", "-plist", "external", "physical"])
        return (result["AllDisksAndPartitions"] as? [[String: Any]] ?? []).compactMap { node in
            guard let id = node["DeviceIdentifier"] as? String else { return nil }
            let details = try? plist(["info", "-plist", id])
            return BrowserDevice(path: "/dev/r" + id, name: details?["MediaName"] as? String ?? id, size: (node["Size"] as? NSNumber)?.uint64Value ?? 0)
        }
        #else
        return []
        #endif
    }
    public static func validate(_ source: String, writable: Bool, unmount: Bool = false) throws {
        guard source.hasPrefix("/dev/") else { return }
        #if os(macOS)
        guard source.range(of: "^/dev/rdisk[0-9]+$", options: .regularExpression) != nil else { throw FATXError("Choose an external whole raw disk (/dev/rdiskN)") }
        let info = try plist(["info", "-plist", source])
        guard info["WholeDisk"] as? Bool == true, info["Internal"] as? Bool == false else { throw FATXError("Only external whole disks are supported") }
        if unmount { _ = try run("/usr/sbin/diskutil", ["unmountDisk", source]) }
        let tree = try plist(["list", "-plist", source])
        func walk(_ node: Any) throws {
            if let dict = node as? [String: Any] {
                if writable, let content = dict["Content"] as? String, content.contains("APFS") || content.contains("HFS") { throw FATXError("Refusing raw writes to a disk containing APFS/HFS partitions") }
                if let id = dict["DeviceIdentifier"] as? String {
                    let details = try plist(["info", "-plist", id])
                    if details["Mounted"] as? Bool == true { throw FATXError("The disk is mounted. Disconnect and use Unmount & Open.") }
                }
                for child in dict.values { try walk(child) }
            } else if let array = node as? [Any] { for child in array { try walk(child) } }
        }
        try walk(tree)
        #else
        throw FATXError("Raw device access requires macOS")
        #endif
    }
    public static func eject(_ source: String) throws {
        try validate(source, writable: false)
        guard source.hasPrefix("/dev/") else { return }
        _ = try run("/usr/sbin/diskutil", ["eject", source])
    }
}
