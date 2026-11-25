import SwiftUI
import Carbon

struct KeyChord: Codable, Equatable {
    let key: UInt32
    let modifiers: UInt32
    let character: String
    static let standard = Self(key: UInt32(kVK_ANSI_L), modifiers: UInt32(cmdKey | shiftKey), character: "L")

    var title: String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { modifiers & UInt32($0.0) != 0 }.map(\.1).joined() + character
    }

    init(key: UInt32, modifiers: UInt32, character: String) {
        self.key = key
        self.modifiers = modifiers
        self.character = character
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags
        guard !flags.intersection([.command, .control, .option]).isEmpty else { return nil }
        let special = [kVK_Space: "Space", kVK_Tab: "Tab", kVK_Return: "Return", kVK_Delete: "Delete",
                       kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"]
        let label = special[Int(event.keyCode)] ?? event.characters(byApplyingModifiers: [])?.uppercased()
        guard let character = label, !character.isEmpty,
              character.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && $0.properties.generalCategory != .privateUse }) else { return nil }
        key = UInt32(event.keyCode)
        modifiers = [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)]
            .reduce(UInt32(0)) { flags.contains($1.0) ? $0 | UInt32($1.1) : $0 }
        self.character = character
    }
}

@MainActor @Observable final class LauncherShortcut {
    private(set) var binding: KeyChord
    private(set) var enabled: Bool
    private(set) var registered = false
    var issue: String?
    @ObservationIgnored private var hotKey: EventHotKeyRef?
    @ObservationIgnored private var handler: EventHandlerRef?
    @ObservationIgnored var action: (() -> Void)?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        binding = defaults.data(forKey: "launcherKeyChord").flatMap { try? JSONDecoder().decode(KeyChord.self, from: $0) } ?? .standard
        enabled = defaults.object(forKey: "launcherShortcutEnabled") as? Bool ?? true
    }

    func setEnabled(_ enabled: Bool) {
        self.enabled = enabled
        defaults.set(enabled, forKey: "launcherShortcutEnabled")
        if enabled { register() } else { suspend(); issue = nil }
    }

    func setBinding(_ chord: KeyChord) {
        let old = binding
        suspend()
        binding = chord
        register()
        if enabled && !registered {
            let error = issue
            binding = old
            register()
            issue = error
            return
        }
        defaults.set(try? JSONEncoder().encode(chord), forKey: "launcherKeyChord")
    }

    func suspend() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        registered = false
    }

    func register() {
        guard enabled, !registered else { return }
        suspend()
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            var id = EventHotKeyID()
            guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                    nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                  id.signature == 0x47535657, id.id == 1, let context else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<LauncherShortcut>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { shortcut.action?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
        registered = status == noErr && RegisterEventHotKey(binding.key, binding.modifiers,
            EventHotKeyID(signature: 0x47535657, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
        issue = registered ? nil : "macOS couldn’t register \(binding.title). Choose another shortcut."
    }
}

struct ShortcutSettings: View {
    let shortcut: LauncherShortcut
    @State private var monitor: Any?
    @State private var window: NSWindow?

    var body: some View {
        Section("Global shortcuts") {
            Toggle("PR launcher", isOn: Binding(get: { shortcut.enabled }, set: { shortcut.setEnabled($0) }))
            HStack {
                Button(monitor == nil ? shortcut.binding.title : "Press shortcut…") {
                    if monitor != nil { finish(); return }
                    window = NSApp.keyWindow
                    shortcut.suspend()
                    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                        guard event.window === window else { return event }
                        if event.keyCode == UInt16(kVK_Escape) { finish(); return nil }
                        if let chord = KeyChord(event: event) { finish(chord) }
                        else { shortcut.issue = "Use Command, Option, or Control with another key." }
                        return nil
                    }
                }.disabled(!shortcut.enabled).accessibilityLabel("Record PR launcher shortcut")
                Button("Reset") { finish(.standard) }
            }
            if let issue = shortcut.issue { Text(issue).foregroundStyle(Ink.red).font(.caption) }
        }.onDisappear { if monitor != nil { finish() } }
            .onChange(of: shortcut.enabled) { if !shortcut.enabled && monitor != nil { finish() } }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { note in
                if monitor != nil, note.object as? NSWindow === window { finish() }
            }
    }

    private func finish(_ chord: KeyChord? = nil) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        window = nil
        if let chord { shortcut.setBinding(chord) } else { shortcut.register() }
    }
}
