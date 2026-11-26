import SwiftUI

/// The pane content stays at its reading width while its visible frame closes.
struct WorkspacePane<Content: View>: View {
    let store: Workspace
    let visible: Bool
    let trailing: Bool
    @ViewBuilder let content: () -> Content
    @State private var initialDragWidth: CGFloat?

    var body: some View {
        // Like T3 Code's default, panels open and close instantly. Animating the width re-laid
        // out the whole window and the diff on every frame, and the content popped in mid-slide.
        // The content stays mounted at its reading width, so it reopens with its scroll position.
        let width = store.sidebarWidth
        content().frame(width: width).frame(maxHeight: .infinity)
            .background(Ink.rail)
            .overlay(alignment: trailing ? .leading : .trailing) { divider }
            .frame(width: visible ? width : 0, alignment: trailing ? .leading : .trailing)
            .clipped().allowsHitTesting(visible).accessibilityHidden(!visible)
            .transaction { $0.animation = nil }
    }

    private var divider: some View {
        Color.clear
            .frame(width: 8)
            .overlay(alignment: trailing ? .leading : .trailing) { WorkspaceRule(vertical: true) }
            .contentShape(Rectangle())
            .onHover { over in if over { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { drag in
                    let start = initialDragWidth ?? store.sidebarWidth
                    initialDragWidth = start
                    store.resizeSidebars(to: start + drag.translation.width * (trailing ? -1 : 1))
                }
                .onEnded { _ in initialDragWidth = nil })
            .accessibilityElement().accessibilityHidden(false).accessibilityLabel("Sidebar width")
            .accessibilityValue("\(Int(store.sidebarWidth)) points")
            .accessibilityAdjustableAction { change in
                store.resizeSidebars(to: store.sidebarWidth + (change == .increment ? 16 : -16))
            }
    }
}
