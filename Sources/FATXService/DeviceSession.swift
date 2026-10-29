import Foundation
import FATXCore
import CFATXPlatform
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct DeviceSessionConfiguration: Codable {
    let token: String
    let uid: UInt32
    let gid: UInt32
    let parentPID: Int32
    let temporaryRoot: String
}
struct DeviceSessionMessage: Codable {
    let id: String
    let token: String
    let action: String
    let request: BrowserRequest?
}
struct DeviceSessionResponse: Codable {
    let id: String
    let token: String
    let reply: BrowserReply
}
struct DeviceSessionReady: Codable { let helperPID: Int32 }

// Pin the directory by descriptor. Every message is a private regular file;
// writes create a new inode and rename it, never following a caller's symlink.
final class SessionFiles {
    static let maximum = 8 * 1024 * 1024
    let fd: Int32
    let owner: UInt32
    init(folder: URL, owner: UInt32? = nil) throws {
        let descriptor = open(folder.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw FATXError("Open session folder: \(String(cString: strerror(errno)))") }
        var st = stat()
        guard fstat(descriptor, &st) == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              st.st_mode & 0o077 == 0, owner == nil || st.st_uid == owner else {
            close(descriptor); throw FATXError("Device session folder must be private and owned by the invoking user")
        }
        fd = descriptor; self.owner = st.st_uid
    }
    deinit { close(fd) }
    func read<T: Decodable>(_ type: T.Type, name: String) throws -> T? {
        let descriptor = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 && errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw FATXError("Open session message: \(String(cString: strerror(errno)))") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true); defer { try? handle.close() }
        var st = stat()
        guard fstat(descriptor, &st) == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              st.st_nlink == 1, st.st_uid == owner, st.st_mode & 0o077 == 0,
              st.st_size > 0, st.st_size <= Self.maximum else { throw FATXError("Unsafe or oversized session message") }
        var data = Data()
        while let chunk = try handle.read(upToCount: min(65536, Self.maximum + 1 - data.count)), !chunk.isEmpty {
            data.append(chunk)
            guard data.count <= Self.maximum else { throw FATXError("Session message exceeds 8 MiB") }
        }
        return try JSONDecoder().decode(type, from: data)
    }
    func write<T: Encodable>(_ value: T, name: String, gid: UInt32? = nil) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= Self.maximum else { throw FATXError("Session message exceeds 8 MiB") }
        let temporary = ".message-" + UUID().uuidString
        let descriptor = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw FATXError("Cannot create private session message") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); _ = unlinkat(fd, temporary, 0) }
        try handle.write(contentsOf: data)
        if geteuid() == 0 {
            guard fchown(descriptor, owner, gid ?? UInt32.max) == 0 else { throw FATXError("Cannot assign session message ownership") }
        }
        guard renameat(fd, temporary, fd, name) == 0 else { throw FATXError("Cannot publish session message") }
    }
    func remove(_ name: String) { _ = unlinkat(fd, name, 0) }
}

public enum DeviceSessionServer {
    public static func serve(folder path: String) throws {
        guard geteuid() == 0 else { throw FATXError("The device session helper must run with administrator privileges") }
        let folder = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let files = try SessionFiles(folder: folder)
        guard let config = try files.read(DeviceSessionConfiguration.self, name: "configuration.json"),
              config.uid == files.owner, config.token.count >= 64, config.parentPID > 1 else { throw FATXError("Invalid device session configuration") }
        let root = URL(fileURLWithPath: config.temporaryRoot).resolvingSymlinksInPath()
        _ = try SessionFiles(folder: root, owner: config.uid)
        guard folder.path.hasPrefix(root.path + "/") else { throw FATXError("Invalid private session workspace") }
        let stamp = fx_process_stamp(config.parentPID)
        guard stamp != 0 else { throw FATXError("The browser process is no longer running") }
        try files.write(DeviceSessionReady(helperPID: getpid()), name: "ready.json", gid: config.gid)
        defer { files.remove("ready.json") }
        while FileManager.default.fileExists(atPath: folder.path) && fx_process_stamp(config.parentPID) == stamp {
            if let message = try files.read(DeviceSessionMessage.self, name: "request.json") {
                files.remove("request.json")
                let response: BrowserReply
                var stopping = false
                do {
                    let result = try process(message, configuration: config)
                    response = result.reply; stopping = result.stop
                } catch {
                    var failure = BrowserReply(); failure.success = false; failure.message = String(describing: error); response = failure
                }
                try files.write(DeviceSessionResponse(id: message.id, token: config.token, reply: response), name: "response.json", gid: config.gid)
                if stopping { return }
            } else { usleep(50000) }
        }
    }
    static func process(_ message: DeviceSessionMessage, configuration config: DeviceSessionConfiguration) throws -> (reply: BrowserReply, stop: Bool) {
        guard message.token == config.token else { throw FATXError("Device session authentication failed") }
        var reply = BrowserReply()
        switch message.action {
        case "ping": reply.message = "Device session ready"
        case "shutdown": return (reply, true)
        case "access": reply.deviceAccess = try checkDeviceAccess()
        case "perform":
            guard var request = message.request else { throw FATXError("Missing device request") }
            try validate(request, configuration: config)
            request.ownerUID = config.uid; request.ownerGID = config.gid
            reply = BrowserService.handle(request)
        default: throw FATXError("Unknown device session operation")
        }
        return (reply, false)
    }
    // Test actual raw-device access instead of guessing from a private TCC database.
    // Opening read-only neither unmounts nor writes to the device.
    private static func checkDeviceAccess() throws -> DeviceAccessReport {
        let devices = try DeviceTools.devices()
        var checked = 0
        for device in devices {
            let descriptor = open(device.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            if descriptor >= 0 { close(descriptor); checked += 1 }
            else if errno == EPERM || errno == EACCES {
                return DeviceAccessReport(status: .blocked, message: "macOS blocked access to \(device.path). Enable Full Disk Access for this FATX Browser app, then quit and reopen it.", checkedDevices: checked)
            }
        }
        if checked > 0 { return DeviceAccessReport(status: .available, message: "Connected raw devices are accessible", checkedDevices: checked) }
        return DeviceAccessReport(status: .unverified, message: "Connect your FATX device and choose Check Again to verify access. If Full Disk Access is already enabled for this app, you can continue.", checkedDevices: 0)
    }
    private static func validate(_ request: BrowserRequest, configuration: DeviceSessionConfiguration) throws {
        guard request.source.range(of: "^/dev/rdisk[0-9]+$", options: .regularExpression) != nil else { throw FATXError("The privileged device session cannot operate on host image files") }
        let root = URL(fileURLWithPath: configuration.temporaryRoot).resolvingSymlinksInPath().path
        func staged(_ path: String) -> Bool { URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(root + "/") }
        for path in request.localPaths where !staged(path) { throw FATXError("Imports must be staged by the browser") }
        if request.command == .exportItems && !staged(request.destination) { throw FATXError("Exports must be staged by the browser") }
        if let journal = request.journal, request.command != .recover {
            let parent = URL(fileURLWithPath: journal).deletingLastPathComponent().resolvingSymlinksInPath().path
            var st = stat()
            guard lstat(parent, &st) == 0, st.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
                  st.st_uid == configuration.uid, st.st_mode & 0o022 == 0 else { throw FATXError("Use a private journal folder owned by the invoking user") }
        }
    }
}
