import Foundation
import FATXCore
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

let help = """
fatx 0.2.5 — FATX/XTAF read/write CLI (macOS 13+, Swift 5.9+)

  fatx devices
  fatx scan SOURCE
  fatx info SOURCE [VOLUME]
  fatx ls SOURCE [FATX_PATH] [VOLUME]
  fatx cat SOURCE FATX_PATH [VOLUME]
  fatx get SOURCE FATX_PATH LOCAL_FILE [VOLUME]
  fatx check SOURCE [VOLUME]
  fatx put SOURCE LOCAL_FILE FATX_PATH [--replace] [VOLUME] --journal FILE
  fatx mkdir SOURCE FATX_PATH [VOLUME] --journal FILE
  fatx mv SOURCE OLD_PATH NEW_PATH [VOLUME] --journal FILE
  fatx rm SOURCE FATX_PATH [VOLUME] --journal FILE
  fatx recover SOURCE --journal FILE

VOLUME (choose one):
  --partition NAME          Known fixed partition; see scan output
  --offset BYTES --length BYTES   Exact custom partition bounds
  (no options)              SOURCE is an individual volume image, not a full disk
  --sector-size 512|4096    FATX logical sector size (default 512)

Numbers accept decimal or 0x hex. FATX paths start with /; quote spaces.
Writes require a new external undo journal for each operation. Existing files
are never replaced unless --replace is given. rm removes files or EMPTY folders.
Raw macOS devices must be external, unmounted whole disks (/dev/rdiskN).
Back up first; this prerelease has limited physical-device validation.
"""
struct Arguments {
    var positionals: [String] = []
    var values: [String: String] = [:]
    var replace = false
    init(_ args: [String]) throws {
        var i = 0, literal = false
        while i < args.count {
            let arg = args[i]
            if arg == "--" && !literal { literal = true; i += 1; continue }
            if !literal && arg == "--replace" {
                guard !replace else { throw FATXError("Duplicate --replace") }; replace = true
            } else if !literal && arg.hasPrefix("--") {
                guard ["--offset", "--length", "--partition", "--sector-size", "--journal"].contains(arg), i + 1 < args.count, values[arg] == nil else { throw FATXError("Unknown, duplicate, or incomplete option: \(arg)") }
                i += 1; values[arg] = args[i]
            } else { positionals.append(arg) }
            i += 1
        }
    }
    func number(_ key: String, default fallback: UInt64? = nil) throws -> UInt64? {
        guard let raw = values[key] else { return fallback }
        let n = raw.lowercased().hasPrefix("0x") ? UInt64(raw.dropFirst(2), radix: 16) : UInt64(raw)
        guard let n else { throw FATXError("Invalid unsigned number for \(key)") }; return n
    }
}
func runProcess(_ executable: String, _ args: [String]) throws -> Data {
    let process = Process(), output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable); process.arguments = args
    process.standardOutput = output; process.standardError = FileHandle.standardError
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw FATXError("\(executable) exited with status \(process.terminationStatus)") }
    return bytes
}
func validateDevice(_ disk: Disk) throws {
    guard disk.isDevice else { return }
    #if os(macOS)
    guard disk.path.range(of: "^/dev/rdisk[0-9]+$", options: .regularExpression) != nil else { throw FATXError("Use an unmounted whole raw disk, for example /dev/rdisk4") }
    let bytes = try runProcess("/usr/sbin/diskutil", ["info", "-plist", disk.path])
    guard let info = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String: Any],
          info["WholeDisk"] as? Bool == true,
          info["Internal"] as? Bool == false else { throw FATXError("Only external whole disks are supported for raw access") }
    let tree = try PropertyListSerialization.propertyList(from: runProcess("/usr/sbin/diskutil", ["list", "-plist", disk.path]), format: nil)
    func inspect(_ node: Any) throws {
        if let dictionary = node as? [String: Any] {
            if let point = dictionary["MountPoint"] as? String, !point.isEmpty { throw FATXError("Disk has a mounted volume: \(point). Run diskutil unmountDisk first.") }
            if disk.writable, let content = dictionary["Content"] as? String,
               content.contains("APFS") || content.contains("HFS") { throw FATXError("Refusing raw writes to a disk containing macOS filesystem partitions") }
            for value in dictionary.values { try inspect(value) }
        } else if let array = node as? [Any] { for value in array { try inspect(value) } }
    }
    try inspect(tree)
    // Mount state is checked again through each device's current info, since
    // diskutil list does not consistently include MountPoint on all macOS versions.
    func checkMounts(_ node: Any) throws {
        if let d = node as? [String: Any] {
            if let id = d["DeviceIdentifier"] as? String {
                let data = try runProcess("/usr/sbin/diskutil", ["info", "-plist", id])
                if let p = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any], p["Mounted"] as? Bool == true { throw FATXError("Mounted volume \(id); unmount the whole disk first") }
            }
            for value in d.values { try checkMounts(value) }
        } else if let a = node as? [Any] { for value in a { try checkMounts(value) } }
    }
    try checkMounts(tree)
    #else
    throw FATXError("Raw-device access is supported only on macOS; use volume images here")
    #endif
}
func json<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}
func run() throws {
    let raw = Array(CommandLine.arguments.dropFirst())
    if raw.isEmpty || raw == ["--help"] || raw == ["help"] { print(help); return }
    if raw == ["--version"] { print("fatx 0.2.5"); return }
    let command = raw[0], args = try Arguments(Array(raw.dropFirst()))
    let counts = ["devices": 0, "scan": 1, "info": 1, "ls": 2, "cat": 2, "get": 3, "check": 1, "put": 3, "mkdir": 2, "mv": 3, "rm": 2, "recover": 1]
    guard let count = counts[command] else { throw FATXError("Unknown command: \(command). Run fatx --help") }
    guard args.positionals.count == count || (command == "ls" && args.positionals.count == 1) else { throw FATXError("Wrong number of arguments. Run fatx --help") }
    let writing = ["put", "mkdir", "mv", "rm", "recover"].contains(command)
    if args.replace && command != "put" { throw FATXError("--replace applies only to put") }
    if !writing && args.values["--journal"] != nil { throw FATXError("Read commands do not take --journal") }
    if ["devices", "scan", "recover"].contains(command) && args.values.keys.contains(where: { $0 != "--journal" }) { throw FATXError("This command does not accept volume options") }
    if command == "devices" {
        #if os(macOS)
        FileHandle.standardOutput.write(try runProcess("/usr/sbin/diskutil", ["list", "external", "physical"]))
        return
        #else
        throw FATXError("devices is available on macOS")
        #endif
    }
    let journal = args.values["--journal"]
    if writing && journal == nil { throw FATXError("Writes require --journal /path/to/a-new-file (on your Mac)") }
    let disk = try Disk(path: args.positionals[0], writable: writing)
    try validateDevice(disk)
    if command == "recover" { try Recovery.restore(disk: disk, journal: journal!); print("Recovered source from undo journal."); return }
    if command == "scan" { try json(Partitions.scan(disk)); return }
    let offset: UInt64, length: UInt64?
    if let name = args.values["--partition"] {
        guard args.values["--offset"] == nil && args.values["--length"] == nil else { throw FATXError("Do not combine --partition with --offset/--length") }
        let p = try Partitions.named(name, diskLength: disk.length); offset = p.offset; length = p.length
    } else {
        if (args.values["--offset"] != nil) != (args.values["--length"] != nil) { throw FATXError("Custom volumes require BOTH --offset and --length") }
        offset = try args.number("--offset", default: 0)!; length = try args.number("--length")
    }
    let sector = try args.number("--sector-size", default: 512)!
    guard sector == 512 || sector == 4096 else { throw FATXError("--sector-size must be 512 or 4096") }
    let volume = try Volume(disk: disk, offset: offset, length: length, sectorSize: Int(sector))
    switch command {
    case "info": try json(volume.info)
    case "check": try json(volume.check())
    case "ls":
        for e in try volume.list(args.positionals.count == 2 ? args.positionals[1] : "/") {
            print("\(e.isDirectory ? "d" : "-")\t\(e.size)\t\(e.name)")
        }
    case "cat": try volume.stream(args.positionals[1]) { try FileHandle.standardOutput.write(contentsOf: $0) }
    case "get":
        // O_EXCL/O_NOFOLLOW prevents overwriting images, devices, and symlinks.
        let target = args.positionals[2]
        let fd = open(target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
        guard fd >= 0 else { throw FATXError("Cannot create destination (it must not exist): \(String(cString: strerror(errno)))") }
        let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try volume.stream(args.positionals[1]) { try output.write(contentsOf: $0) }
            try output.synchronize(); try output.close()
        } catch { try? output.close(); try? FileManager.default.removeItem(atPath: target); throw error }
    default:
        try volume.transaction(journal: journal!) {
            switch command {
            case "put": try volume.put(localPath: args.positionals[1], to: args.positionals[2], replace: args.replace)
            case "mkdir": try volume.mkdir(args.positionals[1])
            case "mv": try volume.move(args.positionals[1], to: args.positionals[2])
            case "rm": try volume.remove(args.positionals[1])
            default: throw FATXError("Unsupported mutation")
            }
        }
        print("\(command) completed; volume check passed.")
    }
}
do { try run() }
catch {
    FileHandle.standardError.write(Data("fatx: \(error)\n".utf8))
    exit(1)
}
