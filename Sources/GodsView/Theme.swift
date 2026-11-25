import SwiftUI
import GitHubCore

enum Ink {
    static let rail = Color(white: 0.105)
    static let detail = Color(white: 0.078)
    static let surface = Color.white.opacity(0.047)
    static let line = Color.white.opacity(0.09)
    static let text = Color(white: 0.94)
    static let dim = Color(white: 0.66)
    static let faint = Color(white: 0.55)
    static let blue = Color(red: 0.47, green: 0.66, blue: 0.98)
    static let selection = Color.white.opacity(0.085)
    static let red = Color(red: 0.96, green: 0.48, blue: 0.49)
    static let green = Color(red: 0.46, green: 0.82, blue: 0.62)
    static let purple = Color(red: 0.74, green: 0.66, blue: 0.96)
}

extension Queue {
    var symbol: String {
        switch self {
        case .inbox: "tray.2"
        case .reviews: "text.bubble"
        case .authored: "pencil.line"
        case .assigned: "person.crop.circle.badge.checkmark"
        case .saved: "bookmark"
        }
    }
}

struct SectionCaption: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.3).foregroundStyle(Ink.faint)
    }
}

struct Avatar: View {
    let login: String
    var size: CGFloat = 22
    private var tint: Color {
        let colors = [Ink.blue, Ink.purple, Ink.green, Color.cyan, Color.pink]
        return colors[login.utf8.reduce(0) { ($0 + Int($1)) % colors.count }]
    }
    var body: some View {
        Text(String(login.prefix(1)).uppercased()).font(.system(size: size * 0.49, weight: .bold, design: .rounded))
            .frame(width: size, height: size).foregroundStyle(tint)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28))
            .accessibilityHidden(true)
    }
}

struct StatePill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.system(size: 10, weight: .medium)).foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 3).background(color.opacity(0.11), in: Capsule())
    }
}
