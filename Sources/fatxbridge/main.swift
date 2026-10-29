import Foundation
import FATXService
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Session-scoped device access, plus one-shot requests for ordinary image files.
// Response is pre-created by the GUI in a private directory, preserving user ownership.
do {
    if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--device-session" {
        try DeviceSessionServer.serve(folder: CommandLine.arguments[2]); exit(0)
    }
    guard CommandLine.arguments.count == 3 else { throw NSError(domain: "FATXBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Usage: fatxbridge REQUEST.json RESPONSE.json"]) }
    let requestPath = CommandLine.arguments[1], responsePath = CommandLine.arguments[2]
    let request = try JSONDecoder().decode(BrowserRequest.self, from: Data(contentsOf: URL(fileURLWithPath: requestPath)))
    let fd = open(responsePath, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw NSError(domain: "FATXBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot open response file"]) }
    let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    var st = stat()
    guard fstat(fd, &st) == 0 && st.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && st.st_nlink == 1 else { throw NSError(domain: "FATXBridge", code: 3, userInfo: [NSLocalizedDescriptionKey: "Unsafe response file"]) }
    let requestURL = URL(fileURLWithPath: requestPath).resolvingSymlinksInPath()
    let responseURL = URL(fileURLWithPath: responsePath).resolvingSymlinksInPath()
    guard requestURL.lastPathComponent == "request.json", responseURL.lastPathComponent == "response.json",
          requestURL.deletingLastPathComponent() == responseURL.deletingLastPathComponent(),
          st.st_uid == (request.ownerUID ?? UInt32(getuid())), st.st_mode & 0o077 == 0 else {
        throw NSError(domain: "FATXBridge", code: 4, userInfo: [NSLocalizedDescriptionKey: "Response must be a private file owned by the requesting user"])
    }
    guard ftruncate(fd, 0) == 0 else { throw NSError(domain: "FATXBridge", code: 5) }
    let reply = BrowserService.handle(request)
    try output.write(contentsOf: JSONEncoder().encode(reply)); try output.synchronize(); try output.close()
} catch {
    FileHandle.standardError.write(Data("fatxbridge: \(error)\n".utf8)); exit(1)
}
