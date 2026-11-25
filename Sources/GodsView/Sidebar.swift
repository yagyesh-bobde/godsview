import SwiftUI
import GitHubCore

struct Sidebar: View {
    @Bindable var store: Workspace
    @Binding var showAccounts: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark()
                Text("GodsView").font(.system(size: 19, weight: .semibold)).tracking(-0.7)
            }.padding(.horizontal, 18).padding(.vertical, 21)
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    SectionCaption("Workspace").padding(.leading, 9).padding(.top, 10).padding(.bottom, 7)
                    ForEach(Queue.allCases, id: \.self) { queue in
                        let selected = store.queue == queue
                        Button {
                            store.queue = queue
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: queue.symbol).frame(width: 17)
                                Text(queue.title)
                                Spacer()
                                Text("\(store.scoped.filter { store.includes($0, in: queue) }.count)")
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                            }
                            .foregroundStyle(selected ? Ink.amber : Ink.dim)
                            .padding(.horizontal, 9).frame(height: 31)
                            .background(selected ? Ink.amber.opacity(0.11) : .clear, in: RoundedRectangle(cornerRadius: 6))
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    Divider().padding(.vertical, 15)
                    HStack {
                        SectionCaption("Accounts")
                        Spacer()
                        Button { showAccounts = true } label: { Image(systemName: "plus") }
                            .buttonStyle(.plain).foregroundStyle(Ink.dim).help("Connect a GitHub account")
                    }.padding(.horizontal, 9).padding(.bottom, 7)
                    accountRow(nil)
                    ForEach(store.accounts) { account in accountRow(account.login) }
                }.padding(.horizontal, 10)
            }
            Divider()
            Button { showAccounts = true } label: {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                    Text("GitHub CLI")
                    Spacer()
                    Circle().fill(store.issues.isEmpty && !store.accounts.isEmpty ? Ink.green : Ink.amber)
                        .frame(width: 6, height: 6)
                }.foregroundStyle(Ink.dim).padding(16).contentShape(Rectangle())
            }.buttonStyle(.plain).help("View GitHub CLI accounts and connection status")
        }.font(.system(size: 12, weight: .medium)).frame(width: 202).background(Ink.rail)
    }

    private func accountRow(_ login: String?) -> some View {
        Button { store.scope = login } label: {
            HStack(spacing: 9) {
                if let login { Avatar(login: login, size: 19) }
                else { Image(systemName: "person.2").frame(width: 19) }
                Text(login ?? "All accounts").lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 3)
                if store.scope == login { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(Ink.amber) }
            }.foregroundStyle(store.scope == login ? Ink.text : Ink.dim)
                .padding(.horizontal, 9).frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
