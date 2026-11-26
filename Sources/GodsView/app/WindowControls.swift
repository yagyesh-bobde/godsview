import SwiftUI

@MainActor @Observable final class WindowControls {
    var headerHeight: CGFloat = 32
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
                // Fill the current desktop (zoom), not a separate full-screen space.
                window.zoom(nil)
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
            // AppKit re-lays out its title bar on resize, on leaving full screen and when the
            // window gains or loses focus, so the buttons are placed again after each of those.
            NotificationCenter.default.removeObserver(self)
            for name in [NSWindow.didResizeNotification, NSWindow.didExitFullScreenNotification,
                         NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                         NSWindow.didBecomeMainNotification, NSWindow.didResignMainNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(titlebarChanged), name: name, object: window)
            }
            titlebarChanged()
        }
        @objc private func titlebarChanged() {
            placeTrafficLights()
            updateHeaderHeight()
        }

        /// The header is 52 points, the standard macOS toolbar height. A real NSToolbar would
        /// size it for us, but it makes SwiftUI re-measure the whole window on every diff scroll
        /// step, so the title bar area is enlarged and the traffic lights centered by hand.
        static let titlebarHeight: CGFloat = 52

        private func placeTrafficLights() {
            guard let window, !window.styleMask.contains(.fullScreen),
                  let close = window.standardWindowButton(.closeButton),
                  let container = close.superview?.superview else { return }
            let height = Self.titlebarHeight
            var frame = container.frame
            if frame.height != height || frame.minY != window.frame.height - height {
                frame.size.height = height
                frame.origin.y = window.frame.height - height
                container.frame = frame
            }
            // The title bar view that holds the buttons must grow too, or it clips them.
            if let bar = close.superview, bar !== container, bar.frame != container.bounds { bar.frame = container.bounds }
            let center = window.frame.height - height / 2  // window coordinates, from the bottom
            // Same inset from the left as from the top, like a standard toolbar window.
            let shift = (height / 2 - close.frame.midX).rounded()
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), let parent = button.superview else { continue }
                let y = (parent.convert(CGPoint(x: 0, y: center), from: nil).y - button.frame.height / 2).rounded()
                let origin = CGPoint(x: button.frame.minX + shift, y: y)
                if abs(button.frame.minY - y) > 0.5 || shift != 0 { button.setFrameOrigin(origin) }
            }
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateHeaderHeight()
        }

        private func updateHeaderHeight() {
            Task { @MainActor [weak self] in
                guard let self, let window, !window.styleMask.contains(.fullScreen),
                      let close = window.standardWindowButton(.closeButton), close.window === window else { return }
                let center = close.convert(CGPoint(x: close.bounds.midX, y: close.bounds.midY), to: nil)
                let height = (2 * (window.frame.height - center.y)).rounded()
                // Ignore transient button positions while AppKit reparents its title bar.
                if (28...60).contains(height), controls?.headerHeight != height { controls?.headerHeight = height }
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let probe = Probe(); probe.controls = controls; return probe }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
