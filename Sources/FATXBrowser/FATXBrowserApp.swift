import SwiftUI
import AppKit

@main
@MainActor
struct FATXBrowserApp: App {
    @StateObject private var model = BrowserModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    var body: some Scene {
        Window("FATX Browser", id: "browser") {
            BrowserView(model: model)
                .frame(minWidth: 960, minHeight: 590)
                .background(BrowserWindowReader { appDelegate.register($0) })
                .onAppear {
                    appDelegate.isBusy = { model.busy }
                    NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true)
                }
        }
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Show Browser") { appDelegate.showBrowser() }.keyboardShortcut("0")
                Divider()
                Button("Open Image…") { model.openImage() }.keyboardShortcut("o").disabled(model.busy)
                Button("New Folder…") { model.newFolder() }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!model.connected || model.busy)
            }
            CommandMenu("Volume") {
                Button("Format Device…") { model.beginFormat() }.disabled(model.busy || !model.deviceSessionAuthorized || model.devices.isEmpty)
                Button("Drive Security…") { model.beginSecurityProbe() }.disabled(model.busy || !model.deviceSessionAuthorized || model.devices.isEmpty)
                Divider()
                Button("Import Files & Folders…") { model.importPanel() }.keyboardShortcut("i").disabled(!model.connected || model.busy)
                Button("Export Selected…") { model.exportPanel() }.keyboardShortcut("e").disabled(model.selection.isEmpty || model.busy)
                Divider()
                Button("Refresh") { model.navigate(model.currentDirectory) }.keyboardShortcut("r").disabled(!model.connected || model.busy)
                Button("Check Volume…") { model.checkVolume() }.disabled(!model.connected || model.busy)
                Button("Recover Interrupted Write…") { model.recover() }.disabled(model.source.isEmpty || model.busy)
                Button("Show Journals in Finder") { NSWorkspace.shared.open(model.journalFolder) }
                Divider()
                Button("Device Access & Permissions…") { model.showAccessSetup = true }
            }
        }
        Settings {
            VStack(alignment: .leading, spacing: 14) {
                Text("FATX Browser").font(.title2.bold())
                Text("Write journals are created automatically. Keep unfinished journals until recovery is complete.").foregroundStyle(.secondary)
                Text(model.journalFolder.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Button("Show Journals in Finder") { NSWorkspace.shared.open(model.journalFolder) }
            }.padding(24).frame(width: 460)
        }
    }
}
