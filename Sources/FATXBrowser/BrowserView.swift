import SwiftUI
import AppKit
import FATXService

@MainActor
struct BrowserView: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Image(systemName: "externaldrive.fill").font(.title2).foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 1) { Text("FATX Browser").font(.headline); Text("FATX storage, on your Mac").font(.caption).foregroundStyle(.secondary) }
                }.padding(18)
                if !model.deviceSessionAuthorized {
                    Button("Enable Device Access…") { model.authorizeDevices() }.padding(.horizontal, 18).padding(.bottom, 12).disabled(model.busy)
                }
                List {
                    Section("EXTERNAL DEVICES") {
                        if model.devices.isEmpty { Text("No external disks found").foregroundStyle(.secondary).font(.caption) }
                        ForEach(model.devices) { device in
                            Button { model.probe(device.path, name: device.name) } label: {
                                Label {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(device.name).lineLimit(1)
                                        Text("\(device.path) · \(ByteCountFormatter.string(fromByteCount: Int64(device.size), countStyle: .file))").font(.caption2).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "externaldrive") }
                            }.buttonStyle(.plain).disabled(model.busy || !model.deviceSessionAuthorized).help("Unmount & open \(device.path)")
                        }
                    }
                    Section("IMAGES") { Button { model.openImage() } label: { Label("Open Disk Image…", systemImage: "doc.badge.plus") }.buttonStyle(.plain).disabled(model.busy) }
                    if model.connected {
                        Section("OPEN VOLUME") {
                            Label(model.sourceName, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            Button("Root Folder") { model.navigate("/") }.disabled(model.busy)
                            Button("Check Volume…") { model.checkVolume() }.disabled(model.busy)
                            Button("Disconnect") { model.disconnect() }.disabled(model.busy)
                            if model.source.hasPrefix("/dev/") { Button("Eject Device") { model.eject() }.disabled(model.busy) }
                        }
                    }
                }.listStyle(.sidebar)
                HStack { Button { model.refreshDevices() } label: { Label("Refresh", systemImage: "arrow.clockwise") }; Spacer() }.buttonStyle(.borderless).padding(14).disabled(model.busy)
            }
            .navigationSplitViewColumnWidth(min: 235, ideal: 260, max: 330)
        } detail: {
            VStack(spacing: 0) {
                if model.connected {
                    HStack(spacing: 10) {
                        Button { model.up() } label: { Image(systemName: "chevron.up") }.disabled(model.currentDirectory == "/" || model.busy).help("Enclosing folder")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 5) {
                                Button("Root") { model.navigate("/") }
                                ForEach(Array(model.currentDirectory.split(separator: "/").enumerated()), id: \.offset) { i, part in
                                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                                    Button(String(part)) { model.navigate("/" + model.currentDirectory.split(separator: "/").prefix(i + 1).joined(separator: "/")) }
                                }
                            }.buttonStyle(.borderless).disabled(model.busy)
                        }
                        TextField("Filter files", text: $model.query).textFieldStyle(.roundedBorder).frame(width: 160)
                    }.padding(12)
                    Divider()
                    ZStack {
                        FileTable(model: model)
                        if model.items.isEmpty && !model.busy {
                            VStack(spacing: 9) {
                                Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.tertiary)
                                Text("This folder is empty").font(.headline)
                                Text("Drop files or folders from Finder to import.").font(.callout).foregroundStyle(.secondary)
                            }.allowsHitTesting(false)
                        }
                    }
                    Divider()
                    HStack {
                        Image(systemName: "externaldrive").foregroundStyle(.secondary)
                        Text("\(model.items.count) items\(model.selection.isEmpty ? "" : " · \(model.selection.count) selected")")
                        Spacer()
                        if let info = model.info { Text("\(info.byteOrder.rawValue == "little" ? "FATX" : "XTAF") · \(info.fatEntryBytes * 8)-bit FAT · \(model.configuration.sectorSize)-byte sectors").foregroundStyle(.secondary) }
                    }.font(.caption).padding(.horizontal, 14).padding(.vertical, 10)
                } else {
                    Spacer()
                    VStack(spacing: 14) {
                        Image(systemName: "externaldrive.badge.plus").font(.system(size: 58, weight: .light)).foregroundStyle(.green)
                        Text("Your files. On your Mac.").font(.title2.bold())
                        Text("Choose an external device in the sidebar, or open a disk image.\nDevices are unmounted before opening.").multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Open Disk Image…") { model.openImage() }.buttonStyle(.borderedProminent).disabled(model.busy)
                        if !model.source.isEmpty {
                            HStack { Button("Choose Volume…") { model.chooseVolume = true }; Button("Recover Interrupted Write…") { model.recover() } }.disabled(model.busy)
                        }
                    }.padding(30)
                    Spacer()
                }
                Divider()
                HStack(spacing: 8) {
                    if model.busy { ProgressView().controlSize(.small) }
                    Text(model.status).font(.caption).lineLimit(2)
                    Spacer()
                }.padding(.horizontal, 14).padding(.vertical, 9).background(.bar)
            }
        }
        .navigationTitle(model.connected ? model.sourceName : "FATX Browser")
        .toolbar {
            ToolbarItemGroup {
                Button { model.importPanel() } label: { Label("Import", systemImage: "square.and.arrow.down") }.disabled(!model.connected || model.busy)
                Button { model.exportPanel() } label: { Label("Export", systemImage: "square.and.arrow.up") }.disabled(model.selection.isEmpty || model.busy)
                Button { model.newFolder() } label: { Label("New Folder", systemImage: "folder.badge.plus") }.disabled(!model.connected || model.busy)
            }
            ToolbarItem {
                Menu {
                    Button("Open / Preview") { model.openSelection() }.disabled(model.selection.count != 1)
                    Button("Rename…") { model.renameSelection() }.disabled(model.selection.count != 1)
                    Button("Move To…") { model.moveSelection() }.disabled(model.selection.isEmpty)
                    Button("Delete…", role: .destructive) { model.deleteSelection() }.disabled(model.selection.isEmpty)
                    Divider()
                    Button("Refresh Folder") { model.navigate(model.currentDirectory) }
                    Button("Volume Info & Check…") { model.checkVolume() }
                    Button("Recover Interrupted Write…") { model.recover() }
                    Button("Show Journals in Finder") { NSWorkspace.shared.open(model.journalFolder) }
                } label: { Label("Actions", systemImage: "ellipsis.circle") }.disabled(!model.connected || model.busy)
            }
        }
        .toolbarBackground(.visible, for: .windowToolbar)
        .onAppear { model.start() }
        .sheet(isPresented: $model.showAccessSetup) { AccessSetupView(model: model) }
        .sheet(isPresented: $model.chooseVolume) { VolumeChooser(model: model) }
        .sheet(isPresented: $model.showReport) {
            VStack(alignment: .leading, spacing: 14) {
                Text("Volume report / preview").font(.headline)
                ScrollView { Text(model.report).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Done") { model.showReport = false }.keyboardShortcut(.defaultAction) }
            }.padding(22).frame(width: 700, height: 480)
        }
    }
}
@MainActor
struct AccessSetupView: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Full Disk Access", systemImage: "externaldrive.badge.checkmark").font(.title2.bold())
            Text("Allow FATX Browser to access your FATX device. You enable this permission in macOS System Settings.")
            Text("1. Open Privacy & Security → Full Disk Access.\n2. Use + or drag the revealed FATX Browser app into the list and enable it.\n3. Quit and reopen FATX Browser after changing the permission.")
            ScrollView { Text(model.accessMessage).font(.callout).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 90)
            HStack {
                Button("Open System Settings") { model.openAccessSettings() }
                Button("Reveal This App") { model.revealApplication() }
            }
            Divider()
            HStack {
                Button("Later") { model.dismissAccessSetup() }.disabled(model.busy)
                Spacer()
                Button(model.deviceSessionAuthorized ? "Check Again" : "Enable Device Access…") { model.checkAccess() }.disabled(model.busy).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 560)
    }
}
@MainActor
struct VolumeChooser: View {
    @ObservedObject var model: BrowserModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Open FATX Volume").font(.title2.bold())
            Text(model.source).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            if !model.candidates.isEmpty {
                Picker("Detected volume", selection: $model.selectedCandidate) {
                    ForEach(model.candidates) { c in Text("\(c.name) · offset 0x\(String(c.offset, radix: 16)) · \(c.sectorSize)-byte sectors").tag(c.id) }
                }.disabled(model.useCustomGeometry)
            }
            Toggle("Use exact custom geometry", isOn: $model.useCustomGeometry)
            if model.useCustomGeometry || model.candidates.isEmpty {
                TextField("Offset (bytes)", text: $model.customOffset)
                TextField("Length (bytes)", text: $model.customLength)
                Picker("Sector size", selection: $model.customSector) { Text("512 bytes (HDD)").tag(512); Text("4096 bytes (FATX memory unit)").tag(4096) }
            }
            Text("The browser probes both sector sizes for standalone volumes. Memory units may use 4096-byte sectors.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Recover Write…") { model.chooseVolume = false; model.recover() }
                Spacer()
                Button("Cancel") { model.chooseVolume = false }
                Button("Open Volume") { model.openChosenVolume(custom: model.useCustomGeometry || model.candidates.isEmpty) }.buttonStyle(.borderedProminent).disabled(model.busy)
            }
        }.padding(24).frame(width: 600)
    }
}
