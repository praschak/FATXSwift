import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// A crash leaves this durable host-side pointer to the required undo journal.
// A new mutation at the same source path cannot silently supersede it.
enum Pending {
    static func path(_ disk: Disk) -> String {
        disk.isDevice ? "/var/tmp/fatxswift-" + URL(fileURLWithPath: disk.path).lastPathComponent + ".pending" : disk.path + ".fatx-pending"
    }
    static func validateClear(_ disk: Disk) throws {
        let state = path(disk)
        if FileManager.default.fileExists(atPath: state) {
            let old = try String(contentsOfFile: state, encoding: .utf8)
            if !old.isEmpty && FileManager.default.fileExists(atPath: old + ".committed") {
                try FileManager.default.removeItem(atPath: state); try syncParent(state)
            } else { throw FATXError("Unfinished write: recover using journal \(old). Pending state: \(state)") }
        }
    }
    static func begin(_ disk: Disk, journal: String) throws {
        let state = path(disk)
        let fd = open(state, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw systemError("Create pending-write state") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        try handle.write(contentsOf: Data(journal.utf8)); try handle.durableSync(); try syncParent(state)
    }
    static func clear(_ disk: Disk, journal: String) throws {
        let state = path(disk)
        if FileManager.default.fileExists(atPath: state) {
            let recorded = try String(contentsOfFile: state, encoding: .utf8)
            try require(recorded == journal, "Pending state points to another journal")
            try FileManager.default.removeItem(atPath: state); try syncParent(state)
        }
    }
    static func validateRecovery(_ disk: Disk, journal: String) throws {
        let state = path(disk)
        if FileManager.default.fileExists(atPath: state) {
            try require(try String(contentsOfFile: state, encoding: .utf8) == journal, "Pending state points to a different journal")
        }
    }
}
