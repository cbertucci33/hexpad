// Headless UI geometry harness (Tools/): run with the compile line in
// macos-app-ui-verification skill section 3. Dumps every subview frame at
// launch, compact-resize, second-tab and find-bar-open states; exits cleanly.
import AppKit


// Headless geometry harness: reproduces HexpadAppDelegate.applicationDidFinishLaunching
// order verbatim (window init -> contentViewController = -> delegate -> makeKeyAndOrderFront
// -> restoreSession-equivalent -> applyPreferences-equivalent) with NO @main file,
// dumps every subview recursively, then exits.

final class HarnessAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: MainWindow?
    var controller: MainWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.mainMenu = NSMenu()  // real menu building needs the delegate; menu bars are not under test today

        let window = MainWindow()
        self.window = window

        let controller = MainWindowController(window: window)
        self.controller = controller

        window.contentViewController = controller
        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        // Session/restore paths touch Application Support; keep the harness
        // deterministic by skipping restoreSession() and applyPreferences()
        // (they are data-driven, not geometry-driven, and are covered by
        // SessionRestoreTests).

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self.dump("after-launch") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Compact resize: the classic layout-break probe.
            self.window?.setContentSize(NSSize(width: 820, height: 520))
            self.dump("after-compact-resize")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            // Second tab + split check: geometry under two documents.
            self.controller?.addNewTab()
            self.dump("after-second-tab")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
            // Find bar open: overlay/clip geometry.
            self.controller?.toggleFindBar()
            self.dump("after-findbar-open")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            NSApp.terminate(nil)
        }
    }

    func dump(_ label: String) {
        print("===== STATE: \(label) =====")
        guard let window = window else { print("window is nil!"); return }
        print("window frame: \(window.frame) contentBounds: \(window.contentView?.bounds ?? .zero)")
        if let contentView = window.contentView {
            dumpView(contentView, depth: 0)
        } else {
            print("contentView is nil!")
        }
        print("firstResponder: \(String(describing: NSApp.keyWindow?.firstResponder))")
    }

    func dumpView(_ view: NSView, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        let frame = view.frame
        let flags = "\(view.isHidden ? " HIDDEN" : "")\(frame.width == 0 || frame.height == 0 ? " ZERO-SIZE" : "")\(frame.minX < 0 || frame.minY < 0 ? " NEG-ORIGIN" : "")"
        print("\(indent)\(type(of: view)) frame=\(frame) mask=\(view.autoresizingMask.rawValue)\(flags)")
        for child in view.subviews {
            dumpView(child, depth: depth + 1)
        }
    }
}

let app = NSApplication.shared
let delegate = HarnessAppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // headless: no Dock icon, no focus stealing
app.run()
