import Foundation

public enum FormatProfile: String, Codable, CaseIterable {
    case retail
    case lba48F = "lba48-f"
    case lba48FG = "lba48-fg"
}
public struct FormatVolume: Codable, Equatable {
    public let name: String
    public let tableIndex: Int
    public let offset: UInt64
    public let length: UInt64
    public let bytesPerCluster: Int
    public let fatEntryBytes: Int
    public let fatLength: UInt64
    public let clusterCount: UInt32
    public var dataOffset: UInt64 { offset + 4096 + fatLength }
}
public struct FormatPlan: Codable, Equatable {
    public let source: String
    public let identity: String
    public let length: UInt64
    public let profile: FormatProfile
    public let volumes: [FormatVolume]
    public let estimatedJournalBytes: UInt64
}
public enum DiskFormatter {
    public static let retailEnd: UInt64 = 0x1dd156000
    public static let maximumDiskBytes: UInt64 = 0x20000000000
    static let tableMagic = Data("****PARTINFO****".utf8)

    public static func plan(disk: Disk, profile: FormatProfile = .lba48FG) throws -> FormatPlan {
        try require(disk.blockSize == 512, "Whole-disk FATX formatting requires 512-byte logical device sectors")
        try require(disk.length >= retailEnd && disk.length <= maximumDiskBytes && disk.length % 512 == 0, "Classic disk layout requires a drive between the retail layout size and 2 TiB")
        let fixed: [(String, Int, UInt64, UInt64)] = [
            ("C", 1, 0x8ca80000, 0x1f400000), ("E", 0, 0xabe80000, 0x1312d6000),
            ("X", 2, 0x80000, 0x2ee00000), ("Y", 3, 0x2ee80000, 0x2ee00000), ("Z", 4, 0x5dc80000, 0x2ee00000)
        ]
        var volumes = try fixed.map { try geometry(name: $0.0, index: $0.1, offset: $0.2, length: $0.3, cluster: 16384) }
        if profile != .retail {
            let extra = disk.length - retailEnd
            try require(extra >= 32 * 1024 * 1024, "Not enough space for extended storage partitions")
            let fSize = profile == .lba48FG ? (extra / 2 / 4096 * 4096) : extra
            volumes.append(try geometry(name: "F", index: 5, offset: retailEnd, length: fSize, cluster: 65536))
            if profile == .lba48FG {
                volumes.append(try geometry(name: "G", index: 6, offset: retailEnd + fSize, length: extra - fSize, cluster: 65536))
            }
        }
        let metadata = volumes.reduce(UInt64(0x80000 + 34 * 512)) { $0 + 4096 + $1.fatLength + UInt64($1.bytesPerCluster) }
        return FormatPlan(source: disk.path, identity: disk.identity, length: disk.length, profile: profile, volumes: volumes,
                          estimatedJournalBytes: metadata + 65536 + (metadata / 1048576 + UInt64(volumes.count * 4) + 4) * 16)
    }
    private static func geometry(name: String, index: Int, offset: UInt64, length: UInt64, cluster: Int) throws -> FormatVolume {
        try require(length > 4096 && offset % 512 == 0 && length % 512 == 0, "Invalid format partition bounds")
        let maximum = length / UInt64(cluster) + 1
        let width = maximum < 0xfff0 ? 2 : 4
        let fat = ((maximum * UInt64(width) + 4095) / 4096) * 4096
        try require(length > 4096 + fat + UInt64(cluster), "Partition is too small")
        let count = (length - 4096 - fat) / UInt64(cluster)
        try require(count > 0 && count <= 0xffffff && length <= 0x10000000000, "Extended FATX partitions must fit the classic 24-bit cluster / 1 TiB limit; choose split F/G")
        return FormatVolume(name: name, tableIndex: index, offset: offset, length: length, bytesPerCluster: cluster, fatEntryBytes: width, fatLength: fat, clusterCount: UInt32(count))
    }
    public static func format(disk: Disk, approvedPlan: FormatPlan, journal path: String) throws {
        try require(disk.writable && disk.journal == nil, "Formatting requires an exclusively opened writable disk")
        let current = try plan(disk: disk, profile: approvedPlan.profile)
        try require(current == approvedPlan, "The device or format plan changed; review a fresh plan before erasing")
        try Pending.validateClear(disk)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let attributes = try FileManager.default.attributesOfFileSystem(forPath: parent)
        if let free = (attributes[.systemFreeSize] as? NSNumber)?.uint64Value {
            try require(free > current.estimatedJournalBytes + 16 * 1024 * 1024, "Insufficient free space for the format undo journal")
        }
        let journal = try UndoJournal(disk: disk, path: path, offset: 0, length: disk.length, wholeDiskFormat: true)
        disk.journal = journal
        defer { disk.journal = nil }
        do {
            var prefix = Data(repeating: 0, count: 0x80000)
            if current.profile != .retail { prefix.replaceSubrange(0..<512, with: partitionTable(current.volumes)) }
            prefix.put(0x42524652, 0x600, 4, .little)
            try disk.write(at: 0, data: prefix)
            try disk.write(at: disk.length - 34 * 512, data: Data(repeating: 0, count: 34 * 512))
            for volume in current.volumes { try writeVolume(disk, volume) }
            for v in current.volumes {
                let volume = try Volume(disk: disk, offset: v.offset, length: v.length)
                let result = try volume.check()
                try require(result.files == 0 && result.directories == 1 && result.usedClusters == 1, "Formatted volume did not pass verification")
            }
            try disk.sync(); try journal.mark("committed\n"); try Pending.clear(disk, journal: journal.path)
        } catch {
            let original = error
            do { try journal.rollback(disk: disk); try journal.mark("rolled-back\n"); try Pending.clear(disk, journal: journal.path) }
            catch { throw FATXError("Format failed (\(original)); rollback failed (\(error)). Recover the format journal before using this disk.") }
            throw original
        }
    }
    static func partitionTable(_ volumes: [FormatVolume]) -> Data {
        var data = Data(repeating: 0, count: 512)
        data.replaceSubrange(0..<16, with: tableMagic)
        for v in volumes {
            let i = 48 + v.tableIndex * 32
            let label = Data(v.name.utf8)
            data.replaceSubrange(i..<i + label.count, with: label)
            data.put(0x80000000, i + 16, 4, .little)
            data.put(UInt32(v.offset / 512), i + 20, 4, .little)
            data.put(UInt32(v.length / 512), i + 24, 4, .little)
        }
        return data
    }
    private static func writeVolume(_ disk: Disk, _ v: FormatVolume) throws {
        var header = Data(repeating: 255, count: 4096)
        header.replaceSubrange(0..<4, with: Data("FATX".utf8))
        header.put(UInt32.random(in: 1...UInt32.max), 4, 4, .little)
        header.put(UInt32(v.bytesPerCluster / 512), 8, 4, .little)
        header.put(1, 12, 4, .little); header.put(0, 16, 2, .little)
        var position: UInt64 = 0
        while position < v.fatLength {
            var bytes = Data(repeating: 0, count: Int(min(1048576, v.fatLength - position)))
            if position == 0 {
                bytes.put(v.fatEntryBytes == 2 ? 0xfff8 : 0xfffffff8, 0, v.fatEntryBytes, .little)
                bytes.put(v.fatEntryBytes == 2 ? 0xffff : 0xffffffff, v.fatEntryBytes, v.fatEntryBytes, .little)
            }
            try disk.write(at: v.offset + 4096 + position, data: bytes); position += UInt64(bytes.count)
        }
        try disk.write(at: v.dataOffset, data: Data(repeating: 255, count: v.bytesPerCluster))
        try disk.write(at: v.offset, data: header)
    }
}
