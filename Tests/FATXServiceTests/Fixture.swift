import Foundation
@testable import FATXCore

// Independent literal fixture writer; does not invoke the production formatter
// or production geometry/entry packing helpers.
final class Fixture {
    let directory: URL
    let path: String
    let big: Bool
    let clusterBytes: Int
    let length: UInt64
    let width: Int
    let dataStart: UInt64
    var serial = 0
    init(big: Bool = false, fat32: Bool = false, clusterBytes: Int = 4096, prefix: UInt64 = 0, sectorSize: Int = 512) throws {
        self.big = big; self.clusterBytes = clusterBytes
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        path = directory.appendingPathComponent("disk.img").path
        length = fat32 ? UInt64(clusterBytes) * 65536 : 2 * 1024 * 1024
        width = fat32 ? 4 : 2
        let fat = ((length / UInt64(clusterBytes) + 1) * UInt64(width) + 4095) & ~UInt64(4095)
        dataStart = prefix + 4096 + fat
        _ = FileManager.default.createFile(atPath: path, contents: nil)
        let file = try FileHandle(forUpdating: URL(fileURLWithPath: path)); defer { try? file.close() }
        try file.truncate(atOffset: prefix + length)
        func store(_ offset: UInt64, _ bytes: Data) throws { try file.seek(toOffset: offset); try file.write(contentsOf: bytes) }
        func integer(_ n: UInt32, _ count: Int) -> Data { Data((0..<count).map { UInt8(truncatingIfNeeded: n >> (8 * (big ? count - 1 - $0 : $0))) }) }
        var header = Data(repeating: 0, count: 4096)
        header.replaceSubrange(0..<4, with: Data((big ? "XTAF" : "FATX").utf8))
        header.replaceSubrange(8..<12, with: integer(UInt32(clusterBytes / sectorSize), 4))
        header.replaceSubrange(12..<16, with: integer(3, 4)) // root intentionally isn't 1
        try store(prefix, header)
        for (c, v): (UInt32, UInt32) in [(0, fat32 ? 0xfffffff8 : 0xfff8), (2, 4), (3, fat32 ? 0xffffffff : 0xffff), (4, fat32 ? 0xffffffff : 0xffff), (6, fat32 ? 0xffffffff : 0xffff)] {
            try store(prefix + 4096 + UInt64(c) * UInt64(width), integer(v, width))
        }
        func entry(_ name: String, _ attr: UInt8, _ first: UInt32, _ size: UInt32) -> Data {
            var bytes = Data(repeating: 255, count: 64)
            bytes[0] = UInt8(name.utf8.count); bytes[1] = attr
            bytes.replaceSubrange(2..<2 + name.utf8.count, with: Data(name.utf8))
            bytes.replaceSubrange(44..<48, with: integer(first, 4))
            bytes.replaceSubrange(48..<52, with: integer(size, 4))
            bytes.replaceSubrange(52..<64, with: Data(repeating: 0, count: 12))
            return bytes
        }
        var root = Data(repeating: 255, count: clusterBytes)
        root.replaceSubrange(0..<64, with: entry("sample.bin", 0x20, 2, UInt32(clusterBytes + 7)))
        root.replaceSubrange(64..<128, with: entry("folder", 0x10, 6, 0))
        try store(dataStart + 2 * UInt64(clusterBytes), root)
        try store(dataStart + UInt64(clusterBytes), Data(repeating: 65, count: clusterBytes))
        try store(dataStart + 3 * UInt64(clusterBytes), Data(repeating: 66, count: 7))
        try store(dataStart + 5 * UInt64(clusterBytes), Data(repeating: 255, count: clusterBytes))
    }
    deinit { try? FileManager.default.removeItem(at: directory) }
    func journal() -> String { serial += 1; return directory.appendingPathComponent("\(serial).journal").path }
    func input(_ bytes: Data) throws -> String {
        serial += 1; let p = directory.appendingPathComponent("input\(serial)").path
        try bytes.write(to: URL(fileURLWithPath: p)); return p
    }
    func patch(_ offset: UInt64, _ bytes: Data) throws {
        let h = try FileHandle(forUpdating: URL(fileURLWithPath: path)); defer { try? h.close() }
        try h.seek(toOffset: offset); try h.write(contentsOf: bytes)
    }
    func bytes() throws -> Data { try Data(contentsOf: URL(fileURLWithPath: path)) }
}
