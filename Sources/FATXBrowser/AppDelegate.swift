import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var isBusy: (() -> Bool)?
    // Keep the primary window alive after its red close button is pressed.
    var mainWindow: NSWindow?
    func register(_ window: NSWindow) {
        mainWindow = window; window.isReleasedWhenClosed = false
    }
    func showBrowser() {
        guard let window = mainWindow else { return }
        window.deminiaturize(nil); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard mainWindow != nil else { return true }
        showBrowser(); return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard isBusy?() == true else { return .terminateNow }
        let alert = NSAlert(); alert.messageText = "An operation is still running"
        alert.informativeText = "Wait for the operation to finish before quitting FATX Browser."
        alert.addButton(withTitle: "Keep App Open"); alert.runModal()
        return .terminateCancel
    }
}
@MainActor
struct BrowserWindowReader: NSViewRepresentable {
    let register: (NSWindow) -> Void
    func makeNSView(context: Context) -> WindowProbe { WindowProbe(register: register) }
    func updateNSView(_ view: WindowProbe, context: Context) { if let window = view.window { register(window) } }
    final class WindowProbe: NSView {
        let register: (NSWindow) -> Void
        init(register: @escaping (NSWindow) -> Void) { self.register = register; super.init(frame: .zero) }
        required init?(coder: NSCoder) { return nil }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { register(window) } }
    }
}
