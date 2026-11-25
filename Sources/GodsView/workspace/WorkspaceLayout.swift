import SwiftUI

/// Both sides of the split place their controls and hairlines in the same rows.
enum WorkspaceHeaderRow: CGFloat {
    case context = 46
    case navigation = 42
    case controls = 40
}

struct WorkspaceRule: View {
    var vertical = false
    @Environment(\.displayScale) private var scale

    var body: some View {
        Rectangle().fill(Color(white: 0.16))
            .frame(width: vertical ? 1 / scale : nil, height: vertical ? nil : 1 / scale)
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

extension View {
    func headerRow(_ row: WorkspaceHeaderRow, rule: Bool = true) -> some View {
        frame(height: row.rawValue)
            .overlay(alignment: .bottom) { if rule { WorkspaceRule() } }
    }
}
