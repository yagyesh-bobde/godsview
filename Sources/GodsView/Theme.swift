import SwiftUI
import GitHubCore

enum Ink {
    static let rail = Color(red: 0.079, green: 0.084, blue: 0.094)
    static let list = Color(red: 0.105, green: 0.111, blue: 0.122)
    static let detail = Color(red: 0.121, green: 0.128, blue: 0.14)
    static let surface = Color.white.opacity(0.047)
    static let line = Color.white.opacity(0.09)
    static let text = Color(white: 0.94)
    static let dim = Color(white: 0.66)
    static let faint = Color(white: 0.55)
    static let amber = Color(red: 0.99, green: 0.71, blue: 0.40)
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

struct BrandMark: View {
    var body: some View {
        Image(systemName: "eye.fill").font(.system(size: 18, weight: .semibold))
            .foregroundStyle(Ink.rail).frame(width: 30, height: 30)
            .background(LinearGradient(colors: [Color(red: 1, green: 0.83, blue: 0.53), Ink.amber],
                                       startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct Avatar: View {
    let login: String
    var size: CGFloat = 22
    private var tint: Color {
        let colors = [Ink.amber, Ink.purple, Ink.green, Color.cyan, Color.pink]
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
