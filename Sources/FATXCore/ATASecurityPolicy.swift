import Foundation

public enum ATASecurityAction: String, Codable { case inspect, derive, set, unlock, disable }
public struct ATASecurityFlags: Codable, Equatable {
    public let supported: Bool, enabled: Bool, locked: Bool, frozen: Bool, expired: Bool, maximum: Bool
    public init(supported: Bool, enabled: Bool, locked: Bool, frozen: Bool, expired: Bool, maximum: Bool) {
        self.supported = supported; self.enabled = enabled; self.locked = locked; self.frozen = frozen; self.expired = expired; self.maximum = maximum
    }
}
public enum ATASecurityPolicy {
    public static func validate(_ action: ATASecurityAction, flags: ATASecurityFlags, master: Bool) throws {
        if action == .inspect || action == .derive { return }
        try require(flags.supported, "Drive does not support ATA security")
        try require(!flags.expired, "Security attempts are exhausted; power-cycle the drive")
        switch action {
        case .inspect, .derive: break
        case .set:
            try require(!flags.frozen && !flags.locked, "Drive is frozen or locked")
            if !master { try require(!flags.enabled, "A user password is already set") }
        case .unlock:
            try require(flags.enabled && flags.locked, "Drive is not locked")
            try require(!master || !flags.maximum, "Master unlock is unavailable at maximum security")
        case .disable:
            try require(flags.enabled && !flags.frozen, "No password is set or the drive is frozen")
            try require(!master || !flags.maximum, "Master disable is unavailable at maximum security")
        }
    }
    public static func passwordBlock(_ password: Data, master: Bool, maximum: Bool) throws -> Data {
        try require(!password.isEmpty && password.count <= 32, "ATA password must contain 1 to 32 bytes")
        var b = Data(repeating: 0, count: 512)
        if master { b[0] = 1 }; if maximum { b[1] = 1 }
        b.replaceSubrange(2..<(2 + password.count), with: password)
        return b
    }
}

/// Executes only the three supported security commands. The caller owns the
/// transport and revalidates the drive identity in each refresh callback.
public enum ATASecurityExecutor {
    public static func run(action: ATASecurityAction, initial: ATASecurityFlags, password: Data, master: Bool, maximum: Bool,
                           send: (UInt8, Data) throws -> Void, refresh: () throws -> ATASecurityFlags) throws -> ATASecurityFlags {
        if action == .inspect || action == .derive { return initial }
        let block = try ATASecurityPolicy.passwordBlock(password, master: master, maximum: action == .set && maximum)
        try ATASecurityPolicy.validate(action, flags: initial, master: master)
        func issue(_ command: UInt8) throws {
            do { try send(command, block) }
            catch { throw FATXError("Security command failed or its result is unknown: \(error). The drive state may have changed; inspect it before trying again.") }
        }
        func refreshed() throws -> ATASecurityFlags {
            do { return try refresh() }
            catch { throw FATXError("Cannot verify the drive after the security command: \(error). Its state is unknown; inspect before retrying.") }
        }
        var current = initial
        switch action {
        case .inspect, .derive: break
        case .set:
            try issue(0xF1); current = try refreshed()
            try require(master || (current.enabled && !current.locked && current.maximum == maximum), "The drive did not confirm the expected security state; inspect before retrying")
        case .unlock:
            try issue(0xF2); current = try refreshed()
            try require(current.enabled && !current.locked, "The drive did not confirm unlock; inspect before retrying")
        case .disable:
            if current.locked {
                try issue(0xF2); current = try refreshed()
                try require(current.enabled && !current.locked && !current.frozen, "Cannot confirm an unlocked, unfrozen drive; password was not disabled")
            }
            try issue(0xF6); current = try refreshed()
            try require(!current.enabled && !current.locked, "The drive did not confirm password removal; inspect before retrying")
        }
        return current
    }
}
