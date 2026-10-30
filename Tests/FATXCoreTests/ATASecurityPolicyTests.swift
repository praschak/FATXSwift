import XCTest
@testable import FATXCore

final class ATASecurityPolicyTests: XCTestCase {
    func flags(_ supported: Bool = true, _ enabled: Bool = false, _ locked: Bool = false, _ frozen: Bool = false, _ expired: Bool = false, _ maximum: Bool = false) -> ATASecurityFlags {
        ATASecurityFlags(supported: supported, enabled: enabled, locked: locked, frozen: frozen, expired: expired, maximum: maximum)
    }
    func testSetRejectsUnsafeStates() throws {
        XCTAssertNoThrow(try ATASecurityPolicy.validate(.set, flags: flags(), master: false))
        for bad in [flags(false), flags(true, true), flags(true, false, true), flags(true, false, false, true), flags(true, false, false, false, true)] {
            XCTAssertThrowsError(try ATASecurityPolicy.validate(.set, flags: bad, master: false))
        }
        XCTAssertNoThrow(try ATASecurityPolicy.validate(.set, flags: flags(true, true), master: true))
    }
    func testUnlockAndDisableRespectStates() {
        XCTAssertNoThrow(try ATASecurityPolicy.validate(.unlock, flags: flags(true, true, true), master: false))
        XCTAssertThrowsError(try ATASecurityPolicy.validate(.unlock, flags: flags(true, true, false), master: false))
        XCTAssertThrowsError(try ATASecurityPolicy.validate(.unlock, flags: flags(true, true, true, false, false, true), master: true))
        XCTAssertNoThrow(try ATASecurityPolicy.validate(.disable, flags: flags(true, true, true), master: false))
        XCTAssertThrowsError(try ATASecurityPolicy.validate(.disable, flags: flags(true, true, true, true), master: false))
        XCTAssertThrowsError(try ATASecurityPolicy.validate(.disable, flags: flags(true, true, true, false, false, true), master: true))
    }
    func testPayloadContainsUserOrMasterFlagsAndExactPassword() throws {
        let password = Data([0x00, 0x11, 0x20, 0xff])
        let user = try ATASecurityPolicy.passwordBlock(password, master: false, maximum: true)
        XCTAssertEqual(user.count, 512); XCTAssertEqual(Array(user[0..<6]), [0, 1, 0, 0x11, 0x20, 0xff])
        XCTAssertTrue(user[6...].allSatisfy { $0 == 0 })
        let master = try ATASecurityPolicy.passwordBlock(password, master: true, maximum: false)
        XCTAssertEqual(Array(master[0..<2]), [1, 0])
        XCTAssertThrowsError(try ATASecurityPolicy.passwordBlock(Data(), master: false, maximum: false))
        XCTAssertThrowsError(try ATASecurityPolicy.passwordBlock(Data(repeating: 0, count: 33), master: false, maximum: false))
    }
}

final class ATASecurityExecutorTests: XCTestCase {
    func state(_ enabled: Bool, _ locked: Bool, _ maximum: Bool = false, _ frozen: Bool = false) -> ATASecurityFlags {
        ATASecurityFlags(supported: true, enabled: enabled, locked: locked, frozen: frozen, expired: false, maximum: maximum)
    }
    func testSetWritesExactlyOneMaximumUserPayloadAndChecksState() throws {
        var commands: [UInt8] = [], payloads: [Data] = []
        let result = try ATASecurityExecutor.run(action: .set, initial: state(false, false), password: Data([1,2,3]), master: false, maximum: true,
            send: { commands.append($0); payloads.append($1) }, refresh: { self.state(true, false, true) })
        XCTAssertEqual(commands, [0xf1]); XCTAssertEqual(Array(payloads[0].prefix(5)), [0,1,1,2,3]); XCTAssertTrue(result.enabled)
    }
    func testDisableLockedDriveUnlocksThenDisables() throws {
        var commands: [UInt8] = [], refreshes = [state(true, false), state(false, false)]
        _ = try ATASecurityExecutor.run(action: .disable, initial: state(true, true), password: Data([1]), master: false, maximum: false,
            send: { command, _ in commands.append(command) }, refresh: { refreshes.removeFirst() })
        XCTAssertEqual(commands, [0xf2,0xf6])
    }
    func testFailedUnlockNeverDisablesOrRetries() {
        var commands: [UInt8] = []
        XCTAssertThrowsError(try ATASecurityExecutor.run(action: .disable, initial: state(true, true), password: Data([1]), master: false, maximum: false,
            send: { command, _ in commands.append(command); throw FATXError("transfer failed") }, refresh: { self.state(true, false) }))
        XCTAssertEqual(commands, [0xf2])
    }
    func testUnverifiedUnlockNeverDisables() {
        var commands: [UInt8] = []
        XCTAssertThrowsError(try ATASecurityExecutor.run(action: .disable, initial: state(true, true), password: Data([1]), master: false, maximum: false,
            send: { command, _ in commands.append(command) }, refresh: { self.state(true, true) }))
        XCTAssertEqual(commands, [0xf2])
    }
    func testRejectedStateSendsNothing() {
        var commands: [UInt8] = []
        XCTAssertThrowsError(try ATASecurityExecutor.run(action: .set, initial: state(false, false, false, true), password: Data([1]), master: false, maximum: true,
            send: { command, _ in commands.append(command) }, refresh: { self.state(true, false, true) }))
        XCTAssertTrue(commands.isEmpty)
    }
}
