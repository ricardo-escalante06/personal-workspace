import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// Milestone 0 shell: sidebar tree, a simple scoped task list, account + sync.
/// The real dashboard arrives in Milestone 1.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showTokens = false

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            if showTokens {
                TokenGallery()
            } else {
                ScopeTaskList(scope: model.selectedScope)
            }
        }
        .toolbar {
            ToolbarItem {
                Toggle(isOn: $showTokens) { Label("Tokens", systemImage: "swatchpalette") }
                    .help("Show design tokens")
            }
            ToolbarItem { SyncStatusView() }
        }
        .alert("Something went wrong", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            Label("All Workspace", systemImage: "square.grid.2x2")
                .tag(SidebarItem.allWorkspace)

            Section("Workspace") {
                if model.tree.isEmpty {
                    Button("Load sample data") { model.loadSampleData() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(WSColor.action)
                }
                OutlineGroup(model.tree, children: \.childrenOrNil) { node in
                    SidebarRow(container: node.container)
                        .tag(SidebarItem.container(node.id))
                        .contextMenu { ContainerMenu(parent: node.container) }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { AccountFooter() }
        .contextMenu { ContainerMenu(parent: nil) }
    }
}

private struct SidebarRow: View {
    let container: Container

    var body: some View {
        Label {
            Text(container.name).lineLimit(1)
        } icon: {
            Image(systemName: container.kind.symbol)
                .foregroundStyle(ContainerColor(named: container.color).accent)
        }
    }
}

private struct ContainerMenu: View {
    @Environment(AppModel.self) private var model
    let parent: Container?

    var body: some View {
        let kinds = ContainerKind.allCases.filter { parent?.kind.canContain($0) ?? true }
        ForEach(kinds, id: \.self) { kind in
            Button("New \(kind.displayName)") { model.createContainer(kind, under: parent?.id) }
        }
        if let parent {
            Divider()
            Button("Delete \(parent.name)", role: .destructive) { model.delete(parent.id) }
        }
    }
}

// MARK: - Scoped task list (placeholder for the Milestone 1 dashboard)

private struct ScopeTaskList: View {
    @Environment(AppModel.self) private var model
    let scope: UUID?
    @State private var tasks: [TaskItem] = []

    var body: some View {
        let crumbs = scope.map { ContainerTree.breadcrumb(for: $0, in: model.containers) } ?? []
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: WSSpace.xs) {
                Text(crumbs.dropLast().map(\.name).joined(separator: " › "))
                    .font(WSFont.metric)
                    .foregroundStyle(WSColor.textSecondary)
                Text(crumbs.last?.name ?? "All Workspace")
                    .font(WSFont.pageTitle)
                    .foregroundStyle(WSColor.textPrimary)
                Text("\(tasks.filter { $0.status != .done }.count) open · \(tasks.filter { $0.status == .done }.count) done")
                    .font(WSFont.metric)
                    .foregroundStyle(WSColor.textSecondary)
            }
            .padding(WSSpace.xl)

            List(tasks) { task in
                HStack(spacing: WSSpace.s) {
                    Button { model.toggleDone(task) } label: {
                        Image(systemName: task.status == .done ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(color(for: task).accent)
                    }
                    .buttonStyle(.plain)
                    Text(task.title)
                        .font(WSFont.rowTitle)
                        .strikethrough(task.status == .done)
                        .foregroundStyle(task.status == .done ? WSColor.textTertiary : WSColor.textPrimary)
                    Spacer()
                    if let due = task.dueDate {
                        Text(due.description + (task.dueTime.map { " \($0.description.prefix(5))" } ?? ""))
                            .font(WSFont.metric)
                            .foregroundStyle(WSColor.textSecondary)
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
        .background(WSColor.canvas)
        .task(id: scope) {
            let observation = ValueObservation.tracking { db in
                try ScopeQuery.tasks(in: scope).fetchAll(db)
            }
            do {
                for try await value in observation.values(in: model.store.db) { tasks = value }
            } catch {}
        }
    }

    private func color(for task: TaskItem) -> ContainerColor {
        ContainerColor(named: model.container(task.containerId)?.color ?? "grey")
    }
}
