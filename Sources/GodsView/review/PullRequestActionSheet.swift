import SwiftUI
import GitHubCore

enum PullRequestAction: String, Identifiable {
    case close = "Close", merge = "Merge"
    var id: Self { self }
}

enum ReviewDecisionDisplay { case full, short, icon }

struct ReviewDecisionButtons: View {
    let item: InboxItem
    let review: ReviewSession
    /// Optional review badge, grouped directly beside Merge so its gate state reads with it.
    var decisionDisplay: ReviewDecisionDisplay? = nil

    private var decisionInfo: (full: String, short: String, color: Color, symbol: String)? {
        switch item.pr.reviewDecision {
        case "APPROVED": ("Approved", "Approved", Ink.green, "checkmark.circle.fill")
        case "CHANGES_REQUESTED": ("Changes requested", "Changes", Ink.red, "exclamationmark.circle.fill")
        case "REVIEW_REQUIRED": ("Review required", "Needs review", Ink.amber, "eye")
        default: nil
        }
    }

    var body: some View {
        let ready = item.pr.reviewDecision == nil || item.pr.reviewDecision == "APPROVED"
        let hasBadge = decisionDisplay != nil && decisionInfo != nil
        HStack(spacing: 6) {
            // Closing is the rarer, destructive action: quiet neutral outline at rest,
            // revealing its destructive red only on hover or press.
            Button { review.sheet = .close } label: {
                Label("Close PR…", systemImage: "xmark.circle")
            }
            .buttonStyle(ActionButtonStyle(kind: .quietDestructive(Ink.red), height: ControlSize.large))
            .disabled(!item.pr.isOpen)
            .help("Close this pull request without merging…").accessibilityLabel("Close pull request")

            if hasBadge {
                WorkspaceRule(vertical: true).frame(height: 16).padding(.horizontal, 1)
            }

            // Group the review status badge directly beside Merge so the gate condition
            // reads as one unit with the merge action.
            HStack(spacing: 6) {
                if let display = decisionDisplay, let info = decisionInfo {
                    MetaChip(tint: info.color, height: 26) {
                        Image(systemName: info.symbol).font(.system(size: 10.5, weight: .semibold))
                        switch display {
                        case .full: Text(info.full)
                        case .short: Text(info.short)
                        case .icon: EmptyView()
                        }
                    }.fixedSize().help(info.full).accessibilityLabel(info.full)
                }
                // Solid green only once the PR is approved (or needs no review); elevated neutral
                // with a green icon while review is pending so it still outranks Close PR.
                Button { review.sheet = .merge } label: {
                    if ready { Label("Merge…", systemImage: "arrow.triangle.merge") }
                    else { Label { Text("Merge…") } icon: { Image(systemName: "arrow.triangle.merge").foregroundStyle(Ink.green) } }
                }
                .buttonStyle(ActionButtonStyle(kind: ready ? .primary(Ink.green) : .secondary, height: ControlSize.large))
                .disabled(item.pr.isDraft || !item.pr.isOpen)
                .help(item.pr.isDraft ? "Draft pull requests can’t be merged"
                      : ready ? "Merge this pull request…"
                      : item.pr.reviewDecision == "CHANGES_REQUESTED" ? "Changes were requested. You can still review and confirm a merge…"
                      : "This pull request still needs an approving review. You can still confirm a merge…")
                .accessibilityLabel("Merge pull request")
            }
        }.fixedSize()
    }
}

struct PullRequestActionSheet: View {
    let action: PullRequestAction
    let item: InboxItem
    let store: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var method = MergeMethod.merge
    @State private var submitting = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("\(action.rawValue) pull request?").font(.title2.bold())
            Text("\(item.pr.repository.nameWithOwner) #\(item.pr.number)").font(.caption.monospaced()).foregroundStyle(Ink.dim)
            Text(item.pr.title).font(.headline)
            if action == .merge, let decision = item.pr.reviewDecision, decision != "APPROVED" {
                Label(decision == "CHANGES_REQUESTED" ? "Changes were requested on this pull request."
                      : "This pull request still needs an approving review.",
                      systemImage: decision == "CHANGES_REQUESTED" ? "exclamationmark.circle.fill" : "eye")
                    .font(.callout).foregroundStyle(decision == "CHANGES_REQUESTED" ? Ink.red : Ink.amber)
            }
            if action == .merge {
                DropdownField(title: "Method", value: method.title) {
                    MergeMethod.allCases.map { choice in
                        DropdownOption(choice.title, icon: "arrow.triangle.merge", selected: choice == method) { method = choice }
                    }
                }.disabled(submitting)
                Text("Into " + item.pr.baseRefName).font(.caption.monospaced())
            }
            if let error { Text(error).font(.callout).foregroundStyle(Ink.red).textSelection(.enabled) }
            HStack {
                Avatar(login: item.account)
                Text(item.account).font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
                    .buttonStyle(ActionButtonStyle(kind: .secondary, height: ControlSize.large))
                Button(submitting ? "Working…" : "\(action.rawValue) PR", role: action == .close ? .destructive : nil) {
                    submitting = true
                    error = nil
                    Task {
                        do {
                            switch action {
                            case .close: try await store.client.close(item)
                            case .merge: try await store.client.merge(item, method: method)
                            }
                            dismiss()
                            await store.removeClosed(item)
                        } catch {
                            self.error = error.localizedDescription
                            submitting = false
                        }
                    }
                }.disabled(submitting)
                    .buttonStyle(ActionButtonStyle(kind: action == .merge ? .primary(Ink.green) : .primary(Ink.red),
                                                   height: ControlSize.large))
            }
        }.padding(24).frame(width: 440).background(Ink.detail)
            .preferredColorScheme(.dark).interactiveDismissDisabled(submitting)
    }
}
