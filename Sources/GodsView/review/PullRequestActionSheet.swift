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
            // Closing is the rarer, destructive action: neutral body, red icon.
            Button { review.sheet = .close } label: {
                Label { Text("Close") } icon: { Image(systemName: "xmark.circle").foregroundStyle(Ink.red) }
            }
            .buttonStyle(ActionButtonStyle(kind: .secondary, height: ControlSize.large))
            .disabled(!item.pr.isOpen)
            .help("Close this pull request without merging…").accessibilityLabel("Close pull request")
            Button { review.sheet = .merge } label: { Label("Merge", systemImage: "arrow.triangle.merge") }
                .buttonStyle(ActionButtonStyle(kind: .primary(Ink.green), height: ControlSize.large))
                .disabled(item.pr.isDraft || !item.pr.isOpen)
                .help(item.pr.isDraft ? "Draft pull requests can’t be merged" : "Merge this pull request…")
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
