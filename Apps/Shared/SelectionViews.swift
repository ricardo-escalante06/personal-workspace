import SwiftUI
import WorkspaceKit
import WorkspaceUI

extension View {
    /// Click to select (⌘-click adds, ⇧-click selects a range of `order`), double-click
    /// for details, right-click menu, and drag (to the sidebar, week strip, calendar…).
    func taskInteractions(_ task: TaskItem, order: [UUID] = [], draggable: Bool = true) -> some View {
        modifier(TaskInteractions(task: task, order: order, isDraggable: draggable))
    }
}

private struct TaskInteractions: ViewModifier {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    let order: [UUID]
    let isDraggable: Bool

    func body(content: Content) -> some View {
        let base = content
            .onTapGesture(count: 2) { model.openDetails(task.id) }
            .simultaneousGesture(TapGesture().onEnded { model.click(task.id, in: order) })
            .contextMenu { TaskContextMenu(task: task) }
        if isDraggable {
            base.draggable("due-\(task.id.uuidString)") { DragPreview(task: task) }
        } else {
            base
        }
    }
}

/// "HW 4" (or "HW 4 + 2 more") under the pointer while dragging.
private struct DragPreview: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    var body: some View {
        let extra = model.targets(for: task.id).count - 1
        Text(extra > 0 ? "\(task.title)  +\(extra) more" : task.title)
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(WSColor.raised))
    }
}

/// Right-click on a task. When it's part of a multi-selection, every item acts on
/// all selected tasks.
struct TaskContextMenu: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    var body: some View {
        let ids = model.targets(for: task.id)
        if ids.count > 1 {
            BulkTaskMenu(ids: ids)
        } else {
            Button(task.status == .done ? "Mark Not Done" : "Mark Done") { model.toggleDone(task) }
            Button("Open Details") { model.openDetails(task.id) }
            TaskEditMenus(ids: [task.id])
            Button(task.isStarred ? "Unstar" : "Star") { model.toggleStar(task) }
            if task.isOccurrence {
                Divider()
                Button("Skip This One") { model.deleteTask(task.id) }
                Button("Stop Repeating") { model.setRepeat(task, nil) }
                Button("Delete Repeating Task", role: .destructive) { if let s = task.occurrenceOf { model.deleteTask(s) } }
            } else {
                Divider()
                Button("Delete", role: .destructive) { model.deleteTask(task.id) }
            }
        }
    }
}

/// The menu for several tasks at once (right-click on a selection, or the bar's "…").
struct BulkTaskMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [UUID]

    var body: some View {
        Button("Mark \(ids.count) Done") { model.setDone(ids, true) }
        Button("Mark \(ids.count) Not Done") { model.setDone(ids, false) }
        TaskEditMenus(ids: ids)
        Menu("Star") {
            Button("Star All") { model.editTasks(ids, "Star") { $0.isStarred = true } }
            Button("Unstar All") { model.editTasks(ids, "Unstar") { $0.isStarred = false } }
        }
        Divider()
        Button("Delete \(ids.count) Tasks", role: .destructive) { model.deleteTasks(ids) }
    }
}

/// Due / Move to / Tag / Priority: shared by the single and multi-task menus.
struct TaskEditMenus: View {
    @Environment(AppModel.self) private var model
    let ids: [UUID]

    var body: some View {
        let today = LocalDate(Date())
        Menu("Due") {
            Button("Today") { model.editTasks(ids, "Change Due Date") { $0.dueDate = today } }
            Button("Tomorrow") { model.editTasks(ids, "Change Due Date") { $0.dueDate = today.adding(days: 1) } }
            Button("Next Week") { model.editTasks(ids, "Change Due Date") { $0.dueDate = today.adding(days: 7) } }
            Divider()
            Button("Push 1 Day Later") { model.editTasks(ids, "Change Due Date") { $0.dueDate = $0.dueDate?.adding(days: 1) } }
            Button("Push 1 Week Later") { model.editTasks(ids, "Change Due Date") { $0.dueDate = $0.dueDate?.adding(days: 7) } }
            Divider()
            Button("No Due Date") { model.editTasks(ids, "Clear Due Date") { $0.dueDate = nil } }
        }
        Menu("Move to") {
            Button("Inbox") { model.editTasks(ids, "Move to Inbox") { $0.containerId = nil } }
            Divider()
            ForEach(model.taskHolders.filter { $0.archivedAt == nil }) { c in
                Button(model.locationLabels[c.id] ?? c.name) {
                    model.editTasks(ids, "Move to \(c.name)") { $0.containerId = c.id }
                }
            }
        }
        Menu("Tag") {
            Button("None") { model.editTasks(ids, "Change Tag") { $0.categoryId = nil } }
            Divider()
            ForEach(model.categories) { c in
                Button(c.name) { model.editTasks(ids, "Change Tag") { $0.categoryId = c.id } }
            }
        }
        Menu("Priority") {
            ForEach([(3, "High"), (2, "Medium"), (1, "Low"), (0, "None")], id: \.0) { value, name in
                Button(name) { model.editTasks(ids, "Change Priority") { $0.priority = value == 0 ? nil : value } }
            }
        }
    }
}

/// Floating bar while two or more tasks are selected.
struct SelectionBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let ids = Array(model.selectedTaskIds)
        if ids.count > 1 {
            HStack(spacing: WSSpace.m) {
                Text("\(ids.count) selected")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(WSColor.textPrimary)
                Divider().frame(height: 16)
                Button { model.setDone(ids, true) } label: { Label("Done", systemImage: "checkmark.circle") }
                Menu { TaskEditMenus(ids: ids) } label: { Label("Edit", systemImage: "slider.horizontal.3") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                Button { model.deleteTasks(ids) } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete (⌫)")
                Divider().frame(height: 16)
                Button { model.clearSelection() } label: { Image(systemName: "xmark") }
                    .help("Clear selection (Esc)")
            }
            .buttonStyle(.plain)
            .font(.system(size: 12.5))
            .foregroundStyle(WSColor.textSecondary)
            .padding(.horizontal, WSSpace.l).padding(.vertical, WSSpace.s + 2)
            .background(RoundedRectangle(cornerRadius: WSRadius.popover).fill(WSColor.raised))
            .overlay(RoundedRectangle(cornerRadius: WSRadius.popover).strokeBorder(WSColor.hairline))
            .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
            .padding(.bottom, WSSpace.xl)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}
