import SwiftUI
import Carbon

@MainActor final class WindowControls {
    weak var window: NSWindow?
    private var enteredFullScreen = false
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

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

    private var openSearch: (() -> Void)?

    func releaseSearchShortcut() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    func resumeSearchShortcut() -> Bool {
        guard let openSearch else { return false }
        return registerSearchShortcut(openSearch)
    }

    func registerSearchShortcut(_ action: @escaping () -> Void) -> Bool {
        openSearch = action
        guard handler == nil else { return hotKey != nil }
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var hotKeyID = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID) == noErr,
                  hotKeyID.signature == 0x47535657, hotKeyID.id == 1 else { return OSStatus(eventNotHandledErr) }
            if let context {
                let controls = Unmanaged<WindowControls>.fromOpaque(context).takeUnretainedValue()
                MainActor.assumeIsolated { controls.openSearch?() }
            }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return false }
        return RegisterEventHotKey(UInt32(kVK_ANSI_K), UInt32(controlKey | optionKey), EventHotKeyID(signature: 0x47535657, id: 1),
                            GetApplicationEventTarget(), 0, &hotKey) == noErr
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
