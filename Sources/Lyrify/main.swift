import AppKit
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!

    func applicationDidFinishLaunching(_ notification: Notification) {
        let vm = LyricsViewModel()

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.level = .floating
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.backgroundColor = .clear
        window.hasShadow = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.title = "Lyrify"
        window.minSize = NSSize(width: 180, height: 120)

        let hosting = NSHostingView(rootView: ContentView(vm: vm))
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)

        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 49 { // spacebar
                DispatchQueue.global().async { SpotifyBridge.playPause() }
                return nil
            }
            return event
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
