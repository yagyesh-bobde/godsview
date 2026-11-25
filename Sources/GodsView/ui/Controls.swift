import SwiftUI

/// One set of corner radii for the whole window, so every control reads as the same family.
enum Radius {
    /// Small chips and badges inside rows.
    static let chip: CGFloat = 6
    /// Buttons, fields, tabs and list rows.
    static let control: CGFloat = 8
    /// Cards and grouped surfaces.
    static let card: CGFloat = 10
    /// Floating panels such as the palette and the launcher.
    static let panel: CGFloat = 14
}

/// Standard control heights. 28 points is the comfortable macOS hit target for toolbar
/// controls; the larger size is for the primary PR actions.
enum ControlSize {
    static let small: CGFloat = 26
    static let regular: CGFloat = 28
    static let large: CGFloat = 30
}

/// Text buttons. `primary` is a solid fill for the one main action in a group, `tinted` is a
/// soft colored fill for secondary actions that carry meaning (such as closing a PR), and
/// `secondary` and `ghost` are neutral.
struct ActionButtonStyle: ButtonStyle {
    enum Kind { case primary(Color), tinted(Color), outline(Color), accent(Color), quietDestructive(Color), secondary, ghost }
    var kind: Kind = .secondary
    var height: CGFloat = ControlSize.regular

    func makeBody(configuration: Configuration) -> some View {
        ActionButtonBody(configuration: configuration, kind: kind, height: height)
    }
}

private struct ActionButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: ActionButtonStyle.Kind
    let height: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        configuration.label
            .labelStyle(ActionLabelStyle())
            .font(.system(size: 12.5, weight: .semibold))
            .lineLimit(1)
            .padding(.horizontal, height >= ControlSize.large ? 11 : 10)
            .frame(height: height)
            .foregroundStyle(foreground)
            .background(fill, in: shape)
            .overlay {
                shape.strokeBorder(stroke, lineWidth: 1)
                if showsTopHighlight {
                    // Subtle top specular edge matching T3 Code's inset control highlight.
                    shape.strokeBorder(
                        LinearGradient(colors: [Color.white.opacity(topHighlightOpacity), .clear],
                                       startPoint: .top, endPoint: .center),
                        lineWidth: 1
                    )
                }
            }
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.42)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .onHover { hovered = $0 && enabled }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }

    private var lift: Double { configuration.isPressed ? 1.6 : (hovered ? 1.3 : 1) }

    private var showsTopHighlight: Bool {
        switch kind {
        case .primary, .secondary: true
        default: false
        }
    }

    private var topHighlightOpacity: Double {
        if case .primary = kind { return 0.28 }
        return hovered ? 0.12 : 0.08
    }

    private var foreground: Color {
        switch kind {
        case .primary: Color(white: 0.04)
        case .tinted(let tint): tint
        case .accent: Ink.text
        case .quietDestructive(let tint): hovered || configuration.isPressed ? tint : Ink.dim
        // Neutral at rest; the destructive color only appears on hover and press.
        case .outline(let tint): hovered || configuration.isPressed ? tint : Ink.text
        case .secondary, .ghost: Ink.text
        }
    }

    private var fill: Color {
        switch kind {
        case .primary(let tint): tint.opacity(configuration.isPressed ? 0.84 : (hovered ? 1 : 0.93))
        case .tinted(let tint): tint.opacity(0.13 * lift)
        case .accent(let tint): tint.opacity(0.14 * lift)
        case .quietDestructive(let tint): hovered || configuration.isPressed ? tint.opacity(0.11 * lift) : .clear
        case .outline(let tint): hovered || configuration.isPressed ? tint.opacity(0.1 * lift) : Color.white.opacity(0.055)
        case .secondary: Color.white.opacity(0.068 * lift)
        case .ghost: Color.white.opacity(hovered || configuration.isPressed ? 0.07 * lift : 0)
        }
    }

    private var stroke: Color {
        switch kind {
        case .primary(let tint): tint.opacity(0.55)
        case .tinted(let tint): tint.opacity(hovered ? 0.5 : 0.32)
        case .accent(let tint): tint.opacity(hovered ? 0.75 : 0.55)
        case .quietDestructive(let tint): hovered || configuration.isPressed ? tint.opacity(0.42) : Color.white.opacity(0.08)
        case .outline(let tint): hovered ? tint.opacity(0.45) : Color.white.opacity(0.1)
        case .secondary: Color.white.opacity(hovered ? 0.18 : 0.12)
        case .ghost: .clear
        }
    }
}

/// Icon and title with a fixed gap, so buttons line up whatever symbol they use.
private struct ActionLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.font(.system(size: 12, weight: .semibold)).imageScale(.medium)
            configuration.title
        }
    }
}

/// Square toolbar icons with a rounded hover state and a 28-point hit area.
struct IconButtonStyle: ButtonStyle {
    var size: CGFloat = ControlSize.regular
    var active = false

    func makeBody(configuration: Configuration) -> some View {
        IconButtonBody(configuration: configuration, size: size, active: active)
    }
}

private struct IconButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let size: CGFloat
    let active: Bool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control - 1, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: size, height: size)
            .foregroundStyle(active || hovered ? Ink.text : Ink.dim)
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : (hovered || active ? 0.07 : 0)), in: shape)
            .contentShape(shape)
            .opacity(enabled ? 1 : 0.38)
            .onHover { hovered = $0 && enabled }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
    }
}

/// A rounded text field shell shared by the sidebar, the file tree and sheets.
struct FieldChrome<Content: View>: View {
    var symbol: String? = "line.3.horizontal.decrease"
    var height: CGFloat = ControlSize.regular
    @ViewBuilder let content: () -> Content

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
        HStack(spacing: 7) {
            if let symbol { Image(systemName: symbol).font(.system(size: 11, weight: .medium)).foregroundStyle(Ink.faint) }
            content()
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: height)
        .background(Ink.field, in: shape)
        .overlay(shape.strokeBorder(Color.white.opacity(0.1)))
    }
}

/// A keyboard key, used in hints at the bottom of the palette and the launcher.
struct Keycap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 10.5, weight: .medium, design: .rounded))
            .foregroundStyle(Ink.dim)
            .padding(.horizontal, 5).frame(minWidth: 19, minHeight: 18)
            .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Color.white.opacity(0.1)))
    }
}

/// Small rounded tag for metadata such as a branch pair or a review decision.
struct MetaChip<Content: View>: View {
    var tint: Color = Ink.dim
    var filled = true
    var height: CGFloat = 22
    @ViewBuilder let content: () -> Content
    var body: some View {
        let radius = height >= 26 ? Radius.control - 1 : Radius.chip
        HStack(spacing: 5) { content() }
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, height >= 26 ? 9 : 7).frame(height: height)
            .background(filled ? tint.opacity(0.12) : Color.white.opacity(0.045),
                        in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(filled ? tint.opacity(0.24) : Color.white.opacity(0.1)))
    }
}
