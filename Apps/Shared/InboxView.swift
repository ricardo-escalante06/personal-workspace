import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// Tasks that don't belong to any list yet: quick adds from All Workspace or the
/// palette with no class/list named. File them with drag-to-sidebar or "Move to".
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @State private var tasks: [TaskItem] = []
    @State private var showCompleted = false

    private var today: LocalDate { LocalDate(Date()) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WSSpace.l) {
                HStack(alignment: .center, spacing: WSSpace.s + 2) {
                    Image(systemName: "tray")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(WSColor.textSecondary)
                    Text("Inbox")
                        .font(WSFont.pageTitle)
                        .foregroundStyle(WSColor.textPrimary)
                    Spacer()
                    Button {
                        model.quickAdd = QuickAddRequest()
                    } label: {
                        Label("New Task", systemImage: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .padding(.horizontal, WSSpace.m).padding(.vertical, 5)
                            .background(WSColor.action, in: RoundedRectangle(cornerRadius: 6))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                Text("Tasks that aren't in a list, class or project yet. Drag one onto the sidebar, or right-click › Move to.")
                    .font(WSFont.metric)
                    .foregroundStyle(WSColor.textSecondary)

                let visible = tasks.filter { showCompleted || $0.status != .done }
                if visible.isEmpty {
                    Text("Inbox zero.")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(WSColor.textTertiary)
                        .padding(.top, WSSpace.l)
                }
                VStack(spacing: 0) {
                    ForEach(visible) { task in
                        TaskRowView(
                            task: task,
                            context: .init(
                                color: .grey,
                                tag: model.tagStyle(task.categoryId),
                                isStarred: model.isStarred(task),
                                dueText: WSFormat.due(task, today: today),
                                isOverdue: task.dueDate.map { $0 < today } ?? false
                            ),
                            isSelected: model.isSelected(task.id),
                            onToggle: { model.toggleDone(task) }
                        )
                        .taskInteractions(task, order: visible.map(\.id))
                    }
                }
                Toggle("Show completed", isOn: $showCompleted)
                    .checkboxToggleStyle()
                    .font(.system(size: 12))
                    .foregroundStyle(WSColor.textSecondary)
            }
            .padding(.horizontal, WSSpace.xxl)
            .padding(.vertical, WSSpace.xl)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WSColor.canvas)
        .task {
            let observation = ValueObservation.tracking { db in
                try TaskItem.live()
                    .filter(Column("container_id") == nil)
                    .filter(Column("parent_task_id") == nil)
                    .order(Column("sort_rank"))
                    .fetchAll(db)
            }
            do {
                for try await value in observation.values(in: model.store.db) { tasks = value }
            } catch {}
        }
    }
}
