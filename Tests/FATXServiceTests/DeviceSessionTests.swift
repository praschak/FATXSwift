import XCTest
import Foundation
import FATXCore
@testable import FATXService
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

final class DeviceSessionTests: XCTestCase {
    func binary() -> URL { URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().appendingPathComponent("fatxbridge") }
    func setup(_ fixture: Fixture, parent: Int32? = nil) throws -> (URL, SessionFiles, DeviceSessionConfiguration) {
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.directory.path)
        let folder = fixture.directory.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let config = DeviceSessionConfiguration(token: String(repeating: "a", count: 64), uid: getuid(), gid: getgid(), parentPID: parent ?? getpid(), temporaryRoot: fixture.directory.path)
        let files = try SessionFiles(folder: folder, owner: getuid())
        try files.write(config, name: "configuration.json")
        return (folder, files, config)
    }
    func launch(_ folder: URL, files: SessionFiles) throws -> Process {
        guard geteuid() == 0 else { throw XCTSkip("Live helper integration requires root on the disposable test host") }
        let process = Process(); process.executableURL = binary(); process.arguments = ["--device-session", folder.path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if try files.read(DeviceSessionReady.self, name: "ready.json") != nil { return process }
            if !process.isRunning { break }
            usleep(20000)
        }
        if process.isRunning { process.terminate(); process.waitUntilExit() }
        throw FATXError("Test session did not start")
    }
    func response(_ files: SessionFiles) throws -> DeviceSessionResponse {
        for _ in 0..<100 {
            if let response = try files.read(DeviceSessionResponse.self, name: "response.json") { files.remove("response.json"); return response }
            usleep(20000)
        }
        throw FATXError("No session response")
    }
    func testClientReusesOneLaunchAcrossRepeatedRequestsAndExplicitShutdown() async throws {
        #if os(Linux)
        guard geteuid() == 0 else { throw XCTSkip("Test never invokes sudo automatically") }
        let client = BrowserClient(executable: binary())
        try await client.authorizeDeviceSession()
        for _ in 0..<8 {
            try await client.authorizeDeviceSession()
            let report = try await client.checkDeviceAccess()
            XCTAssertEqual(report.status, .unverified) // No raw-device enumeration on Linux.
        }
        let launches = await client.authorizationLaunchCount; XCTAssertEqual(launches, 1)
        var request = BrowserRequest(.browse); request.source = "/dev/rdisk9999"
        do { _ = try await client.send(request); XCTFail("Linux cannot access raw Mac devices") }
        catch { XCTAssertTrue(String(describing: error).contains("requires macOS")) }
        let afterError = await client.authorizationLaunchCount; XCTAssertEqual(afterError, 1)
        try await client.closeDeviceSession()
        try await client.authorizeDeviceSession()
        let restarted = await client.authorizationLaunchCount; XCTAssertEqual(restarted, 2)
        try await client.closeDeviceSession()
        #else
        throw XCTSkip("The native administrator dialog is checked manually, not invoked by unit tests")
        #endif
    }
    func testLiveSessionRejectsInvalidTokenThenContinuesAndShutsDown() throws {
        let f = try Fixture(), (folder, files, config) = try setup(f)
        let process = try launch(folder, files: files)
        defer { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        try files.write(DeviceSessionMessage(id: "bad", token: "wrong", action: "ping", request: nil), name: "request.json")
        let rejected = try response(files)
        XCTAssertFalse(rejected.reply.success); XCTAssertTrue(rejected.reply.message.contains("authentication failed"))
        for i in 0..<10 {
            let id = String(i)
            try files.write(DeviceSessionMessage(id: id, token: config.token, action: "ping", request: nil), name: "request.json")
            let reply = try response(files); XCTAssertTrue(reply.reply.success); XCTAssertEqual(reply.id, id)
        }
        try files.write(DeviceSessionMessage(id: "stop", token: config.token, action: "shutdown", request: nil), name: "request.json")
        XCTAssertTrue(try response(files).reply.success)
        process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        XCTAssertNil(try files.read(DeviceSessionReady.self, name: "ready.json"))
    }
    func testHelperExitsWhenParentExits() throws {
        let parent = Process(); parent.executableURL = URL(fileURLWithPath: "/bin/sleep"); parent.arguments = ["1"]
        try parent.run()
        let f = try Fixture(), (folder, files, _) = try setup(f, parent: parent.processIdentifier)
        let helper = try launch(folder, files: files)
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        parent.waitUntilExit()
        for _ in 0..<100 { if !helper.isRunning { break }; usleep(20000) }
        XCTAssertFalse(helper.isRunning)
        XCTAssertNil(try files.read(DeviceSessionReady.self, name: "ready.json"))
    }
    func testRootHelperPublishesMessagesWithInvokingUsersOwnership() throws {
        guard geteuid() == 0 else { throw XCTSkip("Ownership handoff integration requires root") }
        let f = try Fixture(), (folder, _, _) = try setup(f)
        let uid: UInt32 = 65534, gid: UInt32 = 65534
        for path in [f.directory.path, folder.path] {
            if chown(path, uid, gid) != 0 {
                if errno == EPERM { throw XCTSkip("This environment prohibits changing ownership to another UID") }
                #if os(Linux)
                if errno == EINVAL { throw XCTSkip("This Linux test environment maps only UID 0; a second UID is unavailable") }
                #endif
                throw FATXError("Test ownership setup failed: \(String(cString: strerror(errno)))")
            }
        }
        let files = try SessionFiles(folder: folder, owner: uid)
        let config = DeviceSessionConfiguration(token: String(repeating: "b", count: 64), uid: uid, gid: gid, parentPID: getpid(), temporaryRoot: f.directory.path)
        try files.write(config, name: "configuration.json", gid: gid)
        let helper = try launch(folder, files: files)
        defer { if helper.isRunning { helper.terminate(); helper.waitUntilExit() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent("ready.json").path)
        XCTAssertEqual((attributes[.ownerAccountID] as? NSNumber)?.uint32Value, uid)
        try files.write(DeviceSessionMessage(id: "stop", token: config.token, action: "shutdown", request: nil), name: "request.json", gid: gid)
        XCTAssertTrue(try response(files).reply.success)
        helper.waitUntilExit(); XCTAssertEqual(helper.terminationStatus, 0)
    }
    func testSessionPinsPrivateFolderAndRejectsUnsafeMessages() throws {
        let f = try Fixture(), (folder, files, _) = try setup(f)
        try files.write(["safe": true], name: "message.json")
        XCTAssertEqual(try files.read([String: Bool].self, name: "message.json"), ["safe": true])
        let message = folder.appendingPathComponent("message.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: message.path)
        XCTAssertThrowsError(try files.read([String: Bool].self, name: "message.json"))
        try FileManager.default.removeItem(at: message)
        try FileManager.default.createSymbolicLink(at: message, withDestinationURL: URL(fileURLWithPath: f.path))
        XCTAssertThrowsError(try files.read([String: Bool].self, name: "message.json"))
        // Publishing a response replaces the link itself, leaving its target intact.
        let before = try f.bytes(); try files.write(["safe": true], name: "message.json")
        XCTAssertEqual(try f.bytes(), before)
        let alias = folder.appendingPathComponent("alias")
        try FileManager.default.linkItem(at: message, to: alias)
        XCTAssertThrowsError(try files.read([String: Bool].self, name: "message.json"))
        files.remove("message.json"); files.remove("alias")
        try Data(repeating: 65, count: SessionFiles.maximum + 1).write(to: message)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: message.path)
        XCTAssertThrowsError(try files.read([String: Bool].self, name: "message.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path)
        XCTAssertThrowsError(try SessionFiles(folder: folder))
    }
    func testPrivilegedPolicyRejectsHostFilesAndUnstagedTransferPaths() throws {
        let f = try Fixture(), (_, _, config) = try setup(f), before = try f.bytes()
        var request = BrowserRequest(.mkdir); request.source = f.path; request.destination = "/invalid"; request.journal = f.journal()
        XCTAssertThrowsError(try DeviceSessionServer.process(DeviceSessionMessage(id: "1", token: config.token, action: "perform", request: request), configuration: config))
        request.source = "/dev/rdisk4"; request.command = .importItems; request.localPaths = ["/etc/passwd"]
        XCTAssertThrowsError(try DeviceSessionServer.process(DeviceSessionMessage(id: "2", token: config.token, action: "perform", request: request), configuration: config))
        request.command = .exportItems; request.localPaths = []; request.destination = "/etc/unwanted"
        XCTAssertThrowsError(try DeviceSessionServer.process(DeviceSessionMessage(id: "3", token: config.token, action: "perform", request: request), configuration: config))
        XCTAssertEqual(try f.bytes(), before)
    }
    func testClientStartupFailureDoesNotSilentlyRelaunchOrAuthorize() async throws {
        #if os(Linux)
        guard geteuid() == 0 else { throw XCTSkip("Test never invokes sudo automatically") }
        let client = BrowserClient(executable: URL(fileURLWithPath: "/bin/false"))
        do { try await client.authorizeDeviceSession(); XCTFail("Failed executable must be reported") }
        catch { XCTAssertTrue(String(describing: error).contains("helper startup failed")) }
        var request = BrowserRequest(.browse); request.source = "/dev/rdisk4"
        do { _ = try await client.send(request); XCTFail("A request cannot trigger automatic authorization") }
        catch { XCTAssertTrue(String(describing: error).contains("Enable Device Access")) }
        let count = await client.authorizationLaunchCount; XCTAssertEqual(count, 1)
        #else
        throw XCTSkip("The native administrator dialog is checked manually")
        #endif
    }
}
