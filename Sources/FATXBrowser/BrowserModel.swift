import AppKit
import Darwin
import SwiftUI
import FATXCore
import FATXService

@MainActor
final class BrowserModel: ObservableObject {
    private var startupAttempted = false
    @Published var deviceSessionAuthorized = false
    @Published var showAccessSetup = false
    @Published var accessMessage = "Enable Full Disk Access so FATX Browser can open your FATX device. Administrator authorization is also required once each time the app starts."
    @Published var accessVerified = false
    @Published var showSecurityProbe = false
    @Published var securityTarget = ""
    @Published var securityProbe: SecurityProbe?
    @Published var securityCredential = "HDD key"
    @Published var securityPassword = ""
    @Published var savedKeyNames: [String] = []
    @Published var selectedSavedKey = ""
    @Published var saveHDDKey = false
    @Published var newKeyName = ""
    @Published var unlockFromScan = false
    @Published var securityHex = false
    @Published var securitySerialFirst = false
    @Published var securityMaster = false
    @Published var securityMaximum = true
    @Published var showFormat = false
    @Published var formatTarget = ""
    @Published var formatProfile = FormatProfile.lba48FG
    @Published var formatPlan: FormatPlan?
    @Published var formatConfirmation = ""
    @Published var devices: [BrowserDevice] = []
    @Published var source = ""
    @Published var sourceName = ""
    @Published var connected = false
    @Published var candidates: [BrowserCandidate] = []
    @Published var selectedCandidate = ""
    @Published var chooseVolume = false
    @Published var useCustomGeometry = false
    @Published var customOffset = "0"
    @Published var customLength = ""
    @Published var customSector = 4096
    @Published var currentDirectory = "/"
    @Published var items: [BrowserItem] = []
    @Published var selection = Set<String>()
    @Published var query = ""
    @Published var busy = false
    @Published var status = "Choose a FATX device or open an image"
    @Published var info: VolumeInfo?
    @Published var report = ""
    @Published var showReport = false
    @Published var journalFolder: URL
    let client = BrowserClient()
    var configuration = BrowserRequest(.browse)
    var selectedItems: [BrowserItem] { items.filter { selection.contains($0.path) } }
    var visibleItems: [BrowserItem] { query.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(query) } }
    var connectionKey: String { "\(configuration.source)|\(configuration.offset)|\(configuration.length ?? 0)|\(configuration.sectorSize)" }
    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        journalFolder = base.appendingPathComponent("FATXBrowser/Journals", isDirectory: true)
    }
    func request(_ command: BrowserCommand) -> BrowserRequest {
        var r = configuration; r.command = command; r.directory = currentDirectory
        r.ownerUID = getuid(); r.ownerGID = getgid(); return r
    }
    func journal() throws -> String {
        try FileManager.default.createDirectory(at: journalFolder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return journalFolder.appendingPathComponent(UUID().uuidString + ".undo").path
    }
    func apply(_ response: BrowserReply, listing: Bool = true) {
        if listing { items = response.items; selection = []; query = "" }
        if let info = response.info { self.info = info }
        status = response.message.isEmpty ? "\(items.count) items" : response.message
    }
    func work(_ title: String, action: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true; status = title
        Task {
            defer { busy = false }
            do { try await action() }
            catch { status = "Operation failed"; showError(error) }
        }
    }
    func showError(_ error: Error) {
        if String(describing: error).localizedCaseInsensitiveContains("operation not permitted") {
            accessVerified = false
            accessMessage = "macOS blocked device access. Enable Full Disk Access for this copy of FATX Browser, then quit and reopen the app.\n\n" + String(describing: error)
            showAccessSetup = true; return
        }
        let alert = NSAlert(); alert.messageText = "FATX Browser"; alert.informativeText = String(describing: error); alert.alertStyle = .warning; alert.runModal()
    }
    func start() {
        guard !startupAttempted else { return }
        startupAttempted = true; authorizeDevices()
    }
    func authorizeDevices() {
        work("Authorizing device access for this app session…") {
            self.devices = try await self.client.send(BrowserRequest(.devices)).devices
            try await self.client.authorizeDeviceSession()
            self.deviceSessionAuthorized = true
            self.applyAccess(try await self.client.checkDeviceAccess())
            self.status = self.accessVerified ? "Device access ready for this app session" : "Device authorization ready; check Full Disk Access"
        }
    }
    func applyAccess(_ report: DeviceAccessReport) {
        accessVerified = report.status == .available; accessMessage = report.message
        if accessVerified {
            showAccessSetup = false
            UserDefaults.standard.set(true, forKey: "fullDiskAccessGuidanceSeen")
        } else if report.status == .blocked || !UserDefaults.standard.bool(forKey: "fullDiskAccessGuidanceSeen") {
            showAccessSetup = true
        }
    }
    func checkAccess() {
        guard deviceSessionAuthorized else { authorizeDevices(); return }
        work("Checking device access…") {
            self.applyAccess(try await self.client.checkDeviceAccess())
            self.devices = try await self.client.send(BrowserRequest(.devices)).devices
            self.status = self.accessVerified ? "Device access ready" : "Device access not yet verified"
        }
    }
    func openAccessSettings() {
        let pane: String
        if #available(macOS 26, *) { pane = "com.apple.settings.PrivacySecurity.extension" }
        else { pane = "com.apple.preference.security" }
        if let url = URL(string: "x-apple.systempreferences:" + pane + "?Privacy_AllFiles"), NSWorkspace.shared.open(url) { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }
    func revealApplication() { NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL]) }
    func dismissAccessSetup() {
        UserDefaults.standard.set(true, forKey: "fullDiskAccessGuidanceSeen")
        showAccessSetup = false
    }
    func refreshDevices() {
        work("Looking for devices…") {
            self.devices = try await self.client.send(BrowserRequest(.devices)).devices
            if self.deviceSessionAuthorized { self.applyAccess(try await self.client.checkDeviceAccess()) }
            self.status = "\(self.devices.count) external device(s)"
        }
    }
    func beginSecurityProbe() {
        guard !busy, deviceSessionAuthorized, !devices.isEmpty else { return }
        securityTarget = devices.contains(where: { $0.path == source }) ? source : (devices.first?.path ?? "")
        securityProbe = nil; securityPassword = ""; selectedSavedKey = ""; saveHDDKey = false; unlockFromScan = false; refreshSavedKeys(); chooseVolume = false; showSecurityProbe = true
    }
    func refreshSavedKeys() {
        do { savedKeyNames = try HDDKeyStore.names() }
        catch { savedKeyNames = []; showError(error) }
    }
    func selectSavedKey(_ name: String) {
        selectedSavedKey = name; securityPassword = ""
        guard !name.isEmpty else { return }
        do {
            securityPassword = try HDDKeyStore.get(name).map { String(format: "%02x", $0) }.joined()
            saveHDDKey = false
        } catch { selectedSavedKey = ""; showError(error) }
    }
    func deleteSavedKey() {
        guard !selectedSavedKey.isEmpty else { return }
        let alert = NSAlert(); alert.messageText = "Delete saved HDD key?"
        alert.informativeText = "Remove \(selectedSavedKey) from the macOS Keychain? This does not change the drive."
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try HDDKeyStore.delete(selectedSavedKey); selectedSavedKey = ""; securityPassword = ""; refreshSavedKeys() }
        catch { showError(error) }
    }
    func securityPasswordBytes() throws -> Data {
        if !securityHex {
            let bytes = Data(securityPassword.utf8)
            guard !bytes.isEmpty && bytes.count <= 32 else { throw FATXError("Password must be 1 to 32 UTF-8 bytes") }
            return bytes
        }
        let hex = securityPassword.filter { !$0.isWhitespace }
        guard !hex.isEmpty, hex.count <= 64, hex.count % 2 == 0 else { throw FATXError("Hex password must contain 2 to 64 hexadecimal characters") }
        var bytes = Data(), i = hex.startIndex
        while i < hex.endIndex {
            let next = hex.index(i, offsetBy: 2)
            guard let byte = UInt8(hex[i..<next], radix: 16) else { throw FATXError("Invalid hexadecimal password") }
            bytes.append(byte); i = next
        }
        return bytes
    }
    func performSecurity(_ action: ATASecurityAction) {
        guard let probe = securityProbe, probe.disk == securityTarget, action != .inspect else { return }
        do {
            var op = SecurityOperation(action: action, disk: securityTarget, expected: probe.withoutSecret)
            if securityCredential == "HDD key" {
                let saved = securityHex; securityHex = true
                defer { securityHex = saved }
                let key = try securityPasswordBytes()
                guard key.count == 16 else { throw FATXError("HDD key must be 32 hexadecimal characters") }
                op.hddKey = key; op.master = false; op.maximum = true
            } else {
                op.rawPassword = try securityPasswordBytes(); op.master = securityMaster; op.maximum = securityMaximum
            }
            let saveKey = saveHDDKey && securityCredential == "HDD key" && (action == .set || action == .unlock)
            let label = newKeyName.trimmingCharacters(in: .whitespacesAndNewlines)
            if saveKey && label.isEmpty { throw FATXError("Enter a name for the saved HDD key") }
            if saveKey && savedKeyNames.contains(label) { throw FATXError("A saved key with that name already exists") }
            op.serialFirst = securitySerialFirst
            let alert = NSAlert(); alert.alertStyle = .warning
            alert.messageText = action == .derive ? "Show derived password?" : (action == .set ? "Set drive password?" : (action == .unlock ? "Unlock drive?" : "Remove drive password?"))
            alert.informativeText = "Target: \(probe.disk)\nModel: \(probe.model)\nSerial: \(probe.serial)\n\n" + (securitySerialFirst && securityCredential != "Password" ? "Legacy serial-first derivation selected. Verify that this is correct.\n\n" : "") + (action == .derive ? "The derived password is sensitive. Keep it private." : (action == .set ? "The drive will lock on its next power cycle. Keep the correct backup safe. Maximum security limits master-password recovery." : (action == .disable ? "Removing the password can prevent a retail system from booting this drive." : "An incorrect password counts against the drive's limited attempts. Unlock lasts until power is removed.")))
            alert.addButton(withTitle: action == .derive ? "Show Password" : (action == .set ? "Set Password" : (action == .unlock ? "Unlock" : "Remove Password"))); alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            work("Changing drive security; keep the adapter connected…") {
                var request = BrowserRequest(.securityOperation); request.source = op.disk; request.securityRequest = op
                self.securityProbe = nil
                let reply = try await self.client.send(request)
                self.securityProbe = reply.securityProbe; self.securityPassword = ""; self.status = reply.message
                if saveKey, let key = op.hddKey {
                    do { try HDDKeyStore.save(label, key: key); self.refreshSavedKeys(); self.saveHDDKey = false; self.newKeyName = "" }
                    catch { self.showError(FATXError("The drive operation succeeded, but the HDD key was not saved: \(error)")) }
                }
                if action == .unlock && self.unlockFromScan {
                    self.unlockFromScan = false; self.showSecurityProbe = false
                    self.status = "Drive unlocked. Select the device again to open it."
                }
            }
        } catch { showError(error) }
    }
    func inspectDriveSecurity() {
        let target = securityTarget
        guard !target.isEmpty else { return }
        securityProbe = nil
        work("Unmounting disk and checking ATA security…") {
            self.connected = false; self.items = []; self.selection = []; self.info = nil; self.candidates = []
            self.source = target
            self.sourceName = self.devices.first(where: { $0.path == target })?.name ?? URL(fileURLWithPath: target).lastPathComponent
            var r = BrowserRequest(.securityProbe); r.source = target
            self.securityProbe = try await self.client.send(r).securityProbe
            self.status = "Security inspection complete; no password changed"
        }
    }
    func beginFormat() {
        guard !busy, deviceSessionAuthorized, !devices.isEmpty else { return }
        formatTarget = devices.contains(where: { $0.path == source }) ? source : (devices.first?.path ?? "")
        formatPlan = nil; formatConfirmation = ""; chooseVolume = false; showFormat = true
    }
    func reviewFormat() {
        formatPlan = nil; formatConfirmation = ""
        work("Reading format geometry…") {
            var r = BrowserRequest(.formatPlan); r.source = self.formatTarget; r.formatProfile = self.formatProfile
            self.formatPlan = try await self.client.send(r).formatPlan
            self.status = "Review the layout and confirm the target device before erasing"
        }
    }
    func performFormat() {
        guard let plan = formatPlan, plan.source == formatTarget, plan.profile == formatProfile,
              formatConfirmation == URL(fileURLWithPath: plan.source).lastPathComponent else { return }
        let alert = NSAlert(); alert.alertStyle = .critical
        alert.messageText = "Erase all data on \(formatTarget)?"
        alert.informativeText = "This quick format replaces the disk layout and creates empty FATX volumes. Restore your C/E system files afterward. Formatting does not set the drive's ATA password."
        alert.addButton(withTitle: "Erase & Format"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        work("Formatting device; keep it connected…") {
            self.connected = false; self.items = []; self.selection = []; self.info = nil; self.candidates = []
            self.source = plan.source
            self.sourceName = self.devices.first(where: { $0.path == plan.source })?.name ?? URL(fileURLWithPath: plan.source).lastPathComponent
            var r = BrowserRequest(.formatDisk); r.source = plan.source; r.approvedFormat = plan
            r.formatConfirmation = plan.source; r.journal = try self.journal()
            let reply = try await self.client.send(r)
            self.candidates = reply.candidates; self.selectedCandidate = reply.candidates.first?.id ?? ""
            self.useCustomGeometry = false; self.showFormat = false; self.formatPlan = nil
            self.status = reply.message
        }
    }
    func openImage() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.title = "Open a FATX disk or volume image"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { probe(url.path, name: url.lastPathComponent) }
    }
    func probe(_ path: String, name: String) {
        work(path.hasPrefix("/dev/") ? "Unmounting and scanning device…" : "Scanning image…") {
            do {
                var r = BrowserRequest(.probe); r.source = path; r.unmount = path.hasPrefix("/dev/")
                let reply = try await self.client.send(r)
                self.source = path; self.sourceName = name; self.connected = false; self.items = []; self.selection = []; self.info = nil
                self.useCustomGeometry = false
                self.candidates = reply.candidates
                self.selectedCandidate = reply.candidates.first(where: { $0.sectorSize == 4096 && $0.offset == 0 })?.id ?? reply.candidates.first?.id ?? ""
                self.customLength = reply.candidates.first.map { String($0.length) } ?? ""
                self.status = reply.message
                if reply.candidates.count == 1 { try await self.attach(reply.candidates[0]) }
                else { self.chooseVolume = true }
            } catch {
                let scanError = error
                guard path.hasPrefix("/dev/rdisk") else { throw scanError }
                var securityRequest = BrowserRequest(.securityProbe); securityRequest.source = path
                // A read failure alone is not proof of a lock. Inspect the same device.
                let inspected: BrowserReply
                do { inspected = try await self.client.send(securityRequest) }
                catch { throw FATXError("\(scanError)\n\nUnable to check ATA security: \(error)") }
                guard let info = inspected.securityProbe, info.locked else { throw scanError }
                self.source = path; self.sourceName = name; self.connected = false
                self.items = []; self.selection = []; self.info = nil; self.candidates = []
                self.securityTarget = path; self.securityProbe = info
                self.securityCredential = "HDD key"; self.securityPassword = ""
                self.selectedSavedKey = ""; self.unlockFromScan = true
                self.refreshSavedKeys(); self.showSecurityProbe = true
                self.status = "This drive is locked. Select or enter the correct HDD key to unlock it."
            }
        }
    }
    func attach(_ c: BrowserCandidate) async throws {
        var r = BrowserRequest(.browse); r.source = source; r.offset = c.offset; r.length = c.length; r.sectorSize = c.sectorSize
        let reply = try await client.send(r)
        configuration = r; currentDirectory = "/"; connected = true; chooseVolume = false; apply(reply)
    }
    func openChosenVolume(custom: Bool) {
        work("Opening volume…") {
            let candidate: BrowserCandidate
            if custom {
                func number(_ raw: String) throws -> UInt64 {
                    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard let result = value.lowercased().hasPrefix("0x") ? UInt64(value.dropFirst(2), radix: 16) : UInt64(value) else { throw FATXError("Enter unsigned decimal or 0x hexadecimal bounds") }
                    return result
                }
                candidate = BrowserCandidate(name: "Custom volume", offset: try number(self.customOffset), length: try number(self.customLength), sectorSize: self.customSector)
            } else {
                guard let chosen = self.candidates.first(where: { $0.id == self.selectedCandidate }) else { throw FATXError("Select a volume") }; candidate = chosen
            }
            try await self.attach(candidate)
        }
    }
    func navigate(_ path: String) {
        work("Reading folder…") {
            var r = self.request(.browse); r.directory = path
            let reply = try await self.client.send(r); self.currentDirectory = path; self.apply(reply)
        }
    }
    func up() {
        let pieces = currentDirectory.split(separator: "/").dropLast()
        navigate("/" + pieces.joined(separator: "/"))
    }
    func openSelection() {
        guard let item = selectedItems.first else { return }
        if item.directory { navigate(item.path) } else { previewSelection() }
    }
    func importPanel() {
        let panel = NSOpenPanel(); panel.title = "Import files and folders"; panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        if panel.runModal() == .OK { importURLs(panel.urls, into: currentDirectory) }
    }
    func importURLs(_ urls: [URL], into path: String) {
        guard connected && !urls.isEmpty else { return }
        work("Preparing import…") {
            let staging = try await self.client.stageImports(urls)
            defer { Task { await self.client.discard(staging) } }
            var r = self.request(.importPreview); r.directory = path; r.localPaths = staging.items.map(\.path)
            let plan = try await self.client.send(r).importPreview
            if let plan, !plan.conflicts.isEmpty {
                let alert = NSAlert(); alert.messageText = "Replace existing files?"
                alert.informativeText = "\(plan.conflicts.count) existing path(s) conflict. Files will be replaced and folders merged.\n\n" + plan.conflicts.prefix(8).joined(separator: "\n")
                alert.addButton(withTitle: "Replace & Merge"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { self.status = "Import cancelled"; return }
                r.replace = true
            }
            r.command = .importItems; r.journal = try self.journal(); self.status = "Importing files…"
            _ = try await self.client.send(r)
            self.apply(try await self.client.send(self.request(.browse)))
            self.status = "Import complete"
        }
    }
    func exportPanel() {
        let selected = selectedItems; guard !selected.isEmpty else { return }
        let destination: String
        if selected.count == 1 {
            let panel = NSSavePanel(); panel.title = "Export \(selected[0].name)"; panel.nameFieldStringValue = selected[0].name; panel.canCreateDirectories = true
            panel.message = "Choose a new export name. Existing Mac files and folders are never overwritten."
            guard panel.runModal() == .OK, let url = panel.url else { return }; destination = url.path
        } else {
            let panel = NSOpenPanel(); panel.title = "Export selected items into folder"; panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }; destination = url.path + "/"
        }
        var r = request(.exportItems); r.paths = selected.map(\.path); r.destination = destination
        work("Exporting…") { let reply = try await self.client.send(r); self.status = reply.message }
    }
    func prompt(_ title: String, value: String, button: String) -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 350, height: 26); alert.accessoryView = field
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }; return field.stringValue
    }
    func newFolder() {
        guard let name = prompt("New folder", value: "New Folder", button: "Create") else { return }
        var r = request(.mkdir); r.destination = (currentDirectory == "/" ? "" : currentDirectory) + "/" + name
        mutate(r, title: "Creating folder…")
    }
    func renameSelection() {
        guard selectedItems.count == 1, let item = selectedItems.first, let name = prompt("Rename \(item.name)", value: item.name, button: "Rename") else { return }
        guard !name.contains("/") else { showError(FATXError("A name cannot contain /")); return }
        var r = request(.move); r.paths = [item.path]; r.destination = (currentDirectory == "/" ? "" : currentDirectory) + "/" + name
        mutate(r, title: "Renaming…")
    }
    func moveSelection() {
        guard !selection.isEmpty, let target = prompt("Move to FATX folder", value: "/", button: "Move") else { return }
        movePaths(selectedItems.map(\.path), into: target)
    }
    func movePaths(_ paths: [String], into folder: String) {
        var r = request(.move); r.paths = paths; r.destination = folder.hasSuffix("/") ? folder : folder + "/"
        mutate(r, title: "Moving…")
    }
    func deleteSelection() {
        let chosen = selectedItems; guard !chosen.isEmpty else { return }
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Delete \(chosen.count) item(s) permanently?"
        alert.informativeText = "Folders and their contents will be deleted from the original device volume.\n\n" + chosen.prefix(8).map(\.name).joined(separator: "\n")
        alert.addButton(withTitle: "Delete"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var r = request(.delete); r.paths = chosen.map(\.path); mutate(r, title: "Deleting…")
    }
    func mutate(_ request: BrowserRequest, title: String) {
        work(title) { var r = request; r.journal = try self.journal(); self.apply(try await self.client.send(r)) }
    }
    func checkVolume() {
        work("Checking volume…") {
            let response = try await self.client.send(self.request(.check))
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            self.report = "VOLUME GEOMETRY\n" + String(decoding: try encoder.encode(response.info), as: UTF8.self) + "\n\nVOLUME CHECK\n" + String(decoding: try encoder.encode(response.check), as: UTF8.self)
            self.showReport = true; self.status = "Volume check passed"
        }
    }
    func previewSelection() {
        guard let item = selectedItems.first, !item.directory else { return }
        var r = request(.preview); r.paths = [item.path]
        work("Reading preview…") {
            let response = try await self.client.send(r)
            self.report = "\(item.name)\n\(item.size) bytes · cluster \(item.firstCluster) · attributes 0x\(String(item.attributes, radix: 16))\n\n" + (response.preview ?? "")
            self.showReport = true; self.status = "Preview ready (up to 64 KiB)"
        }
    }
    func recover() {
        guard !source.isEmpty else { return }
        let panel = NSOpenPanel(); panel.title = "Choose interrupted operation's journal"; panel.directoryURL = journalFolder
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var r = BrowserRequest(.recover); r.source = source; r.journal = url.path
        work("Recovering interrupted operation…") {
            _ = try await self.client.send(r)
            if self.connected { self.apply(try await self.client.send(self.request(.browse))) }
            self.status = "Recovery complete"
        }
    }
    func disconnect() {
        guard !busy else { return }; connected = false; items = []; selection = []; info = nil; source = ""; sourceName = ""; status = "Disconnected"
    }
    func eject() {
        var r = request(.eject); r.source = source
        work("Ejecting device…") { _ = try await self.client.send(r); self.connected = false; self.items = []; self.source = ""; self.sourceName = ""; self.status = "Device ejected" }
    }
}
