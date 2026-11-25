import SwiftUI

/// Only consume digits in the owning workspace window. Sheets keep their own keys.
struct SidebarShortcuts: NSViewRepresentable {
    let held: (Bool) -> Void
    let select: (Int) -> Bool

    final class Monitor: NSView {
        var actions: SidebarShortcuts?
        private var monitor: Any?
        private var resign: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard let window else { return }
            resign = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.actions?.held(false) }
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self, weak window] event in
                guard let self, let window, window.isKeyWindow, window.attachedSheet == nil else { return event }
                let command = event.modifierFlags.intersection([.command, .option, .control, .shift]) == .command
                if event.type == .flagsChanged { actions?.held(command) }
                else if command, let key = event.charactersIgnoringModifiers, let n = Int(key),
                        (1...9).contains(n), actions?.select(n) == true { return nil }
                return event
            }
        }

        func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            if let resign { NotificationCenter.default.removeObserver(resign) }
            monitor = nil
            resign = nil
        }
    }
    func makeNSView(context: Context) -> Monitor { let view = Monitor(); view.actions = self; return view }
    func updateNSView(_ view: Monitor, context: Context) { view.actions = self }
    static func dismantleNSView(_ view: Monitor, coordinator: ()) { view.stop() }
}

struct SidebarRowFrames: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]
    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
    static func shortcuts(_ frames: [String: CGRect], height: CGFloat) -> [String] {
        Array(frames.filter { $0.value.midY >= 0 && $0.value.midY <= height }.sorted { $0.value.midY < $1.value.midY }.prefix(9).map(\.key))
    }
}
