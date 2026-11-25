import SwiftUI

@MainActor final class WindowControls {
    weak var window: NSWindow?
    private var enteredFullScreen = false
    let shortcut = LauncherShortcut()
    let launcher = PRLauncher()

    func toggleFileFocus(_ store: Workspace) {
        guard store.selected != nil, let window else { return }
        if store.focusingFile {
            store.focusingFile = false
            if enteredFullScreen && window.styleMask.contains(.fullScreen) { window.toggleFullScreen(nil) }
            enteredFullScreen = false
        } else {
            store.focusTreeVisible = false
            store.review.tab = .code
            store.focusingFile = true
            enteredFullScreen = !window.styleMask.contains(.fullScreen)
            if enteredFullScreen { window.toggleFullScreen(nil) }
        }
    }


}


struct WindowReader: NSViewRepresentable {
    let controls: WindowControls
    final class Probe: NSView {
        var controls: WindowControls?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            controls?.window = window
            window.backgroundColor = NSColor(Ink.detail)
            window.titlebarAppearsTransparent = true
        }
    }
    func makeNSView(context: Context) -> Probe { let probe = Probe(); probe.controls = controls; return probe }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
