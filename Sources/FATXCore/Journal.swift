import Foundation
import CFATXPlatform
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Binary records: UInt64 big-endian offset, UInt32 length, UInt32 CRC32, before-image.
// The JSON header is newline terminated; a complete journal is marked by a
// separate .committed file after source sync. A torn final record is ignored:
// its source write cannot have started before that record's successful fsync.
struct JournalHeader: Codable {
    let version: Int
    let source: String
    let identity: String
    let length: UInt64
    let block: Int
    let partitionOffset: UInt64
    let partitionLength: UInt64
    let superblock: Data
}
final class UndoJournal {
    let handle: FileHandle
    let path: String
    let header: JournalHeader
    var records: [(UInt64, UInt64, Int, UInt32)] = [] // source offset, journal payload offset, length
    init(disk: Disk, path: String, offset: UInt64, length: UInt64) throws {
        self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        try Pending.validateClear(disk)
        try require(!FileManager.default.fileExists(atPath: self.path + ".committed"), "Journal completion marker already exists")
        let fd = open(self.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw systemError("Create new journal") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        header = JournalHeader(version: 2, source: disk.path, identity: disk.identity, length: disk.length, block: disk.blockSize,
                               partitionOffset: offset, partitionLength: length, superblock: try disk.read(at: offset, count: 4096))
        try handle.write(contentsOf: JSONEncoder().encode(header) + Data([10]))
        try handle.durableSync()
        try syncParent(self.path)
        try Pending.begin(disk, journal: self.path)
    }
    func record(offset: UInt64, original: Data) throws {
        try require(original.count <= Int(UInt32.max), "Journal record too large")
        let position = try handle.offset()
        var prefix = Data(count: 12)
        for i in 0..<8 { prefix[i] = UInt8(truncatingIfNeeded: offset >> ((7 - i) * 8)) }
        prefix.put(UInt32(original.count), 8, 4, .big)
        let checksum = CRC32.checksum(prefix, original)
        var crc = Data(count: 4); crc.put(checksum, 0, 4, .big)
        try handle.write(contentsOf: prefix + crc)
        try handle.write(contentsOf: original)
        try handle.durableSync()
        records.append((offset, position + 16, original.count, checksum))
    }
    func rollback(disk: Disk) throws {
        let reader = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? reader.close() }
        for (offset, location, count, checksum) in records.reversed() {
            try reader.seek(toOffset: location)
            let data = try readExactly(reader, count)
            var prefix = Data(count: 12)
            for i in 0..<8 { prefix[i] = UInt8(truncatingIfNeeded: offset >> ((7 - i) * 8)) }
            prefix.put(UInt32(count), 8, 4, .big)
            try require(CRC32.checksum(prefix, data) == checksum, "Journal checksum mismatch during rollback")
            try disk.rawWrite(at: offset, data: data)
        }
        try disk.sync()
    }
    func mark(_ status: String) throws {
        let fd = open(path + ".committed", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw systemError("Create journal completion marker") }
        let marker = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try marker.write(contentsOf: Data(status.utf8)); try marker.durableSync()
        try syncParent(path)
    }
}
func syncParent(_ path: String) throws {
    let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
    let fd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { throw systemError("Open journal directory") }
    defer { close(fd) }
    guard fsync(fd) == 0 else { throw systemError("Flush journal directory") }
}
func readExactly(_ handle: FileHandle, _ count: Int) throws -> Data {
    var result = Data()
    while result.count < count {
        guard let chunk = try handle.read(upToCount: count - result.count), !chunk.isEmpty else { throw FATXError("Truncated file") }
        result.append(chunk)
    }
    return result
}
public enum Recovery {
    public static func restore(disk: Disk, journal journalPath: String) throws {
        let path = URL(fileURLWithPath: journalPath).resolvingSymlinksInPath().path
        try Pending.validateRecovery(disk, journal: path)
        try require(disk.writable, "Recovery needs a writable source")
        try require(!FileManager.default.fileExists(atPath: path + ".committed"), "Journal is already committed or rolled back; refusing stale replay")
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? handle.close() }
        var headerData = Data()
        while true {
            let byte = try readExactly(handle, 1)
            if byte[0] == 10 { break }
            headerData.append(byte)
            try require(headerData.count <= 65536, "Invalid journal header")
        }
        let header = try JSONDecoder().decode(JournalHeader.self, from: headerData)
        try require(header.version == 2 && header.source == disk.path && header.identity == disk.identity && header.length == disk.length && header.block == disk.blockSize, "Journal does not match this source")
        try require(header.partitionOffset <= disk.length && header.partitionLength <= disk.length - header.partitionOffset && header.partitionLength >= 4096, "Invalid journal partition bounds")
        try require(header.superblock == disk.read(at: header.partitionOffset, count: 4096), "Partition header differs from journal")
        let journalLength = try handle.seekToEnd()
        try handle.seek(toOffset: UInt64(headerData.count + 1))
        var records: [(UInt64, UInt64, Int, UInt32)] = []
        while try handle.offset() < journalLength {
            let position = try handle.offset()
            if journalLength - position < 16 { break }
            let prefix = try readExactly(handle, 16)
            var offset: UInt64 = 0
            for byte in prefix.prefix(8) { offset = offset << 8 | UInt64(byte) }
            let count = Int(prefix.number(8, 4, .big))
            try require(count > 0 && count <= 1114112 && offset % UInt64(disk.blockSize) == 0 && count % disk.blockSize == 0, "Invalid journal record")
            try require(offset >= header.partitionOffset && offset <= header.partitionOffset + header.partitionLength && UInt64(count) <= header.partitionOffset + header.partitionLength - offset, "Journal record exceeds selected partition")
            let payload = try handle.offset()
            if UInt64(count) > journalLength - payload { break }
            let checksum = prefix.number(12, 4, .big)
            let original = try readExactly(handle, count)
            try require(CRC32.checksum(Data(prefix.prefix(12)), original) == checksum, "Journal checksum mismatch; no recovery writes performed")
            records.append((offset, payload, count, checksum))
        }
        // Validate every complete record before changing the source.
        for (offset, payload, count, _) in records.reversed() {
            try handle.seek(toOffset: payload)
            try disk.rawWrite(at: offset, data: readExactly(handle, count))
        }
        try disk.sync()
        let markerPath = path + ".committed"
        let fd = open(markerPath, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw systemError("Mark recovered journal") }
        let marker = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try marker.write(contentsOf: Data("recovered\n".utf8)); try marker.durableSync(); try syncParent(path)
        try Pending.clear(disk, journal: path)
    }
}

extension FileHandle {
    func durableSync() throws {
        guard fx_sync(fileDescriptor) == 0 else { throw systemError("Flush journal to stable storage") }
    }
}
