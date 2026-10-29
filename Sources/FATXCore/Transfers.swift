import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct ImportPreview: Codable {
    public var files: Int = 0
    public var directories: Int = 0
    public var bytes: UInt64 = 0
    public var conflicts: [String] = []
}
struct ImportNode { let url: URL; let destination: String; let directory: Bool }
extension Volume {
    func importPlan(_ urls: [URL], into directory: String) throws -> [ImportNode] {
        try require(try lookup(directory).isDirectory, "Import target must be a directory")
        var plan: [ImportNode] = [], destinations = Set<Data>()
        func append(_ url: URL, _ parent: String) throws {
            try require(plan.count < 100000, "Import exceeds 100,000 items; split it into smaller batches")
            let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            try require(values.isSymbolicLink != true, "Symbolic links cannot be imported: \(url.lastPathComponent)")
            let isDirectory = values.isDirectory == true
            try require(isDirectory || values.isRegularFile == true, "Only regular files and folders can be imported")
            _ = try nameBytes(url.lastPathComponent)
            if !isDirectory { try require((values.fileSize ?? 0) <= Int(UInt32.max), "File exceeds FATX's 4 GiB limit") }
            let path = (parent == "/" ? "" : parent) + "/" + url.lastPathComponent
            try require(destinations.insert(folded(Data(path.utf8))).inserted, "Two imported items have the same FATX path: \(path)")
            plan.append(ImportNode(url: url, destination: path, directory: isDirectory))
            if isDirectory {
                let children = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]).sorted { $0.lastPathComponent < $1.lastPathComponent }
                for child in children where child.lastPathComponent != ".DS_Store" { try append(child, path) }
            }
        }
        for url in urls { try append(url, directory) }
        return plan
    }
    public func previewImport(_ urls: [URL], into directory: String) throws -> ImportPreview {
        let plan = try importPlan(urls, into: directory)
        var result = ImportPreview()
        // Parent directories absent from the volume are expected in a new tree.
        // Existing paths are resolved through directory listings, not error swallowing.
        var existing: [String: Entry] = ["/": rootEntry()]
        func resolveExisting(_ path: String) throws -> Entry? {
            if let cached = existing[path] { return cached }
            let parts = try components(path)
            if parts.isEmpty { return rootEntry() }
            let parentPath = "/" + parts.dropLast().joined(separator: "/")
            guard let parent = try resolveExisting(parentPath), parent.isDirectory else { return nil }
            let bytes = try lookupBytes(parts.last!)
            if let entry = try find(bytes, in: parent) { existing[path] = entry; return entry }
            return nil
        }
        for node in plan {
            if node.directory { result.directories += 1 }
            else { result.files += 1; result.bytes += UInt64(try node.url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
            if let old = try resolveExisting(node.destination) {
                try require(old.isDirectory == node.directory, "A file/folder type conflict cannot be replaced: \(node.destination)")
                result.conflicts.append(node.destination)
            }
        }
        return result
    }
    public func importItems(_ urls: [URL], into directory: String, replace: Bool = false) throws {
        try writing()
        let plan = try importPlan(urls, into: directory)
        for node in plan {
            if node.directory {
                let (parent, name) = try parentAndName(node.destination)
                if let old = try find(name, in: parent) {
                    try require(replace && old.isDirectory, "Destination already exists: \(node.destination)")
                } else { try mkdir(node.destination) }
            } else { try put(localPath: node.url.path, to: node.destination, replace: replace) }
        }
    }
    public func removeItems(_ paths: [String], recursively: Bool) throws {
        try writing()
        let normalized = try paths.map { "/" + (try components($0)).joined(separator: "/") }
        let roots = normalized.filter { path in !normalized.contains { $0 != path && path.hasPrefix($0 + "/") } }
        var seen = Set<String>()
        func erase(_ path: String) throws {
            let entry = try lookup(path)
            if entry.isDirectory && recursively {
                for child in try entries(cluster: entry.firstCluster) {
                    try erase((path == "/" ? "" : path) + "/" + child.name)
                }
            }
            try remove(path)
        }
        for path in roots where seen.insert(path).inserted { try require(path != "/", "Cannot delete the root"); try erase(path) }
    }
    public func exportItem(_ path: String, to destination: URL, owner: (UInt32, UInt32)? = nil) throws {
        let entry = try lookup(path)
        try require(!FileManager.default.fileExists(atPath: destination.path), "Export destination already exists: \(destination.lastPathComponent)")
        func assignOwner(_ target: String) throws {
            if let (uid, gid) = owner, geteuid() == 0 {
                guard chown(target, uid_t(uid), gid_t(gid)) == 0 else { throw systemError("Set export ownership") }
            }
        }
        if entry.isDirectory {
            guard makeHostDirectory(destination.path) == 0 else { throw systemError("Create export folder") }
            do {
                try assignOwner(destination.path)
                for child in try list(path) {
                    let childPath = (path == "/" ? "" : path) + "/" + child.name
                    try exportItem(childPath, to: destination.appendingPathComponent(child.name), owner: owner)
                }
            } catch { try? FileManager.default.removeItem(at: destination); throw error }
        } else {
            let fd = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard fd >= 0 else { throw systemError("Create export file") }
            let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            do {
                try stream(path) { try output.write(contentsOf: $0) }
                try output.synchronize(); try assignOwner(destination.path); try output.close()
            } catch { try? output.close(); try? FileManager.default.removeItem(at: destination); throw error }
        }
    }
}

private func makeHostDirectory(_ path: String) -> Int32 {
    #if canImport(Darwin)
    return Darwin.mkdir(path, mode_t(0o700))
    #else
    return Glibc.mkdir(path, mode_t(0o700))
    #endif
}
