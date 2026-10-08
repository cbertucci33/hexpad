import SwiftUI
import AppKit
import HexpadKit

@main
struct HexpadApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 800, minHeight: 600)
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable automatic window tabbing for proper tab behavior
        NSWindow.allowsAutomaticWindowTabbing = false
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

struct ContentView: View {
    @StateObject private var tabStore = TabStore()
    @State private var selectedTheme = HexpadTheme.dark
    @State private var showFindBar = false
    @State private var findText = ""
    @State private var replaceText = ""
    @State private var findOptions = SearchOptions()
    
    var body: some View {
        MainWindow(tabStore: tabStore, theme: $selectedTheme, showFindBar: $showFindBar)
            .onAppear {
                restoreSession()
            }
            .onReceive(NSNotification.Name(" applicationWillTerminate")) { _ in
                saveSession(tabStore)
            }
    }
    
    private func restoreSession() {
        if let (tabs, index) = SessionStore.restore() {
            tabStore.documents = tabs.documents
            tabStore.selectedIndex = index
        }
    }
    
    private func saveSession(_ tabs: TabStore) {
        try? SessionStore.save(tabs)
    }
}
