import SwiftUI

/// The pane content stays at its reading width while its visible frame slides closed.
struct WorkspacePane<Content: View>: View {
    let store: Workspace
    let visible: Bool
    let trailing: Bool
    @ViewBuilder let content: () -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var retained = false
    @State private var initialDragWidth: CGFloat?

    var body: some View {
        let width = store.sidebarWidth
        ZStack {
            if visible || retained {
                content().frame(width: width).frame(maxHeight: .infinity)
                    .background(Ink.rail)
                    .overlay(alignment: trailing ? .leading : .trailing) { divider }
            }
        }
        .frame(width: visible ? width : 0, alignment: trailing ? .leading : .trailing)
        .clipped().allowsHitTesting(visible).accessibilityHidden(!visible)
        .animation(Motion.layout(reduceMotion), value: visible)
        .task(id: visible) {
            if !visible && !reduceMotion {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
            retained = visible
        }
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
