import XCTest
@testable import FATXCore

final class FATXTests: XCTestCase {
    func contents(_ v: Volume, _ path: String) throws -> Data {
        var data = Data(); try v.stream(path) { data.append($0) }; return data
    }
    func testNamedPartitionsAndScanUseFilesystemNames() throws {
        let length: UInt64 = 0x200000000
        let expected: [(String, UInt64, UInt64)] = [
            ("fatx-x", 0x80000, 0x2ee00000), ("fatx-y", 0x2ee80000, 0x2ee00000),
            ("fatx-z", 0x5dc80000, 0x2ee00000), ("fatx-c", 0x8ca80000, 0x1f400000),
            ("fatx-e", 0xabe80000, 0x1312d6000)
        ]
        for (name, offset, size) in expected {
            let partition = try Partitions.named(name, diskLength: length)
            XCTAssertEqual(partition.name, name); XCTAssertEqual(partition.offset, offset); XCTAssertEqual(partition.length, size)
        }
        XCTAssertThrowsError(try Partitions.named("fatx-c", diskLength: 512))
        let fixture = try Fixture(prefix: 0x8ca80000)
        // Sparse backing file: only the literal fixture blocks occupy space.
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: fixture.path))
        try file.truncate(atOffset: length); try file.close()
        let found = try Partitions.scan(Disk(path: fixture.path))
        XCTAssertEqual(found.map(\.name), ["fatx-c"])
        XCTAssertEqual(found.first?.offset, 0x8ca80000)
    }
    func testReadAllByteOrdersAndWidths() throws {
        for big in [false, true] { for fat32 in [false, true] {
            let f = try Fixture(big: big, fat32: fat32)
            let v = try Volume(disk: Disk(path: f.path))
            XCTAssertEqual(v.info.fatEntryBytes, fat32 ? 4 : 2)
            XCTAssertEqual(v.info.rootCluster, 3)
            XCTAssertEqual(try v.list().map(\.name), ["sample.bin", "folder"])
            XCTAssertEqual(try contents(v, "/SAMPLE.BIN"), Data(repeating: 65, count: 4096) + Data(repeating: 66, count: 7))
            let result = try v.check(); XCTAssertEqual(result.files, 1); XCTAssertEqual(result.directories, 2)
            XCTAssertEqual(result.usedClusters, 4)
        } }
    }
    func testWriteLifecycleAllFormats() throws {
        for big in [false, true] { for fat32 in [false, true] {
            let f = try Fixture(big: big, fat32: fat32), v = try Volume(disk: Disk(path: f.path, writable: true))
            let payload = Data((0..<20003).map { UInt8(truncatingIfNeeded: $0 * 17) }), input = try f.input(payload)
            try v.transaction(journal: f.journal()) {
                try v.mkdir("/new"); try v.put(localPath: input, to: "/new/test.bin")
                try v.move("/new/test.bin", to: "/folder/moved.bin")
                try v.move("/new", to: "/NEW")
            }
            XCTAssertEqual(try contents(v, "/folder/moved.bin"), payload)
            let empty = try f.input(Data())
            try v.transaction(journal: f.journal()) {
                try v.put(localPath: empty, to: "/folder/moved.bin", replace: true)
                try v.remove("/folder/moved.bin"); try v.remove("/new")
            }
            XCTAssertEqual(try v.check().usedClusters, 4)
            XCTAssertEqual(try v.list().map(\.name), ["sample.bin", "folder"])
        } }
    }
    func testDirectoryGrowthDeletedSlotsAndEndMarkers() throws {
        let f = try Fixture(), v = try Volume(disk: Disk(path: f.path, writable: true)), empty = try f.input(Data())
        try v.transaction(journal: f.journal()) {
            for i in 0..<140 { try v.put(localPath: empty, to: "/f\(i)") }
        }
        XCTAssertEqual(try v.list().count, 142)
        XCTAssertEqual(try v.chain(v.info.rootCluster).count, 3)
        try v.transaction(journal: f.journal()) { try v.remove("/f0"); try v.put(localPath: empty, to: "/reused") }
        XCTAssertEqual(try v.list().count, 142)
        XCTAssertNoThrow(try v.check())
    }
    func testEachInjectedWriteFailureRollsBackExactly() throws {
        for failure in 0..<18 {
            let f = try Fixture(), before = try f.bytes(), v = try Volume(disk: Disk(path: f.path, writable: true))
            let input = try f.input(Data(repeating: 7, count: 16000))
            v.disk.failAfterWrites = failure
            do {
                try v.transaction(journal: f.journal()) {
                    try v.mkdir("/added"); try v.put(localPath: input, to: "/sample.bin", replace: true)
                    try v.move("/added", to: "/folder/added"); try v.remove("/sample.bin")
                }
                XCTAssertNoThrow(try v.check())
            } catch { XCTAssertEqual(try f.bytes(), before, "Failed after \(failure) writes: \(error)") }
        }
    }
    func testCrashRecoveryAndTornTail() throws {
        let f = try Fixture(), before = try f.bytes(), journal = f.journal()
        do {
            let disk = try Disk(path: f.path, writable: true), v = try Volume(disk: disk)
            disk.journal = try UndoJournal(disk: disk, path: journal, offset: 0, length: f.length)
            try disk.write(at: v.info.dataOffset + 900, data: Data(repeating: 9, count: 40))
            try disk.write(at: v.info.dataOffset + 910, data: Data(repeating: 8, count: 50))
            try disk.sync()
        }
        let tail = try FileHandle(forWritingTo: URL(fileURLWithPath: journal))
        try tail.seekToEnd(); try tail.write(contentsOf: Data([0, 1, 2])); try tail.close()
        do {
            let disk = try Disk(path: f.path, writable: true)
            try Recovery.restore(disk: disk, journal: journal)
            XCTAssertThrowsError(try Recovery.restore(disk: disk, journal: journal))
        }
        XCTAssertEqual(try f.bytes(), before)
    }
    func testMutationValidationAndOutOfSpaceAreAtomic() throws {
        let f = try Fixture(), v = try Volume(disk: Disk(path: f.path, writable: true)), before = try f.bytes()
        let huge = try f.input(Data(repeating: 7, count: 3 * 1024 * 1024))
        let actions: [() throws -> Void] = [
            { try v.mkdir("/bad+name") }, { try v.mkdir("/..") }, { try v.mkdir("/") },
            { try v.mkdir("/folder") }, { try v.remove("/missing") },
            { try v.move("/folder", to: "/folder/child") },
            { try v.move("/sample.bin", to: "/folder") },
            { try v.put(localPath: huge, to: "/too-big") },
            { try v.put(localPath: f.path, to: "/self") },
            { try v.mkdir("/x"); try v.put(localPath: huge, to: "/x/file") }
        ]
        for action in actions {
            XCTAssertThrowsError(try v.transaction(journal: f.journal(), action))
            XCTAssertEqual(try f.bytes(), before)
        }
    }
    func testCorruptionRejectedBeforeJournalOrWrite() throws {
        for kind in 0..<5 {
            let f = try Fixture()
            switch kind {
            case 0: try f.patch(4096 + 2 * 2, Data([2, 0])) // file chain loop
            case 1: try f.patch(4096 + 2 * 2, Data([0, 0])) // live cluster free
            case 2: try f.patch(4096 + 8 * 2, Data([255, 255])) // orphan
            case 3: try f.patch(f.dataStart + 2 * 4096 + 64 + 44, Data([2, 0, 0, 0])) // cross-link
            default: try f.patch(f.dataStart + 2 * 4096, Data([43])) // invalid name length
            }
            let before = try f.bytes(), v = try Volume(disk: Disk(path: f.path, writable: true)), j = f.journal()
            XCTAssertThrowsError(try v.check())
            XCTAssertThrowsError(try v.transaction(journal: j) { try v.mkdir("/x") })
            XCTAssertFalse(FileManager.default.fileExists(atPath: j)); XCTAssertEqual(try f.bytes(), before)
        }
    }
    func testPartitionBoundsAnd4096ByteSectors() throws {
        let f = try Fixture(clusterBytes: 4096, prefix: 8192, sectorSize: 4096)
        let disk = try Disk(path: f.path, writable: true)
        XCTAssertThrowsError(try Volume(disk: disk))
        XCTAssertThrowsError(try Volume(disk: disk, offset: UInt64.max))
        let v = try Volume(disk: disk, offset: 8192, length: f.length, sectorSize: 4096)
        let before = try disk.read(at: 0, count: 8192)
        try v.transaction(journal: f.journal()) { try v.mkdir("/new") }
        XCTAssertEqual(try disk.read(at: 0, count: 8192), before)
        XCTAssertNoThrow(try v.check())
    }
    func testJournalReuseAndCommittedReplayRefused() throws {
        let f = try Fixture(), v = try Volume(disk: Disk(path: f.path, writable: true)), journal = f.journal()
        try v.transaction(journal: journal) { try v.mkdir("/new") }
        let bytes = try f.bytes()
        XCTAssertThrowsError(try v.transaction(journal: journal) { try v.remove("/new") })
        XCTAssertThrowsError(try Recovery.restore(disk: v.disk, journal: journal))
        XCTAssertEqual(try f.bytes(), bytes)
    }
    func testReadOnlyAndInvalidHeaders() throws {
        let f = try Fixture(), v = try Volume(disk: Disk(path: f.path))
        XCTAssertThrowsError(try v.mkdir("/x"))
        XCTAssertThrowsError(try v.transaction(journal: f.journal()) {})
        XCTAssertThrowsError(try v.disk.read(at: UInt64.max, count: 1))
        XCTAssertThrowsError(try v.lookup("relative"))
        try f.patch(8, Data([3, 0, 0, 0]))
        XCTAssertThrowsError(try Volume(disk: Disk(path: f.path)))
    }
    func testTimestampsUseFullHourMinuteFieldsAndDifferentEpochs() throws {
        var fields = DateComponents()
        fields.year = 2026; fields.month = 1; fields.day = 1; fields.hour = 23; fields.minute = 59; fields.second = 58
        let date = try XCTUnwrap(Calendar(identifier: .gregorian).date(from: fields))
        for big in [false, true] {
            let f = try Fixture(big: big), v = try Volume(disk: Disk(path: f.path))
            let packed = v.timestamp(date)
            XCTAssertEqual(packed >> 25, big ? 46 : 26)
            XCTAssertEqual((packed >> 21) & 15, 1)
            XCTAssertEqual((packed >> 16) & 31, 1)
            XCTAssertEqual((packed >> 11) & 31, 23)
            XCTAssertEqual((packed >> 5) & 63, 59)
            XCTAssertEqual((packed & 31) * 2, 58)
        }
    }
    func testCRC32KnownVectorAndCorruptJournalRejectedWithoutWrites() throws {
        XCTAssertEqual(CRC32.checksum(Data("123456789".utf8)), 0xcbf43926)
        let f = try Fixture(), j = f.journal()
        do {
            let d = try Disk(path: f.path, writable: true)
            d.journal = try UndoJournal(disk: d, path: j, offset: 0, length: f.length)
            try d.write(at: f.dataStart + 700, data: Data(repeating: 1, count: 10))
        }
        let h = try FileHandle(forUpdating: URL(fileURLWithPath: j))
        let end = try h.seekToEnd(); try h.seek(toOffset: end - 1); try h.write(contentsOf: Data([99])); try h.close()
        let before = try f.bytes(), disk = try Disk(path: f.path, writable: true)
        XCTAssertThrowsError(try Recovery.restore(disk: disk, journal: j))
        XCTAssertEqual(try f.bytes(), before)
    }
    func testWrongSourceJournalRejectedAndBoundaries() throws {
        let f = try Fixture(), other = try Fixture(), j = f.journal()
        do {
            let d = try Disk(path: f.path, writable: true)
            d.journal = try UndoJournal(disk: d, path: j, offset: 0, length: f.length)
            try d.write(at: f.dataStart, data: Data([42]))
        }
        let before = try other.bytes(), disk = try Disk(path: other.path, writable: true)
        XCTAssertThrowsError(try Recovery.restore(disk: disk, journal: j))
        XCTAssertEqual(try other.bytes(), before)
        for (clusters, expected) in [(65518, 2), (65519, 4), (65520, 4)] {
            let fixture = try Fixture()
            let h = try FileHandle(forUpdating: URL(fileURLWithPath: fixture.path))
            try h.truncate(atOffset: UInt64(clusters) * 4096); try h.close()
            let v = try Volume(disk: Disk(path: fixture.path))
            XCTAssertEqual(v.info.fatEntryBytes, expected)
        }
    }

    func testPendingOperationBlocksNewWritesUntilRecovery() throws {
        let f = try Fixture(), before = try f.bytes(), journal = f.journal()
        do {
            let disk = try Disk(path: f.path, writable: true)
            disk.journal = try UndoJournal(disk: disk, path: journal, offset: 0, length: f.length)
            try disk.write(at: f.dataStart + 33, data: Data([1, 2, 3]))
        }
        let v = try Volume(disk: Disk(path: f.path, writable: true)), second = f.journal()
        XCTAssertThrowsError(try v.transaction(journal: second) { try v.mkdir("/blocked") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: second))
        try Recovery.restore(disk: v.disk, journal: journal)
        XCTAssertEqual(try f.bytes(), before)
        try v.transaction(journal: second) { try v.mkdir("/ok") }
        XCTAssertNoThrow(try v.lookup("/ok"))
    }

}
