import Foundation

public struct Partition: Codable {
    public let name: String
    public let offset: UInt64
    public let length: UInt64
}
public enum Partitions {
    public static func table(_ disk: Disk) throws -> [Partition]? {
        let bytes = try disk.read(at: 0, count: 512)
        guard bytes.prefix(16) == DiskFormatter.tableMagic else { return nil }
        let names = ["fatx-e", "fatx-c", "fatx-x", "fatx-y", "fatx-z", "fatx-f", "fatx-g"]
        var result: [Partition] = []
        for n in 0..<14 {
            let i = 48 + n * 32
            if bytes.number(i + 16, 4, .little) & 0x80000000 == 0 { continue }
            let offset = UInt64(bytes.number(i + 20, 4, .little)) * 512
            let length = UInt64(bytes.number(i + 24, 4, .little)) * 512
            try require(offset >= 0x80000 && offset < disk.length && length >= 12288 && length <= disk.length - offset, "Invalid active FATX partition table entry")
            try require(!result.contains { offset < $0.offset + $0.length && $0.offset < offset + length }, "Overlapping active FATX partition table entries")
            result.append(Partition(name: n < names.count ? names[n] : "fatx-p\(n + 1)", offset: offset, length: length))
        }
        try require(!result.isEmpty, "FATX partition table contains no active volumes")
        return result
    }
    public static func named(_ name: String, disk: Disk) throws -> Partition {
        if let table = try table(disk), name.hasPrefix("fatx-") {
            guard let found = table.first(where: { $0.name == name }) else { throw FATXError("Partition is not active in this disk's table: \(name)") }
            return found
        }
        return try named(name, diskLength: disk.length)
    }
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
        if let table = try table(disk) {
            return try table.filter {
                let header = try disk.read(at: $0.offset, count: 4)
                return header == Data("FATX".utf8) || header == Data("XTAF".utf8)
            }
        }
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
