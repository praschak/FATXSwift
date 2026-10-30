import XCTest
@testable import FATXCore

final class FormattingTests: XCTestCase {
    func image(_ bytes: UInt64 = 16 * 1024 * 1024 * 1024) throws -> Fixture {
        let f = try Fixture()
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: f.path))
        try file.truncate(atOffset: bytes); try file.close()
        return f
    }
    func snapshots(_ disk: Disk, plan: FormatPlan) throws -> [(UInt64, Data)] {
        let positions = [UInt64(0), disk.length - 34 * 512] + plan.volumes.flatMap { [$0.offset, $0.offset + 4096, $0.dataOffset] }
        return try positions.map { ($0, try disk.read(at: $0, count: 4096)) }
    }
    func testRetailFormatCreatesFixedEmptyUsableVolumes() throws {
        let f = try image(), disk = try Disk(path: f.path, writable: true)
        let plan = try DiskFormatter.plan(disk: disk, profile: .retail)
        XCTAssertEqual(plan.volumes.map(\.name), ["C", "E", "X", "Y", "Z"])
        XCTAssertTrue(plan.volumes.allSatisfy { $0.bytesPerCluster == 16384 })
        XCTAssertEqual(plan.volumes.first(where: { $0.name == "E" })?.length, 0x1312d6000)
        try DiskFormatter.format(disk: disk, approvedPlan: plan, journal: f.journal())
        XCTAssertNil(try Partitions.table(disk))
        XCTAssertEqual(try Partitions.scan(disk).count, 5)
        for p in plan.volumes {
            let volume = try Volume(disk: disk, offset: p.offset, length: p.length)
            XCTAssertEqual(volume.info.rootCluster, 1)
            let check = try volume.check()
            XCTAssertEqual(check.usedClusters, 1); XCTAssertEqual(check.directories, 1); XCTAssertEqual(check.files, 0)
        }
        let c = plan.volumes[0], volume = try Volume(disk: disk, offset: c.offset, length: c.length)
        try volume.transaction(journal: f.journal()) { try volume.mkdir("/Backup") }
        XCTAssertEqual(try volume.list().map(\.name), ["Backup"])
    }
    func testExtendedTableSelectsFAndGWithCorrectBounds() throws {
        let f = try image(), disk = try Disk(path: f.path, writable: true)
        let plan = try DiskFormatter.plan(disk: disk), fVolume = plan.volumes[5], gVolume = plan.volumes[6]
        XCTAssertEqual(fVolume.offset, 0x1dd156000)
        XCTAssertEqual(fVolume.offset + fVolume.length, gVolume.offset)
        XCTAssertEqual(gVolume.offset + gVolume.length, disk.length)
        XCTAssertEqual(fVolume.bytesPerCluster, 65536); XCTAssertEqual(gVolume.bytesPerCluster, 65536)
        try DiskFormatter.format(disk: disk, approvedPlan: plan, journal: f.journal())
        XCTAssertEqual(try XCTUnwrap(Partitions.table(disk)).count, 7)
        XCTAssertEqual(try Partitions.named("fatx-f", disk: disk).length, fVolume.length)
        XCTAssertEqual(try Partitions.named("fatx-g", disk: disk).offset, gVolume.offset)
        XCTAssertEqual(try Partitions.scan(disk).count, 7)
        let bytes = try disk.read(at: 0, count: 512)
        XCTAssertEqual(String(decoding: bytes.prefix(16), as: UTF8.self), "****PARTINFO****")
        XCTAssertEqual(bytes.number(48 + 5 * 32 + 20, 4, .little), UInt32(0x1dd156000 / 512))
    }
    func testInjectedFormatFailureRestoresTouchedMetadata() throws {
        for failedWrite in [0, 1, 3, 8, 16] {
            let f = try image(), disk = try Disk(path: f.path, writable: true)
            let plan = try DiskFormatter.plan(disk: disk), before = try snapshots(disk, plan: plan)
            disk.failAfterWrites = failedWrite
            XCTAssertThrowsError(try DiskFormatter.format(disk: disk, approvedPlan: plan, journal: f.journal()))
            for (offset, data) in before { XCTAssertEqual(try disk.read(at: offset, count: data.count), data) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: Pending.path(disk)))
        }
    }
    func testChangedTargetRejectedBeforeJournalCreation() throws {
        let f = try image()
        let approved = try DiskFormatter.plan(disk: Disk(path: f.path))
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: f.path)); try file.truncate(atOffset: approved.length + 512); try file.close()
        let journal = f.journal(), disk = try Disk(path: f.path, writable: true)
        XCTAssertThrowsError(try DiskFormatter.format(disk: disk, approvedPlan: approved, journal: journal))
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal))
    }
    func testInterruptedFormatRecoveryRestoresChangedHeader() throws {
        let f = try image(), journal = f.journal()
        let original: Data
        do {
            let disk = try Disk(path: f.path, writable: true)
            original = try disk.read(at: 0, count: 4096)
            disk.journal = try UndoJournal(disk: disk, path: journal, offset: 0, length: disk.length, wholeDiskFormat: true)
            try disk.write(at: 0, data: Data(repeating: 0, count: 4096)); try disk.sync()
        }
        let disk = try Disk(path: f.path, writable: true)
        try Recovery.restore(disk: disk, journal: journal)
        XCTAssertEqual(try disk.read(at: 0, count: 4096), original)
        XCTAssertThrowsError(try Recovery.restore(disk: disk, journal: journal))
    }
    func testOverlappingTableDoesNotFallBack() throws {
        let f = try image(), disk = try Disk(path: f.path)
        let plan = try DiskFormatter.plan(disk: disk)
        var table = DiskFormatter.partitionTable(plan.volumes)
        table.put(table.number(48 + 20, 4, .little), 48 + 32 + 20, 4, .little)
        try f.patch(0, table)
        XCTAssertThrowsError(try Partitions.scan(disk))
    }
    func testCapacityAndClusterLimits() throws {
        let small = try Fixture()
        XCTAssertThrowsError(try DiskFormatter.plan(disk: Disk(path: small.path)))
        let large = try image(2 * 1024 * 1024 * 1024 * 1024)
        let disk = try Disk(path: large.path)
        XCTAssertThrowsError(try DiskFormatter.plan(disk: disk, profile: .lba48F))
        XCTAssertTrue(try DiskFormatter.plan(disk: disk, profile: .lba48FG).volumes.allSatisfy { $0.clusterCount <= 0xffffff })
    }
}
