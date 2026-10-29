import Foundation
import CFATXPlatform
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

func systemError(_ action: String) -> FATXError { FATXError("\(action): \(String(cString: strerror(errno)))") }

public final class Disk {
    let fd: Int32
    var deviceLock: Int32 = -1
    public let path: String
    public let length: UInt64
    public let blockSize: Int
    public let isDevice: Bool
    public let writable: Bool
    let identity: String
    var journal: UndoJournal?
    // Injectable I/O failure for tests; never enabled by CLI arguments or environment.
    var failAfterWrites: Int?
    public init(path: String, writable: Bool = false) throws {
        self.path = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        self.writable = writable
        let handle = open(self.path, (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC | O_NOFOLLOW)
        guard handle >= 0 else { throw systemError("Open \(path)") }
        fd = handle
        do {
            var size: UInt64 = 0, block: UInt32 = 0
            var device: Int32 = 0
            guard fx_geometry(fd, &size, &block, &device) == 0 else { throw systemError("Read device geometry") }
            try require(size > 0 && size <= UInt64(Int64.max), "Unsupported source length")
            try require(block >= 512 && block <= 65536 && block.nonzeroBitCount == 1, "Unsupported device block size")
            length = size; blockSize = Int(block); isDevice = device != 0
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw systemError("Read identity") }
            identity = "\(st.st_dev):\(st.st_ino):\(st.st_rdev):\(size)"
            if isDevice {
                // Darwin devfs does not implement advisory locking on raw disks.
                // A persistent, separately locked file coordinates our processes.
                let lockPath = "/var/tmp/fatxswift-" + URL(fileURLWithPath: self.path).lastPathComponent + ".lock"
                let lockFD = open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
                guard lockFD >= 0 else { throw systemError("Open device coordination lock (use the same user/sudo for device commands)") }
                var lockStat = stat()
                guard fstat(lockFD, &lockStat) == 0 && lockStat.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) && lockStat.st_uid == geteuid() && lockStat.st_nlink == 1 else {
                    close(lockFD); throw FATXError("Unsafe device lock file")
                }
                guard fx_lock(lockFD, writable ? 1 : 0) == 0 else { close(lockFD); throw systemError("Device is busy in another fatx process") }
                deviceLock = lockFD
            } else {
                guard fx_lock(fd, writable ? 1 : 0) == 0 else { throw systemError("Lock source (another process may be using it)") }
            }
        } catch { close(handle); throw error }
    }
    deinit { if deviceLock >= 0 { close(deviceLock) }; close(fd) }
    func bounds(_ offset: UInt64, _ count: Int) throws {
        try require(count >= 0 && offset <= length && UInt64(count) <= length - offset, "I/O exceeds source bounds")
    }
    // Device operations are always aligned, including small FAT and directory updates.
    public func read(at offset: UInt64, count: Int) throws -> Data {
        try bounds(offset, count)
        if count == 0 { return Data() }
        let unit = isDevice ? UInt64(blockSize) : 1
        let start = offset / unit * unit
        let end = ((offset + UInt64(count) + unit - 1) / unit) * unit
        try bounds(start, Int(end - start))
        var bytes = Data(count: Int(end - start))
        try bytes.withUnsafeMutableBytes { buffer in
            var done = 0
            while done < buffer.count {
                let n = pread(fd, buffer.baseAddress!.advanced(by: done), buffer.count - done, off_t(start) + off_t(done))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw systemError("Read source (short read or I/O error)") }
                done += n
            }
        }
        return Data(bytes[Int(offset - start)..<Int(offset - start) + count])
    }
    func rawWrite(at offset: UInt64, data: Data, injectFailure: Bool = false) throws {
        try require(writable, "Source was opened read-only")
        try bounds(offset, data.count)
        if injectFailure, let remaining = failAfterWrites {
            if remaining == 0 { failAfterWrites = nil; throw FATXError("Injected write failure") }
            failAfterWrites = remaining - 1
        }
        try data.withUnsafeBytes { buffer in
            var done = 0
            while done < buffer.count {
                let n = pwrite(fd, buffer.baseAddress!.advanced(by: done), buffer.count - done, off_t(offset) + off_t(done))
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw systemError("Write source") }
                done += n
            }
        }
    }
    func write(at offset: UInt64, data: Data) throws {
        guard let journal else { throw FATXError("Writes require an active undo journal") }
        try bounds(offset, data.count)
        if data.isEmpty { return }
        let unit = UInt64(blockSize)
        let start = offset / unit * unit
        let end = (offset + UInt64(data.count) + unit - 1) / unit * unit
        try bounds(start, Int(end - start))
        var replacement = try read(at: start, count: Int(end - start))
        // Each record is durable before its corresponding source write. Repeated
        // offsets deliberately retain all before-images, replayed in reverse.
        try journal.record(offset: start, original: replacement)
        replacement.replaceSubrange(Int(offset - start)..<Int(offset - start) + data.count, with: data)
        try rawWrite(at: start, data: replacement, injectFailure: true)
        try require(try read(at: start, count: replacement.count) == replacement, "Write verification failed")
    }
    public func sync() throws { guard fx_sync(fd) == 0 else { throw systemError("Flush source") } }
}
