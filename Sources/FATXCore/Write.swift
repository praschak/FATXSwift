import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

extension Volume {
    func writing() throws { try require(transactionActive, "Mutations must run inside transaction(journal:)") }
    func updateFat(_ changes: [(UInt32, UInt32)]) throws {
        var pages: [UInt64: [(UInt32, UInt32)]] = [:]
        for change in changes {
            _ = try clusterOffset(change.0)
            let page = UInt64(change.0) * UInt64(info.fatEntryBytes) / 65536 * 65536
            pages[page, default: []].append(change)
        }
        for page in pages.keys.sorted() {
            var bytes = try disk.read(at: fatOffset + page, count: Int(min(65536, fatLength - page)))
            for (cluster, value) in pages[page]! {
                bytes.put(value, Int(UInt64(cluster) * UInt64(info.fatEntryBytes) - page), info.fatEntryBytes, info.byteOrder)
            }
            try disk.write(at: fatOffset + page, data: bytes)
        }
        fatPageStart = UInt64.max
    }
    func allocate(_ count: Int) throws -> [UInt32] {
        if count == 0 { return [] }
        var found: [UInt32] = []
        for c in UInt32(1)...info.clusterCount where try fat(c) == 0 {
            found.append(c)
            if found.count == count { break }
        }
        try require(found.count == count, "Not enough free clusters")
        try updateFat(found.enumerated().map { (i, c) in (c, i + 1 < found.count ? found[i + 1] : eoc) })
        return found
    }
    func release(_ first: UInt32) throws { try updateFat(chain(first).map { ($0, 0) }) }
    func parentAndName(_ path: String) throws -> (Entry, Data) {
        var parts = try components(path)
        try require(!parts.isEmpty, "Cannot modify the root entry")
        let name = try nameBytes(parts.removeLast())
        let parent = try lookup("/" + parts.joined(separator: "/"))
        try require(parent.isDirectory && parent.attributes & 1 == 0, "Parent must be a writable directory")
        return (parent, name)
    }
    func find(_ name: Data, in parent: Entry) throws -> Entry? {
        try entries(cluster: parent.firstCluster).first { folded($0.nameData) == folded(name) }
    }
    func freeSlot(in parent: Entry) throws -> UInt64 {
        let clusters = try chain(parent.firstCluster)
        for (ci, c) in clusters.enumerated() {
            let start = try clusterOffset(c)
            let bytes = try disk.read(at: start, count: info.bytesPerCluster)
            for i in stride(from: 0, to: bytes.count, by: 64) {
                let n = bytes[i]
                if n == 229 { return start + UInt64(i) }
                if n == 0 || n == 255 {
                    // Preserve the end marker, including when the original end
                    // falls on the last slot of a non-final directory cluster.
                    if i + 64 < bytes.count {
                        try disk.write(at: start + UInt64(i + 64), data: Data(repeating: 255, count: 64))
                    } else if ci + 1 < clusters.count {
                        try disk.write(at: clusterOffset(clusters[ci + 1]), data: Data(repeating: 255, count: 64))
                    }
                    return start + UInt64(i)
                }
            }
        }
        let extra = try allocate(1)[0]
        try disk.write(at: clusterOffset(extra), data: Data(repeating: 255, count: info.bytesPerCluster))
        guard let last = clusters.last else { throw FATXError("Directory is unallocated") }
        try setFat(last, extra)
        return try clusterOffset(extra)
    }
    // FAT-style date (upper 16 bits) and time (lower 16 bits), with console-specific epochs.
    func timestamp(_ date: Date = Date()) -> UInt32 {
        let fields = Calendar(identifier: .gregorian).dateComponents(in: .current, from: date)
        let epoch = info.byteOrder == .little ? 2000 : 1980
        let year = UInt32(min(epoch + 127, max(epoch, fields.year ?? epoch)) - epoch)
        let month = UInt32(fields.month ?? 1), day = UInt32(fields.day ?? 1)
        let hour = UInt32(fields.hour ?? 0), minute = UInt32(fields.minute ?? 0), seconds = UInt32((fields.second ?? 0) / 2)
        return year << 25 | month << 21 | day << 16 | hour << 11 | minute << 5 | seconds
    }
    func makeEntry(name: Data, attributes: UInt8, first: UInt32, size: UInt32, previous: Data? = nil) -> Data {
        var bytes = previous ?? Data(repeating: 0, count: 64)
        bytes[0] = UInt8(name.count); bytes[1] = attributes
        bytes.replaceSubrange(2..<44, with: Data(repeating: 255, count: 42))
        bytes.replaceSubrange(2..<2 + name.count, with: name)
        bytes.put(first, 44, 4, info.byteOrder); bytes.put(size, 48, 4, info.byteOrder)
        let now = timestamp()
        if previous == nil { bytes.put(now, 52, 4, info.byteOrder); bytes.put(now, 60, 4, info.byteOrder) }
        bytes.put(now, 56, 4, info.byteOrder)
        return bytes
    }
    public func mkdir(_ path: String) throws {
        try writing()
        let (parent, name) = try parentAndName(path)
        try require(try find(name, in: parent) == nil, "Destination already exists")
        let slot = try freeSlot(in: parent), first = try allocate(1)[0]
        try disk.write(at: clusterOffset(first), data: Data(repeating: 255, count: info.bytesPerCluster))
        try disk.write(at: slot, data: makeEntry(name: name, attributes: 0x10, first: first, size: 0))
    }
    public func put(localPath: String, to path: String, replace: Bool = false) throws {
        try writing()
        let (parent, name) = try parentAndName(path)
        let old = try find(name, in: parent)
        try require(old == nil || replace, "Destination exists; use --replace")
        if let old { try require(!old.isDirectory && old.attributes & 1 == 0, "Cannot replace a directory or read-only file") }
        let input = try FileHandle(forReadingFrom: URL(fileURLWithPath: localPath)); defer { try? input.close() }
        var st = stat(), source = stat()
        guard fstat(input.fileDescriptor, &st) == 0 && fstat(disk.fd, &source) == 0 else { throw systemError("Stat input") }
        try require(st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && st.st_size >= 0 && UInt64(st.st_size) <= UInt64(UInt32.max), "Input must be a regular file smaller than 4 GiB")
        try require(st.st_dev != source.st_dev || st.st_ino != source.st_ino, "Cannot import source into itself")
        let count = Int(st.st_size), slot = try old?.offset ?? freeSlot(in: parent)
        // Copy-on-write replacement keeps the old chain until the new entry is written.
        let clusters = try allocate((count + info.bytesPerCluster - 1) / info.bytesPerCluster)
        var remaining = count, i = 0
        while i < clusters.count {
            var end = i + 1
            while end < clusters.count && clusters[end] == clusters[end - 1] + 1 && (end - i + 1) * info.bytesPerCluster <= 1048576 { end += 1 }
            let capacity = (end - i) * info.bytesPerCluster, n = min(remaining, capacity)
            var data = try readExactly(input, n)
            data.append(Data(repeating: 0, count: capacity - n))
            try disk.write(at: clusterOffset(clusters[i]), data: data)
            remaining -= n; i = end
        }
        let extra = try input.read(upToCount: 1)
        var final = stat()
        guard fstat(input.fileDescriptor, &final) == 0 else { throw systemError("Recheck input") }
        try require(extra?.isEmpty != false && final.st_size == st.st_size, "Input changed during import")
        try disk.write(at: slot, data: makeEntry(name: name, attributes: old?.attributes ?? 0x20, first: clusters.first ?? 0,
                                               size: UInt32(count), previous: old?.raw))
        if let old { try release(old.firstCluster) }
    }
    public func remove(_ path: String) throws {
        try writing()
        let (parent, name) = try parentAndName(path)
        guard let entry = try find(name, in: parent) else { throw FATXError("Path does not exist") }
        try require(entry.attributes & 1 == 0, "Entry is read-only")
        if entry.isDirectory { try require(try entries(cluster: entry.firstCluster).isEmpty, "Directory is not empty") }
        var bytes = entry.raw; bytes[0] = 229
        try disk.write(at: entry.offset, data: bytes)
        try release(entry.firstCluster)
    }
    public func move(_ from: String, to: String) throws {
        try writing()
        let (oldParent, oldName) = try parentAndName(from)
        guard let entry = try find(oldName, in: oldParent) else { throw FATXError("Source path does not exist") }
        try require(entry.attributes & 1 == 0, "Entry is read-only")
        let (parent, name) = try parentAndName(to)
        let existing = try find(name, in: parent)
        try require(existing == nil || existing?.offset == entry.offset, "Destination already exists")
        if entry.isDirectory {
            var parts = try components(to); parts.removeLast()
            for n in 0...parts.count {
                let ancestor = try lookup("/" + parts.prefix(n).joined(separator: "/"))
                try require(ancestor.firstCluster != entry.firstCluster, "Cannot move a directory into itself or its descendant")
            }
        }
        var bytes = entry.raw
        bytes[0] = UInt8(name.count)
        bytes.replaceSubrange(2..<44, with: Data(repeating: 255, count: 42))
        bytes.replaceSubrange(2..<2 + name.count, with: name)
        if oldParent.firstCluster == parent.firstCluster { try disk.write(at: entry.offset, data: bytes) }
        else {
            let slot = try freeSlot(in: parent)
            try disk.write(at: slot, data: bytes)
            var deleted = entry.raw; deleted[0] = 229
            try disk.write(at: entry.offset, data: deleted)
        }
    }
}
