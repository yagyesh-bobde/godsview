import SwiftUI

/// Shared timing for workspace transitions. Animations are attached to state values
/// (not to the buttons or shortcuts that change them), so the mouse, the keyboard and
/// scroll-driven changes all animate the same way. With Reduce Motion on, nothing moves.
enum Motion {
    /// Layout changes such as rows folding away. `nil` means "change instantly".
    static func layout(_ reduce: Bool) -> Animation? {
        reduce ? nil : .smooth(duration: 0.22)
    }

    /// Content swaps that keep their frame, such as switching what a pane shows.
    static func swap(_ reduce: Bool) -> Animation? {
        reduce ? nil : .easeInOut(duration: 0.16)
    }

    /// Header rows slide up under the toolbar and fade, so neighbours stay aligned.
    static func header(_ reduce: Bool) -> AnyTransition {
        reduce ? .identity : .move(edge: .top).combined(with: .opacity)
    }
}

extension View {
    /// Fades (and, without Reduce Motion, slightly slides) a pane in when it appears.
    /// It only touches opacity and offset, which never change layout, so it is safe inside
    /// split views whose pane widths the user drags and other views read back.
    func revealOnAppear(from edge: Edge? = nil) -> some View {
        modifier(RevealOnAppear(edge: edge))
    }


}

private struct RevealOnAppear: ViewModifier {
    let edge: Edge?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        let distance: CGFloat = shown || reduceMotion ? 0 : 10
        content
            .opacity(shown || reduceMotion ? 1 : 0)
            .offset(x: edge == .leading ? -distance : (edge == .trailing ? distance : 0))
            .onAppear {
                guard !shown else { return }
                if reduceMotion { shown = true } else { withAnimation(.easeOut(duration: 0.18)) { shown = true } }
            }
    }
}

extension View {
    /// Folds a header to zero height without removing it, so unfolding is only a layout
    /// change and never rebuilds its views. The rows slide up under the toolbar as they fold.
    func foldAway(_ folded: Bool) -> some View {
        fixedSize(horizontal: false, vertical: true)
            .frame(height: folded ? 0 : nil, alignment: .bottom)
            .clipped()
            .opacity(folded ? 0 : 1)
            .allowsHitTesting(!folded)
            .accessibilityHidden(folded)
    }
}

/// Moves the PR header and diff controls up as the diff scrolls, like a page header. It is the
/// only view that reads the scroll distance, so following the scroll never rebuilds the review.
struct ReviewHeaderScroll: ViewModifier {
    let review: ReviewSession
    var enabled = true

    func body(content: Content) -> some View {
        content.offset(y: enabled ? -review.headerScroll : 0)
    }
}
