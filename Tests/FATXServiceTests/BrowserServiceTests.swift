import XCTest
import FATXCore
@testable import FATXService

final class BrowserServiceTests: XCTestCase {
    func send(_ fixture: Fixture, _ command: BrowserCommand, configure: (inout BrowserRequest) -> Void = { _ in }) throws -> BrowserReply {
        var request = BrowserRequest(command); request.source = fixture.path
        if [.mkdir, .importItems, .move, .delete].contains(command) { request.journal = fixture.journal() }
        configure(&request)
        let decoded = try JSONDecoder().decode(BrowserRequest.self, from: JSONEncoder().encode(request))
        let reply = BrowserService.handle(decoded)
        if !reply.success { throw FATXError(reply.message) }
        return try JSONDecoder().decode(BrowserReply.self, from: JSONEncoder().encode(reply))
    }
    func tree(_ fixture: Fixture) throws -> URL {
        let directory = fixture.directory.appendingPathComponent("Game")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Sub"), withIntermediateDirectories: true)
        try Data("nested data".utf8).write(to: directory.appendingPathComponent("Sub/save.bin"))
        try Data(repeating: 57, count: 100003).write(to: directory.appendingPathComponent("default.xbe"))
        return directory
    }
    func testBrowserRecursiveImportExportMoveAndDelete() throws {
        let f = try Fixture(), local = try tree(f)
        let preview = try send(f, .importPreview) { $0.localPaths = [local.path] }
        XCTAssertEqual(preview.importPreview?.files, 2); XCTAssertEqual(preview.importPreview?.directories, 2)
        let imported = try send(f, .importItems) { $0.localPaths = [local.path] }
        XCTAssertTrue(imported.items.contains { $0.name == "Game" && $0.directory })
        let nested = try send(f, .browse) { $0.directory = "/Game/Sub" }
        XCTAssertEqual(nested.items.map(\.name), ["save.bin"])
        let exported = f.directory.appendingPathComponent("Exported")
        _ = try send(f, .exportItems) { $0.paths = ["/Game"]; $0.destination = exported.path }
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("Sub/save.bin")), Data("nested data".utf8))
        XCTAssertEqual(try Data(contentsOf: exported.appendingPathComponent("default.xbe")), Data(repeating: 57, count: 100003))
        _ = try send(f, .move) { $0.paths = ["/Game"]; $0.destination = "/Renamed" }
        let deleted = try send(f, .delete) { $0.paths = ["/Renamed"] }
        XCTAssertFalse(deleted.items.contains { $0.name == "Renamed" })
        XCTAssertEqual(try send(f, .check).check?.usedClusters, 4)
    }
    func testImportConflictRequiresReplaceAndIsAtomic() throws {
        let f = try Fixture(), local = try tree(f)
        _ = try send(f, .importItems) { $0.localPaths = [local.path] }
        let bytes = try f.bytes()
        XCTAssertThrowsError(try send(f, .importItems) { $0.localPaths = [local.path] })
        XCTAssertEqual(try f.bytes(), bytes)
        let preview = try send(f, .importPreview) { $0.localPaths = [local.path] }
        XCTAssertEqual(preview.importPreview?.conflicts.count, 4)
        try Data("replacement".utf8).write(to: local.appendingPathComponent("Sub/save.bin"))
        _ = try send(f, .importItems) { $0.localPaths = [local.path]; $0.replace = true }
        let text = try send(f, .preview) { $0.paths = ["/Game/Sub/save.bin"] }
        XCTAssertEqual(text.preview, "replacement")
    }
    func testRecursiveImportFailureRollsBackAllFoldersAndFiles() throws {
        let f = try Fixture(), local = try tree(f), before = try f.bytes()
        try Data(repeating: 1, count: 3 * 1024 * 1024).write(to: local.appendingPathComponent("zz-too-big.bin"))
        XCTAssertThrowsError(try send(f, .importItems) { $0.localPaths = [local.path] })
        XCTAssertEqual(try f.bytes(), before)
    }
    func testSymlinkAndInvalidNamesFailBeforeMutation() throws {
        let f = try Fixture(), local = try tree(f), before = try f.bytes()
        try FileManager.default.createSymbolicLink(atPath: local.appendingPathComponent("link").path, withDestinationPath: "/etc/passwd")
        XCTAssertThrowsError(try send(f, .importItems) { $0.localPaths = [local.path] })
        XCTAssertEqual(try f.bytes(), before)
        try FileManager.default.removeItem(at: local.appendingPathComponent("link"))
        try Data([1]).write(to: local.appendingPathComponent("bad+name"))
        XCTAssertThrowsError(try send(f, .importPreview) { $0.localPaths = [local.path] })
        XCTAssertEqual(try f.bytes(), before)
    }
    func testProbeFindsMemoryUnitSectorSize() throws {
        let f = try Fixture(clusterBytes: 16384, sectorSize: 4096)
        let reply = try send(f, .probe)
        XCTAssertTrue(reply.candidates.contains { $0.offset == 0 && $0.sectorSize == 4096 })
        XCTAssertFalse(reply.candidates.contains { $0.offset == 0 && $0.sectorSize == 512 })
    }
    func testExportRefusesExistingTargetsAndDoesNotLeavePartialBatches() throws {
        let f = try Fixture(), target = f.directory.appendingPathComponent("sample.bin")
        try Data("keep".utf8).write(to: target)
        XCTAssertThrowsError(try send(f, .exportItems) { $0.paths = ["/sample.bin"]; $0.destination = target.path })
        XCTAssertEqual(try Data(contentsOf: target), Data("keep".utf8))
        XCTAssertThrowsError(try send(f, .exportItems) { $0.paths = ["/folder", "/missing"]; $0.destination = f.directory.path + "/" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("folder").path))
    }
    func testRecursiveDeleteReadOnlyEntryRollsBack() throws {
        let f = try Fixture(), local = try tree(f)
        _ = try send(f, .importItems) { $0.localPaths = [local.path] }
        let offset: UInt64
        do { let v = try Volume(disk: Disk(path: f.path)); offset = try v.lookup("/Game/default.xbe").offset }
        try f.patch(offset + 1, Data([0x21]))
        let before = try f.bytes()
        XCTAssertThrowsError(try send(f, .delete) { $0.paths = ["/Game"] })
        XCTAssertEqual(try f.bytes(), before)

    }
    func testActualBrowserClientStagingAndExport() async throws {
        let f = try Fixture(), local = try tree(f)
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("fatxbridge")
        let client = BrowserClient(executable: executable)
        let staging = try await client.stageImports([local])
        XCTAssertEqual(try Data(contentsOf: staging.items[0].appendingPathComponent("Sub/save.bin")), Data("nested data".utf8))
        var request = BrowserRequest(.importItems); request.source = f.path; request.localPaths = staging.items.map(\.path); request.journal = f.journal()
        _ = try await client.send(request)
        await client.discard(staging)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.root.path))
        let target = f.directory.appendingPathComponent("Client Export")
        request = BrowserRequest(.exportItems); request.source = f.path; request.paths = ["/Game"]; request.destination = target.path
        _ = try await client.send(request)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Sub/save.bin")), Data("nested data".utf8))
        do { _ = try await client.send(request); XCTFail("Must not overwrite an existing export") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathComponent("default.xbe").path)) }
    }

}
