import Foundation

public struct Entry {
    public let name: String
    public let nameData: Data
    public let attributes: UInt8
    public let firstCluster: UInt32
    public let size: UInt32
    public let offset: UInt64
    let raw: Data
    public var isDirectory: Bool { attributes & 0x10 != 0 }
}
public struct VolumeInfo: Codable {
    public let offset: UInt64
    public let length: UInt64
    public let byteOrder: ByteOrder
    public let bytesPerCluster: Int
    public let fatEntryBytes: Int
    public let clusterCount: UInt32
    public let rootCluster: UInt32
    public let dataOffset: UInt64
}
public struct CheckResult: Codable {
    public var files = 0
    public var directories = 0
    public var usedClusters: UInt64 = 0
    public var freeClusters: UInt64 = 0
    public var badClusters: UInt64 = 0
}
public final class Volume {
    public let disk: Disk
    public let info: VolumeInfo
    let fatOffset: UInt64
    let fatLength: UInt64
    let sectorSize: Int
    var fatPageStart: UInt64 = UInt64.max
    var fatPage = Data()
    var transactionActive = false
    var eoc: UInt32 { info.fatEntryBytes == 2 ? 0xffff : 0xffffffff }
    var bad: UInt32 { eoc - 8 }
    var reserved: UInt32 { eoc - 15 }
    public init(disk: Disk, offset: UInt64 = 0, length: UInt64? = nil, sectorSize: Int = 512) throws {
        let size = length ?? (offset <= disk.length ? disk.length - offset : 0)
        try require([512, 4096].contains(sectorSize), "Sector size must be 512 or 4096")
        try require(offset <= disk.length && size <= disk.length - offset && size >= 12288, "Invalid partition bounds")
        try require(offset % UInt64(disk.blockSize) == 0 && size % UInt64(disk.blockSize) == 0 && size % UInt64(sectorSize) == 0, "Partition must align to device blocks and filesystem sectors")
        let header = try disk.read(at: offset, count: 4096)
        let magic = String(decoding: header.prefix(4), as: UTF8.self)
        let order: ByteOrder
        switch magic { case "FATX": order = .little; case "XTAF": order = .big; default: throw FATXError("No FATX/XTAF header at selected offset") }
        let spc = header.number(8, 4, order)
        try require(spc > 0 && spc <= 1024 && spc.nonzeroBitCount == 1, "Unsupported sectors per cluster")
        let cluster = UInt64(spc) * UInt64(sectorSize)
        try require(cluster <= 524288 && (order != .big || cluster >= 4096), "Unsupported cluster size")
        let maximum = size / cluster + 1
        let width = maximum < 0xfff0 ? 2 : 4
        let fatBytes = (maximum * UInt64(width) + 4095) / 4096 * 4096
        try require(fatBytes + 4096 < size, "Partition too small for FAT")
        let clusters = (size - 4096 - fatBytes) / cluster
        try require(clusters > 0 && clusters < 0x10000000, "Unsupported cluster count (extended FATX layouts are not supported)")
        let root = header.number(12, 4, order)
        try require(root > 0 && UInt64(root) <= clusters, "Invalid root directory cluster")
        self.disk = disk; self.sectorSize = sectorSize
        fatOffset = offset + 4096; fatLength = fatBytes
        info = VolumeInfo(offset: offset, length: size, byteOrder: order, bytesPerCluster: Int(cluster), fatEntryBytes: width,
                          clusterCount: UInt32(clusters), rootCluster: root, dataOffset: offset + 4096 + fatBytes)
    }
    func clusterOffset(_ cluster: UInt32) throws -> UInt64 {
        try require(cluster > 0 && cluster <= info.clusterCount, "Cluster \(cluster) is out of range")
        return info.dataOffset + UInt64(cluster - 1) * UInt64(info.bytesPerCluster)
    }
    func fat(_ cluster: UInt32) throws -> UInt32 {
        try require(cluster <= info.clusterCount, "FAT index out of range")
        let relative = UInt64(cluster) * UInt64(info.fatEntryBytes)
        let page = relative / 65536 * 65536
        if page != fatPageStart {
            fatPage = try disk.read(at: fatOffset + page, count: Int(min(65536, fatLength - page)))
            fatPageStart = page
        }
        return fatPage.number(Int(relative - page), info.fatEntryBytes, info.byteOrder)
    }
    func setFat(_ cluster: UInt32, _ value: UInt32) throws {
        _ = try clusterOffset(cluster)
        var bytes = Data(count: info.fatEntryBytes)
        bytes.put(value, 0, bytes.count, info.byteOrder)
        try disk.write(at: fatOffset + UInt64(cluster) * UInt64(bytes.count), data: bytes)
        fatPageStart = UInt64.max
    }
    func chain(_ first: UInt32) throws -> [UInt32] {
        if first == 0 { return [] }
        var seen = Set<UInt32>(), result: [UInt32] = [], current = first
        while true {
            _ = try clusterOffset(current)
            try require(seen.insert(current).inserted, "Cluster chain contains a cycle")
            result.append(current)
            let next = try fat(current)
            if next >= eoc - 7 { break }
            try require(next != 0 && next < reserved, "Free, bad, or reserved cluster in active chain")
            current = next
        }
        return result
    }
    public func entries(cluster: UInt32) throws -> [Entry] {
        var result: [Entry] = []
        for c in try chain(cluster) {
            let start = try clusterOffset(c)
            let bytes = try disk.read(at: start, count: info.bytesPerCluster)
            for i in stride(from: 0, to: bytes.count, by: 64) {
                let n = Int(bytes[i])
                if n == 0 || n == 255 { return result }
                if n == 229 { continue }
                try require(n <= 42, "Invalid directory name length at \(start + UInt64(i))")
                let raw = Data(bytes[i..<i + 64]), name = Data(raw[2..<2 + n])
                try validateName(name)
                let display = name.map { String(UnicodeScalar(Int($0))!) }.joined()
                result.append(Entry(name: display, nameData: name, attributes: raw[1], firstCluster: raw.number(44, 4, info.byteOrder),
                                    size: raw.number(48, 4, info.byteOrder), offset: start + UInt64(i), raw: raw))
            }
        }
        return result
    }
    func rootEntry() -> Entry {
        Entry(name: "/", nameData: Data(), attributes: 0x10, firstCluster: info.rootCluster, size: 0, offset: 0, raw: Data())
    }
    public func lookup(_ path: String) throws -> Entry {
        var current = rootEntry()
        for part in try components(path) {
            try require(current.isDirectory, "Path component is not a directory")
            let bytes = try lookupBytes(part)
            let matches = try entries(cluster: current.firstCluster).filter { folded($0.nameData) == folded(bytes) }
            try require(matches.count == 1, matches.isEmpty ? "Path does not exist: \(path)" : "Ambiguous case-insensitive path")
            current = matches[0]
        }
        return current
    }
    func lookupBytes(_ name: String) throws -> Data {
        var bytes = Data()
        for scalar in name.unicodeScalars {
            try require(scalar.value <= 255, "Existing FATX names use single-byte characters")
            bytes.append(UInt8(scalar.value))
        }
        return bytes
    }
    public func list(_ path: String = "/") throws -> [Entry] {
        let entry = try lookup(path)
        try require(entry.isDirectory, "Path is not a directory")
        return try entries(cluster: entry.firstCluster)
    }
    public func stream(_ path: String, consume: (Data) throws -> Void) throws {
        let entry = try lookup(path)
        try require(!entry.isDirectory, "Cannot read a directory as a file")
        let clusters = try chain(entry.firstCluster)
        try require(UInt64(clusters.count) * UInt64(info.bytesPerCluster) >= UInt64(entry.size), "File chain is shorter than file size")
        var remaining = Int(entry.size)
        for c in clusters where remaining > 0 {
            let n = min(remaining, info.bytesPerCluster)
            try consume(disk.read(at: clusterOffset(c), count: n)); remaining -= n
        }
    }
    public func check() throws -> CheckResult {
        var result = CheckResult()
        var claimed = [UInt8](repeating: 0, count: (Int(info.clusterCount) + 8) / 8)
        var queue = [rootEntry()], index = 0
        func claim(_ c: UInt32) throws {
            let i = Int(c), mask = UInt8(1 << (i % 8))
            try require(claimed[i / 8] & mask == 0, "Cross-linked cluster \(c)")
            claimed[i / 8] |= mask; result.usedClusters += 1
        }
        while index < queue.count {
            let entry = queue[index]; index += 1
            let clusters = try chain(entry.firstCluster)
            for c in clusters { try claim(c) }
            if entry.isDirectory {
                try require(!clusters.isEmpty, "Directory has no cluster")
                result.directories += 1
                var names = Set<Data>()
                for child in try entries(cluster: entry.firstCluster) {
                    try require(names.insert(folded(child.nameData)).inserted, "Duplicate case-insensitive name")
                    queue.append(child)
                }
            } else {
                result.files += 1
                let needed = (UInt64(entry.size) + UInt64(info.bytesPerCluster) - 1) / UInt64(info.bytesPerCluster)
                // Some formatters preallocate one cluster for an empty file.
                try require(UInt64(clusters.count) == needed || (entry.size == 0 && clusters.count == 1), "File size and allocation disagree: \(entry.name)")
            }
        }
        for c in UInt32(1)...info.clusterCount {
            let value = try fat(c)
            let owned = claimed[Int(c) / 8] & UInt8(1 << (Int(c) % 8)) != 0
            if value == 0 { try require(!owned, "Live cluster marked free"); result.freeClusters += 1 }
            else if value == bad { try require(!owned, "Live cluster marked bad"); result.badClusters += 1 }
            else { try require(owned, "Orphan or reserved allocation at cluster \(c); repair with a dedicated tool before writing") }
        }
        return result
    }
    public func transaction(journal path: String, _ work: () throws -> Void) throws {
        try require(disk.writable && !transactionActive && disk.journal == nil, "Writable source and no active transaction required")
        try Pending.validateClear(disk)
        _ = try check()
        let journal = try UndoJournal(disk: disk, path: path, offset: info.offset, length: info.length)
        disk.journal = journal; transactionActive = true
        defer { disk.journal = nil; transactionActive = false; fatPageStart = UInt64.max }
        do {
            try work()
            fatPageStart = UInt64.max
            _ = try check()
            try disk.sync()
            try journal.mark("committed\n")
            try Pending.clear(disk, journal: journal.path)
        } catch {
            let original = error
            do {
                try journal.rollback(disk: disk); try journal.mark("rolled-back\n")
                try Pending.clear(disk, journal: journal.path)
            }
            catch { throw FATXError("Operation failed (\(original)); rollback failed (\(error)). Keep the source disconnected and run recover with this journal.") }
            throw original
        }
    }
}
