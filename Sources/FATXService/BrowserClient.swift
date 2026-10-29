import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import FATXCore

public struct StagedImport {
    public let root: URL
    public let items: [URL]
}
public actor BrowserClient {
    private let executableOverride: URL?
    private var runtimeRoot: URL?
    private var session: DeviceSessionConnection?
    private(set) var authorizationLaunchCount = 0
    private func workspace() throws -> URL {
        if let root = runtimeRoot { return root }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fatx-browser-" + UUID().uuidString, isDirectory: true).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        runtimeRoot = root; return root
    }
    private func executable() throws -> URL {
        guard let binary = executableOverride ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("fatxbridge"), FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw FATXError("The bundled fatxbridge tool is missing. Build using scripts/build-app.sh.")
        }
        return binary
    }
    public func authorizeDeviceSession() throws {
        if let session { _ = try session.exchange(action: "ping"); return }
        let binary = try executable(), root = try workspace()
        let folder = root.appendingPathComponent("session-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let config = DeviceSessionConfiguration(token: (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: ""), uid: getuid(), gid: getgid(), parentPID: getpid(), temporaryRoot: root.path)
        let files = try SessionFiles(folder: folder, owner: getuid())
        try files.write(config, name: "configuration.json")
        let log = folder.appendingPathComponent("authorization.log")
        guard FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw FATXError("Cannot create authorization log") }
        let errors = try FileHandle(forWritingTo: log)
        let process = Process()
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        #if os(macOS)
        // Keep this invocation in the foreground for the complete session.
        // There is no background shell launch, nohup, or per-operation osascript.
        let command = [binary.path, "--device-session", folder.path].map(Self.shellQuote).joined(separator: " ")
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv\n do shell script (item 1 of argv) with administrator privileges\nend run", command]
        #else
        guard geteuid() == 0 else { throw FATXError("Session integration tests require root; automatic sudo is never attempted") }
        process.executableURL = binary; process.arguments = ["--device-session", folder.path]
        #endif
        let connection = DeviceSessionConnection(folder: folder, configuration: config, files: files, process: process, log: log)
        do {
            try process.run(); authorizationLaunchCount += 1
            // The user may take time to answer the system authorization dialog.
            let deadline = Date().addingTimeInterval(300)
            while try files.read(DeviceSessionReady.self, name: "ready.json") == nil {
                guard process.isRunning else { throw connection.failure("Administrator authorization or helper startup failed") }
                guard Date() < deadline else { throw FATXError("Authorization is still waiting. Close the macOS password dialog and retry Enable Device Access.") }
                usleep(50000)
            }
            _ = try connection.exchange(action: "ping")
            session = connection
            try? errors.close()
        } catch {
            // Removing the folder asks an already-started helper to exit. Never
            // terminate a helper in the middle of a journaled device operation.
            try? FileManager.default.removeItem(at: folder)
            if process.isRunning { process.terminate() } // Startup only: no requests were sent.
            try? errors.close(); throw error
        }
    }
    public func checkDeviceAccess() throws -> DeviceAccessReport {
        guard let session else { throw FATXError("Choose Enable Device Access to authorize this app session") }
        guard let report = try session.exchange(action: "access").deviceAccess else { throw FATXError("Missing device access result") }
        return report
    }
    public func closeDeviceSession() throws {
        guard let connection = session else { return }
        _ = try connection.exchange(action: "shutdown")
        session = nil; try? FileManager.default.removeItem(at: connection.folder)
    }
    public init(executable: URL? = nil) { executableOverride = executable }
    public func stageImports(_ urls: [URL]) throws -> StagedImport {
        let root = (try workspace()).appendingPathComponent("fatx-import-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        do {
            var items: [URL] = []
            for url in urls {
                #if os(macOS)
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                #endif
                let target = root.appendingPathComponent(url.lastPathComponent)
                try FileManager.default.copyItem(at: url, to: target); items.append(target)
            }
            return StagedImport(root: root, items: items)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }
    public func discard(_ staging: StagedImport) { try? FileManager.default.removeItem(at: staging.root) }
    public func send(_ original: BrowserRequest) throws -> BrowserReply {
        if original.command == .exportItems {
            let staging = (try workspace()).appendingPathComponent("fatx-export-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: staging) }
            var request = original
            request.destination = original.paths.count == 1 && !original.destination.hasSuffix("/") ? staging.appendingPathComponent("payload").path : staging.path + "/"
            let reply = try exchange(request)
            let sources = try FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)
            var written: [URL] = []
            do {
                for source in sources {
                    let target = original.paths.count == 1 && !original.destination.hasSuffix("/") ? URL(fileURLWithPath: original.destination) : URL(fileURLWithPath: original.destination).appendingPathComponent(source.lastPathComponent)
                    guard !FileManager.default.fileExists(atPath: target.path) else { throw FATXError("Export destination already exists: \(target.lastPathComponent)") }
                    do { try FileManager.default.copyItem(at: source, to: target); written.append(target) }
                    catch { throw FATXError("Export failed; a partial copy may remain at \(target.path): \(error)") }
                }
                return reply
            } catch { for target in written { try? FileManager.default.removeItem(at: target) }; throw error }
        }
        return try exchange(original)
    }
    private func exchange(_ original: BrowserRequest) throws -> BrowserReply {
        var request = original
        request.ownerUID = getuid(); request.ownerGID = getgid()
        if request.source.hasPrefix("/dev/") {
            guard let session else { throw FATXError("Choose Enable Device Access to authorize this app session") }
            return try session.exchange(action: "perform", request: request)
        }
        let executable = try executable()
        let folder = (try workspace()).appendingPathComponent("fatx-request-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("request.json"), output = folder.appendingPathComponent("response.json")
        try JSONEncoder().encode(request).write(to: input, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: input.path)
        guard FileManager.default.createFile(atPath: output.path, contents: Data(), attributes: [.posixPermissions: 0o600]) else { throw FATXError("Cannot create response file") }
        _ = try DeviceTools.run(executable.path, [input.path, output.path])
        let reply = try JSONDecoder().decode(BrowserReply.self, from: Data(contentsOf: output))
        if !reply.success { throw FATXError(reply.message) }
        return reply
    }
    private static func shellQuote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
