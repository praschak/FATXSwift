import XCTest
import FATXCore
@testable import FATXService

final class FormatServiceTests: XCTestCase {
    func testRejectsAliasesAndNonRegularTargets() throws {
        let f = try Fixture(), alias = f.path + "-device-alias"
        try FileManager.default.createSymbolicLink(atPath: alias, withDestinationPath: "/dev/null")
        defer { try? FileManager.default.removeItem(atPath: alias) }
        XCTAssertThrowsError(try DeviceTools.validateFormatTarget(alias, unmount: false, requireUnmounted: false))
        XCTAssertThrowsError(try DeviceTools.validateFormatTarget(URL(fileURLWithPath: f.path).deletingLastPathComponent().path, unmount: false))
        try DeviceTools.validateFormatTarget(f.path, unmount: false)
    }
    func testSecurityProbeRefusesImageFilesWithoutChangingThem() throws {
        let f = try Fixture(), before = try f.bytes()
        var request = BrowserRequest(.securityProbe); request.source = f.path
        let result = BrowserService.handle(request)
        XCTAssertFalse(result.success)
        XCTAssertNil(result.securityProbe)
        XCTAssertEqual(try f.bytes(), before)
    }
    func testSecurityMutationRequiresRawDiskAndDoesNotChangeImage() throws {
        let f = try Fixture(), before = try f.bytes()
        var request = BrowserRequest(.securityOperation); request.source = f.path
        request.securityRequest = SecurityOperation(action: .set, disk: f.path, rawPassword: Data([1]))
        let result = BrowserService.handle(request)
        XCTAssertFalse(result.success); XCTAssertEqual(try f.bytes(), before)
    }
    func testFormatRequiresReviewedPlanAndConfirmation() throws {
        let f = try Fixture(), before = try f.bytes()
        var request = BrowserRequest(.formatDisk); request.source = f.path; request.journal = f.journal()
        XCTAssertFalse(BrowserService.handle(request).success)
        XCTAssertEqual(try f.bytes(), before)
    }
    func testServiceFormatsImageAndReturnsAllVolumes() throws {
        let f = try Fixture()
        let file = try FileHandle(forWritingTo: URL(fileURLWithPath: f.path)); try file.truncate(atOffset: 16 * 1024 * 1024 * 1024); try file.close()
        var request = BrowserRequest(.formatPlan); request.source = f.path
        let plan = try XCTUnwrap(BrowserService.handle(request).formatPlan)
        request.command = .formatDisk; request.approvedFormat = plan; request.formatConfirmation = f.path; request.journal = f.journal()
        let result = BrowserService.handle(request)
        XCTAssertTrue(result.success, result.message); XCTAssertEqual(result.candidates.count, 7)
        XCTAssertTrue(result.candidates.contains { $0.name == "fatx-f" })
    }
}
