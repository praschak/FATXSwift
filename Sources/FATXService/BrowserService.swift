import Foundation
import FATXCore

public enum BrowserService {
    public static func handle(_ request: BrowserRequest) -> BrowserReply {
        do { return try execute(request) }
        catch { var reply = BrowserReply(); reply.success = false; reply.message = String(describing: error); return reply }
    }
    static func execute(_ r: BrowserRequest) throws -> BrowserReply {
        var reply = BrowserReply()
        if r.command == .devices { reply.devices = try DeviceTools.devices(); return reply }
        if r.command == .eject { try DeviceTools.eject(r.source); reply.message = "Disk ejected"; return reply }
        if r.command == .securityProbe || r.command == .securityOperation {
            guard r.source.range(of: "^/dev/rdisk[0-9]+$", options: .regularExpression) != nil else { throw FATXError("Select an external raw disk") }
            let op = r.securityRequest ?? SecurityOperation(action: .inspect, disk: r.source)
            guard op.disk == r.source else { throw FATXError("Security request target differs from the selected disk") }
            if r.command == .securityOperation {
                guard op.action != .inspect, op.expected?.disk == r.source, op.expected?.identity.isEmpty == false,
                      [op.rawPassword, op.hddKey].compactMap({ $0 }).count == 1 else { throw FATXError("Inspect the device and select one credential before changing security") }
                if op.action == .derive { guard op.rawPassword == nil else { throw FATXError("Derivation requires an HDD key") } }
                if let key = op.hddKey { guard key.count == 16 && !op.master else { throw FATXError("HDD key must contain exactly 16 bytes and uses the user password") } }
                if let data = op.rawPassword { guard !data.isEmpty && data.count <= 32 else { throw FATXError("ATA password must contain 1 to 32 bytes") } }
            } else { guard op.action == .inspect else { throw FATXError("Invalid inspection request") } }
            try DeviceTools.validateFormatTarget(r.source, unmount: true)
            #if os(macOS)
            let binary = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("FATXSecurityProbe")
            guard FileManager.default.isExecutableFile(atPath: binary.path) else { throw FATXError("The security probe is missing from the application bundle") }
            let data = try DeviceTools.runSecurityProbe(binary, request: op)
            reply.securityProbe = try JSONDecoder().decode(SecurityProbe.self, from: data)
            reply.message = (op.action == .inspect || op.action == .derive) ? "Security information ready; no password was changed." : (op.action == .set ? (op.master ? "Master-password command accepted. The drive cannot report its value." : "Password enabled. The drive locks after a power cycle.") : (op.action == .unlock ? "Drive unlocked until power is removed." : "ATA password disabled."))
            return reply
            #else
            throw FATXError("ATA security inspection requires macOS")
            #endif
        }
        if r.command == .formatPlan || r.command == .formatDisk {
            let writing = r.command == .formatDisk
            if writing {
                guard r.formatConfirmation == URL(fileURLWithPath: r.source).resolvingSymlinksInPath().path, r.approvedFormat != nil, r.journal != nil else { throw FATXError("Formatting needs a reviewed plan, exact target confirmation and new undo journal") }
            }
            try DeviceTools.validateFormatTarget(r.source, unmount: writing, requireUnmounted: writing)
            let disk = try Disk(path: r.source, writable: writing)
            try DeviceTools.validateOpenedFormatTarget(disk, requireUnmounted: writing)
            if !writing { reply.formatPlan = try DiskFormatter.plan(disk: disk, profile: r.formatProfile ?? .lba48FG); return reply }
            try DiskFormatter.format(disk: disk, approvedPlan: r.approvedFormat!, journal: r.journal!)
            reply.candidates = r.approvedFormat!.volumes.map { BrowserCandidate(name: "fatx-" + $0.name.lowercased(), offset: $0.offset, length: $0.length, sectorSize: 512) }
            reply.message = "Format complete. Import your system and dashboard files into C/E. Drive locking is a separate step."
            return reply
        }
        let mutation = [.importItems, .mkdir, .move, .delete, .recover].contains(r.command)
        if r.command == .recover { try DeviceTools.validateFormatTarget(r.source, unmount: false) }
        else { try DeviceTools.validate(r.source, writable: mutation, unmount: r.unmount && r.command == .probe) }
        let disk = try Disk(path: r.source, writable: mutation)
        if r.command == .probe {
            let partitions = try Partitions.scan(disk)
            for p in partitions {
                for sector in [512, 4096] {
                    if let volume = try? Volume(disk: disk, offset: p.offset, length: p.length, sectorSize: sector), (try? volume.check()) != nil {
                        reply.candidates.append(BrowserCandidate(name: p.name, offset: p.offset, length: p.length, sectorSize: sector))
                    }
                }
            }
            // Fixed-layout HDD partitions use 512-byte sectors. 4096-byte sectors
            // are offered for standalone images/memory units, never silently picked.
            reply.candidates = reply.candidates.filter { $0.offset == 0 || $0.sectorSize == 512 }
            reply.message = reply.candidates.isEmpty ? "No readable FATX volume found. Use exact custom geometry if this is a nonstandard layout." : "Choose a volume to open"
            return reply
        }
        if r.command == .recover {
            guard let journal = r.journal else { throw FATXError("Choose a journal to recover") }
            try Recovery.restore(disk: disk, journal: journal); reply.message = "Interrupted operation recovered"; return reply
        }
        let volume = try Volume(disk: disk, offset: r.offset, length: r.length, sectorSize: r.sectorSize)
        reply.info = volume.info
        switch r.command {
        case .browse: break
        case .check: reply.check = try volume.check(); reply.message = "Volume check passed"
        case .preview:
            guard let path = r.paths.first else { throw FATXError("Select a file") }
            var bytes = Data()
            struct Limit: Error {}
            do { try volume.stream(path) { data in
                bytes.append(data.prefix(max(0, 65536 - bytes.count)))
                if bytes.count == 65536 { throw Limit() }
            } } catch is Limit {}
            if let text = String(data: bytes, encoding: .utf8), !bytes.contains(0) { reply.preview = text }
            else { reply.preview = "Binary preview (first 256 bytes)\n\n" + bytes.prefix(256).enumerated().map { i, byte in String(format: "%02X", byte) + ((i + 1) % 16 == 0 ? "\n" : " ") }.joined() }
        case .importPreview:
            reply.importPreview = try volume.previewImport(r.localPaths.map { URL(fileURLWithPath: $0) }, into: r.directory)
        case .exportItems:
            _ = try volume.check()
            let owner: (UInt32, UInt32)?
            if let uid = r.ownerUID, let gid = r.ownerGID { owner = (uid, gid) } else { owner = nil }
            var completed: [URL] = []
            do {
                for path in r.paths {
                    let target = r.paths.count == 1 && !r.destination.hasSuffix("/") ? URL(fileURLWithPath: r.destination) : URL(fileURLWithPath: r.destination).appendingPathComponent(try volume.lookup(path).name)
                    try volume.exportItem(path, to: target, owner: owner); completed.append(target)
                }
            } catch {
                for target in completed { try? FileManager.default.removeItem(at: target) }
                throw error
            }
            reply.message = "Exported \(r.paths.count) item(s)"
        case .importItems, .mkdir, .move, .delete:
            guard let journal = r.journal else { throw FATXError("Write journal is required") }
            try volume.transaction(journal: journal) {
                switch r.command {
                case .importItems: try volume.importItems(r.localPaths.map { URL(fileURLWithPath: $0) }, into: r.directory, replace: r.replace)
                case .mkdir: try volume.mkdir(r.destination)
                case .move:
                    guard !r.paths.isEmpty else { throw FATXError("Select items to move") }
                    for path in r.paths {
                        let target = r.destination.hasSuffix("/") ? r.destination + (try volume.lookup(path).name) : r.destination
                        if r.paths.count > 1 && !r.destination.hasSuffix("/") { throw FATXError("Multiple moves need a destination directory ending in /") }
                        try volume.move(path, to: target)
                    }
                case .delete: try volume.removeItems(r.paths, recursively: true)
                default: break
                }
            }
            reply.message = "Completed; volume check passed"
        default: throw FATXError("Unsupported operation")
        }
        if [.browse, .mkdir, .move, .delete, .importItems].contains(r.command) {
            reply.items = try volume.list(r.directory).map { BrowserItem(entry: $0, parent: r.directory) }.sorted {
                $0.directory == $1.directory ? $0.name.localizedStandardCompare($1.name) == .orderedAscending : $0.directory
            }
        }
        return reply
    }
}
