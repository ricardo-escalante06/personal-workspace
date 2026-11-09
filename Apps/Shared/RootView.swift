import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// Main window: sidebar tree · scoped dashboard · task inspector.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 250)
        } detail: {
            DashboardView(scope: model.selectedScope, store: model.store, weekStart: model.weekStart)
                .id(model.selectedScope)
                .inspector(isPresented: $model.showInspector) {
                    Group {
                        if let id = model.selectedTaskId {
                            TaskInspector(taskId: id)
                        } else {
                            ContentUnavailableView("Select a task", systemImage: "sidebar.right",
                                                   description: Text("Click any task to see its details."))
                        }
                    }
                    .inspectorColumnWidth(min: 300, ideal: 340, max: 460)
                }
        }
        .toolbar {
            ToolbarItem { SyncStatusView() }
            ToolbarItem {
                Button { model.toggleInspector() } label: {
                    Label("Details", systemImage: "sidebar.right")
                }
                .help("Show details (⌘I)")
            }
        }
        .sheet(item: $model.quickAdd) { request in
            QuickAddView(request: request, scope: model.selectedScope)
        }
        .sheet(isPresented: $model.showPalette) {
            CommandPalette()
        }
        .overlay(alignment: .bottom) { ToastView() }
        .animation(.smooth(duration: 0.25), value: model.toast?.id)
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, manager in model.undoManager = manager }
        .background {
            // Esc hides the details panel (zero-size button so the shortcut stays active).
            Button("") { model.setInspector(visible: false) }
                .keyboardShortcut(.escape, modifiers: [])
                .disabled(!model.showInspector)
                .opacity(0)
                .frame(width: 0, height: 0)
        }
        .alert("Something went wrong", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .sheet(item: $model.containerEditor) { request in
            ContainerEditorSheet(request: request)
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
                .dropDestination(for: String.self) { ids, _ in
                    moveToTop(ids)
                }

            Section("Workspace") {
                if model.tree.isEmpty {
                    Button("Load sample data") { model.loadSampleData() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(WSColor.action)
                }
                OutlineGroup(model.tree, children: \.childrenOrNil) { node in
                    SidebarRow(container: node.container)
                        .tag(SidebarItem.container(node.id))
                        .contextMenu { ContainerMenu(container: node.container) }
                        .draggable("container-\(node.id.uuidString)")
                        .dropDestination(for: String.self) { ids, _ in
                            drop(ids, onto: node.container)
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { AccountFooter() }
        .contextMenu { NewContainerMenu(parent: nil) }
    }

    private func containerId(from payload: String) -> UUID? {
        guard payload.hasPrefix("container-") else { return nil }
        return UUID(uuidString: String(payload.dropFirst("container-".count)))
    }

    private func drop(_ payloads: [String], onto target: Container) -> Bool {
        guard let payload = payloads.first else { return false }
        if let id = containerId(from: payload) {
            return model.dropContainer(id, onto: target.id)
        }
        // A task dragged from the dashboard onto a list/class/project moves it there.
        if payload.hasPrefix("due-"), let taskId = UUID(uuidString: String(payload.dropFirst(4))), target.kind.holdsTasks {
            model.editTask(taskId) { $0.containerId = target.id }
            return true
        }
        return false
    }

    private func moveToTop(_ payloads: [String]) -> Bool {
        guard let id = payloads.first.flatMap(containerId(from:)) else { return false }
        return model.dropContainer(id, onto: nil)
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

private struct NewContainerMenu: View {
    @Environment(AppModel.self) private var model
    let parent: Container?

    var body: some View {
        let kinds = ContainerKind.allCases.filter { parent?.kind.canContain($0) ?? true }
        ForEach(kinds, id: \.self) { kind in
            Button("New \(kind.displayName)") { model.createContainer(kind, under: parent?.id) }
        }
    }
}

private struct ContainerMenu: View {
    @Environment(AppModel.self) private var model
    let container: Container

    var body: some View {
        NewContainerMenu(parent: container)
        Divider()
        Button("Edit…") { model.editContainer(container) }
        Menu("Color") {
            ForEach(ContainerColor.allCases) { color in
                Button {
                    model.setColor(container.id, color.rawValue)
                } label: {
                    Label {
                        Text(color.displayName + (container.color == color.rawValue ? "  ✓" : ""))
                    } icon: {
                        ColorSwatchImage.image(for: color)
                    }
                }
            }
        }
        if container.parentId != nil {
            Button("Move to Top Level") { _ = model.dropContainer(container.id, onto: nil) }
        }
        Divider()
        Button("Delete \(container.name)", role: .destructive) { model.delete(container.id) }
    }
}

// MARK: - Toast

private struct ToastView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let toast = model.toast {
            HStack(spacing: WSSpace.m) {
                Text(toast.message)
                    .foregroundStyle(WSColor.textPrimary)
                    .lineLimit(1)
                Button("Undo") { model.undoToast() }
                    .buttonStyle(.plain)
                    .fontWeight(.semibold)
                    .foregroundStyle(WSColor.action)
            }
            .font(.system(size: 13))
            .padding(.horizontal, WSSpace.l).padding(.vertical, WSSpace.s + 2)
            .background(RoundedRectangle(cornerRadius: WSRadius.popover).fill(WSColor.raised))
            .overlay(RoundedRectangle(cornerRadius: WSRadius.popover).strokeBorder(WSColor.hairline))
            .padding(.bottom, WSSpace.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .id(toast.id)
        }
    }
}
