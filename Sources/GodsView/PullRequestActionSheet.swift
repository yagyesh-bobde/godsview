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
        HStack(spacing: 6) {
            decisionButton("Close", symbol: "xmark.circle", tint: Ink.red, disabled: !item.pr.isOpen) {
                review.sheet = .close
            }
            decisionButton("Merge", symbol: "arrow.triangle.merge", tint: Ink.green, disabled: item.pr.isDraft || !item.pr.isOpen) {
                review.sheet = .merge
            }
        }.fixedSize()
    }

    private func decisionButton(_ title: String, symbol: String, tint: Color, disabled: Bool,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 8).frame(height: 23)
                .foregroundStyle(tint)
                .background(tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.4)))
        }.buttonStyle(.plain).disabled(disabled).opacity(disabled ? 0.45 : 1)
            .help(title + " pull request…").accessibilityLabel(title + " pull request")
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
                Picker("Method", selection: $method) {
                    ForEach(MergeMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                }.disabled(submitting)
                Text("Into " + item.pr.baseRefName).font(.caption.monospaced())
            }
            if let error { Text(error).font(.callout).foregroundStyle(Ink.red).textSelection(.enabled) }
            HStack {
                Avatar(login: item.account)
                Text(item.account).font(.caption)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(submitting)
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
            }
        }.padding(22).frame(width: 440).background(Ink.detail)
            .preferredColorScheme(.dark).interactiveDismissDisabled(submitting)
    }
}
