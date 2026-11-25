import SwiftUI

struct DropdownOption: Identifiable {
    let id: String
    let title: String
    let symbol: String
    let selected: Bool
    let action: () -> Void

    init(_ title: String, icon: String, id: String? = nil, selected: Bool = false, action: @escaping () -> Void) {
        self.id = id ?? title
        self.title = title
        self.symbol = icon
        self.selected = selected
        self.action = action
    }
}

struct Dropdown<Trigger: View>: View {
    var width: CGFloat = 236
    var edge: Edge = .bottom
    let options: () -> [DropdownOption]
    @ViewBuilder let label: () -> Trigger
    @State private var open = false
    @State private var hovered = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                label()
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Ink.dim)
            }
            .padding(.horizontal, 5).frame(minHeight: 24)
            .background(open || hovered ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .popover(isPresented: $open, arrowEdge: edge) {
            DropdownList(options: options()) { option in
                open = false
                if let option { option.action() }
            }
            .frame(width: width)
            .preferredColorScheme(.dark)
        }
    }
}

private struct DropdownList: View {
    let options: [DropdownOption]
    let finish: (DropdownOption?) -> Void
    @State private var cursor: String?
    @FocusState private var focused: Bool
    @State private var prefix = ""
    @State private var typedAt = Date.distantPast

    var body: some View {
        ScrollViewReader { scroll in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(options) { option in
                        Button { finish(option) } label: {
                            HStack(spacing: 9) {
                                Image(systemName: option.symbol).frame(width: 18).foregroundStyle(Ink.dim)
                                Text(option.title).lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 3)
                                if option.selected { Image(systemName: "checkmark").foregroundStyle(Ink.blue) }
                            }.font(.system(size: 12, weight: .medium))
                                .padding(.horizontal, 9).frame(height: 30)
                                .background(cursor == option.id ? Ink.selection : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                        }.buttonStyle(.plain).focusable(false)
                            .accessibilityAddTraits(option.selected ? .isSelected : [])
                            .onHover { if $0 { cursor = option.id } }
                            .id(option.id)
                    }
                }.padding(5)
            }
            .frame(height: CGFloat(min(9, options.count)) * 32 + 8)
            .foregroundStyle(Ink.text)
            .background(Ink.surface)
            .focusable().focused($focused).focusEffectDisabled()
            .onAppear {
                focused = true
                cursor = options.first(where: \.selected)?.id ?? options.first?.id
            }
            .onChange(of: cursor) { _, id in if let id { scroll.scrollTo(id) } }
            .onKeyPress(.downArrow) { move(1); return .handled }
            .onKeyPress(.upArrow) { move(-1); return .handled }
            .onKeyPress(keys: [.return, .space]) { _ in
                if let option = options.first(where: { $0.id == cursor }) { finish(option) }
                return .handled
            }
            .onKeyPress(characters: .alphanumerics) { key in
                guard key.modifiers.intersection([.command, .control, .option]).isEmpty else { return .ignored }
                if Date.now.timeIntervalSince(typedAt) > 0.7 { prefix = "" }
                prefix += key.characters.lowercased()
                typedAt = .now
                if let option = options.first(where: { $0.title.lowercased().hasPrefix(prefix) }) { cursor = option.id }
                return .handled
            }
            .onExitCommand { finish(nil) }
        }
    }

    private func move(_ step: Int) {
        guard !options.isEmpty else { return }
        let index = options.firstIndex { $0.id == cursor } ?? (step > 0 ? -1 : 0)
        cursor = options[(index + step + options.count) % options.count].id
    }
}

struct DropdownField: View {
    let title: String
    let value: String
    let options: () -> [DropdownOption]

    var body: some View {
        LabeledContent(title) {
            Dropdown(width: 300, options: options) {
                Text(value).lineLimit(1).truncationMode(.middle)
            }
            .background(Ink.surface, in: RoundedRectangle(cornerRadius: 5))
            .accessibilityLabel(title + ", " + value)
        }
    }
}
