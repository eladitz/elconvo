// `--tour <folder>`: Elconvo uses itself, step by step at a watchable pace, for the screen recording App Review
// asks new developers for: the format wheel and a conversion, the tools wheel and a tool, a video conversion
// and the main window, on made-up files in `folder`, on a plain backdrop. Then it quits.

import AppKit

@MainActor
enum Tour {
    /// The display with the menu bar: the one the recording is made of (not "the main screen", which is
    /// whichever screen the active window happens to be on).
    static var screen: NSScreen { NSScreen.screens.first! }
    /// Set while a tour runs; popups that follow the pointer's screen use this one instead.
    nonisolated(unsafe) static var active: NSScreen?

    private static var backdrop: NSWindow?

    static func run(_ folder: URL) {
        active = screen
        stage()
        let photo = folder.appendingPathComponent("Mountains.jpg")
        let clip = folder.appendingPathComponent("Sunset clip.mov")
        let screen = Tour.screen.visibleFrame
        let centre = NSPoint(x: screen.midX, y: screen.midY + 60)
        Task {
            func pause(_ s: Double) async { try? await Task.sleep(for: .seconds(s)) }
            @MainActor func wheel(_ tools: Bool, then choose: PetalAction, on urls: [URL]) async {
                Shelf.shared.showWheel(for: urls, at: centre, tools: tools)
                await pause(1.2)
                for i in [0, 1, 2, 3, 2, 1] { Shelf.shared.hovered = i; await pause(0.45) }   // pointing at the petals
                await pause(0.6)
                Shelf.shared.hide()
                Shelf.shared.perform(choose, urls: urls)
            }
            await pause(1.5)
            JobHUD.notice("Hold ⇧ Shift while dragging a file", "A wheel of formats opens around the pointer")
            await pause(2)
            await wheel(false, then: .convert(Formats.byID("png")!), on: [photo])
            await pause(3.5)
            JobHUD.notice("Add ⌥ Option for tools", "Compress, resize, remove background, crop, trim…")
            await pause(2)
            await wheel(true, then: .op(.compress), on: [photo])
            await pause(3.5)
            JobHUD.notice("Video too", "MP4, MOV, HEVC, WebM, GIF, audio…")
            await pause(1.5)
            await wheel(false, then: .convert(Formats.byID("mp4")!), on: [clip])
            await pause(5)
            Store.shared.add([photo, clip])
            if let app = NSApp.delegate as? AppDelegate {
                app.showMainWindow()
                Tour.centre(app.window)
            }
            await pause(4.5)
            NSApp.terminate(nil)
        }
    }

    static func centre(_ window: NSWindow?) {
        guard let window else { return }
        let v = screen.visibleFrame, size = window.frame.size
        window.setFrameOrigin(NSPoint(x: v.midX - size.width / 2, y: v.midY - size.height / 2))
        window.orderFrontRegardless()
    }

    /// A plain dark backdrop over the main screen, behind Elconvo's wheel and windows.
    private static func stage() {
        let screen = Tour.screen
        let w = NSWindow(contentRect: screen.visibleFrame, styleMask: [.borderless], backing: .buffered, defer: false)
        w.backgroundColor = NSColor(srgbRed: 0.09, green: 0.10, blue: 0.14, alpha: 1)
        w.isReleasedWhenClosed = false
        w.ignoresMouseEvents = true
        w.level = .normal
        w.orderFrontRegardless()
        backdrop = w
    }
}
