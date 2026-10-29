import Foundation
import FATXCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Owned by BrowserClient's actor: exactly one in-flight request per session.
final class DeviceSessionConnection {
    let folder: URL
    let configuration: DeviceSessionConfiguration
    let files: SessionFiles
    let process: Process
    let log: URL
    init(folder: URL, configuration: DeviceSessionConfiguration, files: SessionFiles, process: Process, log: URL) {
        self.folder = folder; self.configuration = configuration; self.files = files; self.process = process; self.log = log
    }
    func failure(_ context: String) -> FATXError {
        let detail: String
        if let data = try? Data(contentsOf: log) { detail = String(decoding: data.suffix(8192), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
        else { detail = "" }
        return FATXError(context + (detail.isEmpty ? "" : "\n\n" + detail) + "\n\nQuit and reopen FATX Browser to authorize a new session. If a write was interrupted, recover its journal before writing again.")
    }
    func exchange(action: String, request: BrowserRequest? = nil) throws -> BrowserReply {
        guard process.isRunning else { throw failure("The authorized device helper has exited") }
        let id = UUID().uuidString
        files.remove("response.json")
        try files.write(DeviceSessionMessage(id: id, token: configuration.token, action: action, request: request), name: "request.json")
        // Device operations may take minutes. Never time out or terminate a write.
        while true {
            if let response = try files.read(DeviceSessionResponse.self, name: "response.json") {
                guard response.id == id, response.token == configuration.token else { throw FATXError("Unexpected device session response") }
                files.remove("response.json")
                guard response.reply.success else { throw FATXError(response.reply.message) }
                return response.reply
            }
            guard process.isRunning else { throw failure("The authorized device helper exited before completing its response") }
            usleep(25000)
        }
    }
}
