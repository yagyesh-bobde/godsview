import SwiftUI
import GitHubCore

enum PullRequestAction: String, Identifiable {
    case close = "Close", merge = "Merge"
    var id: Self { self }
}

struct ReviewDecisionButtons: View {
    let item: InboxItem
    let review: ReviewSession

    var body: some View {
        HStack(spacing: 8) {
            // Closing is the rarer, destructive action: quiet outline, red label.
            Button { review.sheet = .close } label: {
                Label { Text("Close PR…") } icon: { Image(systemName: "xmark.circle").foregroundStyle(Ink.red) }
            }
            .buttonStyle(ActionButtonStyle(kind: .quietDestructive(Ink.red), height: ControlSize.large))
            .disabled(!item.pr.isOpen)
            .help("Close this pull request without merging…").accessibilityLabel("Close pull request")
            // Merge is the strongest signal only once the PR is approved (or needs no review).
            let ready = item.pr.reviewDecision == nil || item.pr.reviewDecision == "APPROVED"
            // Solid green only once the PR is approved; a soft green while review is pending.
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
