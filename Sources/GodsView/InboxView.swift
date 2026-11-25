import SwiftUI

struct InboxView: View {
    @Bindable var store: Workspace
    @Binding var showAccounts: Bool
    let controls: WindowControls

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var retainSidebar = false

    var body: some View {
        GeometryReader { viewport in split(width: viewport.size.width) }
    }

    private func split(width: CGFloat) -> some View {
        let showSidebar = store.sidebarVisible && !store.focusingFile
        return HSplitView {
            if showSidebar || (retainSidebar && !reduceMotion && !store.focusingFile) {
                Sidebar(store: store, showAccounts: $showAccounts)
                    .revealOnAppear(from: .leading)
                    .opacity(showSidebar ? 1 : 0)
                    .animation(Motion.swap(reduceMotion), value: showSidebar)
                    .allowsHitTesting(showSidebar)
                    .accessibilityHidden(!showSidebar)
                    .frame(minWidth: min(300, max(195, width * 0.16)),
                           idealWidth: min(370, max(245, width * 0.20)),
                           maxWidth: max(265, min(620, width * 0.38)), maxHeight: .infinity)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { store.sidebarWidth = $0 }
                    .clipped()
                    .overlay(alignment: .trailing) { WorkspaceRule(vertical: true) }
            }
            if let item = store.selected {
                DetailView(item: item, store: store) { controls.toggleFileFocus(store) }
                    .revealOnAppear().id(item.id).frame(minWidth: 490, maxWidth: .infinity, maxHeight: .infinity).clipped()
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
        .trackPaneVisibility(showSidebar, retained: $retainSidebar, reduceMotion: reduceMotion)
        .overlay(alignment: .top) { WorkspaceRule() }
        .onChange(of: store.displayedIDs, initial: true) { _, ids in
            if !ids.contains(store.selection ?? "") { store.selection = ids.first }
        }
    }
}
