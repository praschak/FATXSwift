import Foundation

public struct Partition: Codable {
    public let name: String
    public let offset: UInt64
    public let length: UInt64
}
public enum Partitions {
    // Only established fixed layouts. An explicit length is required for custom
    // offsets: wrong lengths can silently change FAT width and data offsets.
    public static func named(_ name: String, diskLength: UInt64) throws -> Partition {
        let fixed: [String: (UInt64, UInt64)] = [
            "fatx-x": (0x80000, 0x2ee00000), "fatx-y": (0x2ee80000, 0x2ee00000),
            "fatx-z": (0x5dc80000, 0x2ee00000), "fatx-c": (0x8ca80000, 0x1f400000),
            "fatx-e": (0xabe80000, 0x1312d6000),
            "360-sysext": (0x10c080000, 0xce30000), "360-sysext2": (0x118eb0000, 0x8000000),
            "360-compat": (0x120eb0000, 0x10000000)
        ]
        let start: UInt64, size: UInt64
        if name == "360-data" { start = 0x130eb0000; size = diskLength > start ? diskLength - start : 0 }
        else if name == "360-mu" { start = 0x7ff000; size = diskLength > start ? diskLength - start : 0 }
        else if let pair = fixed[name] { start = pair.0; size = pair.1 }
        else { throw FATXError("Unknown partition name: \(name)") }
        try require(start < diskLength && size > 0 && size <= diskLength - start, "Partition does not fit source")
        return Partition(name: name, offset: start, length: size)
    }
    public static func scan(_ disk: Disk) throws -> [Partition] {
        let names = ["fatx-x", "fatx-y", "fatx-z", "fatx-c", "fatx-e", "360-sysext", "360-sysext2", "360-compat", "360-data", "360-mu"]
        var candidates: [Partition] = [Partition(name: "volume-at-zero", offset: 0, length: disk.length)]
        for name in names { if let p = try? named(name, diskLength: disk.length) { candidates.append(p) } }
        var found: [Partition] = []
        for p in candidates {
            let bytes = try disk.read(at: p.offset, count: 4)
            if bytes == Data("FATX".utf8) || bytes == Data("XTAF".utf8) { found.append(p) }
        }
        return found
    }
}
