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

/// AppKit tracks the drag across displays and honors the system double-click interval.
struct WindowDragSurface: NSViewRepresentable {
    final class Surface: NSView {
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            guard let window, window.attachedSheet == nil else { return }
            if event.clickCount == 2 {
                window.toggleFullScreen(nil)
            } else if event.clickCount == 1 {
                window.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> Surface { Surface() }
    func updateNSView(_ view: Surface, context: Context) {}
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
