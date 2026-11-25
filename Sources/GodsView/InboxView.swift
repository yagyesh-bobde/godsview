import SwiftUI

struct InboxView: View {
    @Bindable var store: Workspace
    @Binding var showAccounts: Bool
    let controls: WindowControls

    var body: some View {
        HSplitView {
            if store.sidebarVisible && !store.focusingFile {
                Sidebar(store: store, showAccounts: $showAccounts)
                    .frame(minWidth: 195, idealWidth: 245, maxWidth: 265, maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { store.sidebarWidth = $0 }
                    .clipped()
                    .overlay(alignment: .trailing) { WorkspaceRule(vertical: true) }
            }
            if let item = store.selected {
                DetailView(item: item, store: store) { controls.toggleFileFocus(store) }
                    .id(item.id).frame(minWidth: 490, maxWidth: .infinity, maxHeight: .infinity).clipped()
            } else {
                VStack(spacing: 12) {
                    if !store.hasCheckedInbox || (store.items.isEmpty && store.refreshing && store.lastRefresh == nil) { ProgressView("Syncing with GitHub…").controlSize(.small) }
                    else {
                        Image(systemName: "tray").font(.largeTitle).foregroundStyle(Ink.faint)
                        Text(!store.issues.isEmpty && store.items.isEmpty ? "Couldn’t sync the inbox" : store.accounts.isEmpty ? "Connect a GitHub account" : "No pull requests in this view").font(.headline)
                        if store.accounts.isEmpty || !store.issues.isEmpty {
                            Button("GitHub account settings") { showAccounts = true }
                        } else {
                            Button("Search workspace") { store.palette = .global }
                        }
                        if !store.sidebarVisible { Button("Show sidebar") { store.sidebarVisible = true } }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Ink.detail)
            }
        }
        .overlay(alignment: .top) { WorkspaceRule() }
        .onChange(of: store.displayedIDs, initial: true) { _, ids in
            if !ids.contains(store.selection ?? "") { store.selection = ids.first }
        }
    }
}
