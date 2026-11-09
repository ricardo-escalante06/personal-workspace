import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// Right-hand task details (DESIGN.md §11): title, status, category, container,
/// due date (separate from work blocks), work blocks, subtasks, notes.
/// Every change writes straight to the local store (and from there, syncs).
struct TaskInspector: View {
    @Environment(AppModel.self) private var model
    let taskId: UUID

    @State private var task: TaskItem?
    @State private var blocks: [ScheduleBlock] = []
    @State private var subtasks: [TaskItem] = []
    @State private var titleDraft = ""
    @State private var notesDraft = ""
    @State private var newSubtask = ""
    @FocusState private var titleFocused: Bool

    var body: some View {
        Group {
            if let task {
                form(task)
            } else {
                ContentUnavailableView("No task selected", systemImage: "checklist")
            }
        }
        .task(id: taskId) { await observe() }
    }

    private func observe() async {
        let id = taskId
        let observation = ValueObservation.tracking { db -> (TaskItem?, [ScheduleBlock], [TaskItem]) in
            let task = try TaskItem.live().filter(id: id).fetchOne(db)
            let blocks = try ScheduleBlock.live().filter(Column("task_id") == id).order(Column("starts_at")).fetchAll(db)
            let subtasks = try TaskItem.live().filter(Column("parent_task_id") == id).order(Column("sort_rank")).fetchAll(db)
            return (task, blocks, subtasks)
        }
        do {
            for try await (t, b, s) in observation.values(in: model.store.db) {
                // Don't clobber text the user is typing.
                if !titleFocused { titleDraft = t?.title ?? "" }
                if task?.id != t?.id { notesDraft = t?.notes ?? "" }
                task = t
                blocks = b
                subtasks = s
            }
        } catch {}
    }

    private func form(_ task: TaskItem) -> some View {
        let color = ContainerColor(named: model.color(for: task))
        return Form {
            Section {
                HStack(alignment: .firstTextBaseline, spacing: WSSpace.s) {
                    TaskCheckbox(isDone: task.status == .done, color: color) { model.toggleDone(task) }
                    TextField("Title", text: $titleDraft, axis: .vertical)
                        .font(.system(size: 15, weight: .semibold))
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .onSubmit(commitTitle)
                        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                }
            }

            Section {
                Picker("Status", selection: binding(\.status)) {
                    Text("Not started").tag(TaskStatus.notStarted)
                    Text("In progress").tag(TaskStatus.inProgress)
                    Text("Done").tag(TaskStatus.done)
                    Text("Cancelled").tag(TaskStatus.cancelled)
                }
                Picker("Category", selection: binding(\.categoryId)) {
                    Text("None").tag(UUID?.none)
                    ForEach(model.categories) { c in
                        Label(c.name, systemImage: c.symbol).tag(UUID?.some(c.id))
                    }
                }
                Picker("Priority", selection: binding(\.priority)) {
                    Text("None").tag(Int?.none)
                    Text("Low").tag(Int?.some(1))
                    Text("Medium").tag(Int?.some(2))
                    Text("High").tag(Int?.some(3))
                }
                Picker("Location", selection: binding(\.containerId)) {
                    Text("Inbox").tag(UUID?.none)
                    ForEach(taskHolders) { c in
                        Text(locationLabel(c)).tag(UUID?.some(c.id))
                    }
                }
            }

            Section("Deadline") {
                Toggle("Due date", isOn: Binding(
                    get: { task.dueDate != nil },
                    set: { on in model.editTask(task.id) { $0.dueDate = on ? LocalDate(Date()) : nil } }
                ))
                if let due = task.dueDate {
                    DatePicker("Date", selection: Binding(
                        get: { due.startOfDay(in: .current) },
                        set: { d in model.editTask(task.id) { $0.dueDate = LocalDate(d) } }
                    ), displayedComponents: .date)
                    Toggle("Specific time", isOn: Binding(
                        get: { task.dueTime != nil },
                        set: { on in model.editTask(task.id) { $0.dueTime = on ? LocalTime(hour: 23, minute: 59) : nil } }
                    ))
                    if let time = task.dueTime {
                        DatePicker("Time", selection: Binding(
                            get: { due.startOfDay(in: .current).addingTimeInterval(TimeInterval(time.secondsSinceMidnight)) },
                            set: { d in
                                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                                model.editTask(task.id) { $0.dueTime = LocalTime(hour: c.hour ?? 0, minute: c.minute ?? 0) }
                            }
                        ), displayedComponents: .hourAndMinute)
                    }
                }
            }

            Section {
                ForEach(blocks) { block in
                    BlockEditor(block: block)
                }
                Button {
                    model.addBlock(to: task)
                } label: {
                    Label("Add work block", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Work blocks")
            } footer: {
                Text("Planned time to work on this. Moving a block never changes the deadline.")
                    .font(.caption)
                    .foregroundStyle(WSColor.textTertiary)
            }

            Section("Subtasks") {
                ForEach(subtasks) { sub in
                    HStack(spacing: WSSpace.s) {
                        TaskCheckbox(isDone: sub.status == .done, color: color) { model.toggleDone(sub) }
                        Text(sub.title)
                            .strikethrough(sub.status == .done)
                            .foregroundStyle(sub.status == .done ? WSColor.textTertiary : WSColor.textPrimary)
                        Spacer()
                        Button { model.deleteTask(sub.id) } label: { Image(systemName: "xmark") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(WSColor.textTertiary)
                    }
                }
                TextField("Add subtask", text: $newSubtask)
                    .onSubmit {
                        let title = newSubtask.trimmingCharacters(in: .whitespaces)
                        guard !title.isEmpty else { return }
                        model.addSubtask(to: task, title: title)
                        newSubtask = ""
                    }
            }

            Section("Details") {
                LabeledContent("Estimate") {
                    TextField("minutes", value: binding(\.estimatedMinutes), format: .number)
                        .multilineTextAlignment(.trailing)
                }
                TextField("Link", text: Binding(
                    get: { task.sourceUrl ?? "" },
                    set: { v in model.editTask(task.id) { $0.sourceUrl = v.isEmpty ? nil : v } }
                ))
            }

            Section("Notes") {
                TextEditor(text: $notesDraft)
                    .font(WSFont.body)
                    .frame(minHeight: 90)
                    .onChange(of: notesDraft) { _, value in
                        guard value != task.notes else { return }
                        model.editTask(task.id) { $0.notes = value }
                    }
            }

            Section {
                Button("Delete Task", role: .destructive) { model.deleteTask(task.id) }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(WSColor.raised)
    }

    private func commitTitle() {
        guard let task, titleDraft != task.title,
              !titleDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let value = titleDraft
        model.editTask(task.id) { $0.title = value }
    }

    /// A binding to one field that writes through the store.
    private func binding<V: Equatable>(_ keyPath: WritableKeyPath<TaskItem, V>) -> Binding<V> {
        Binding(
            get: { task![keyPath: keyPath] },
            set: { value in
                guard let id = task?.id else { return }
                model.editTask(id) { $0[keyPath: keyPath] = value }
            }
        )
    }

    private var taskHolders: [Container] {
        model.containers.filter { $0.kind.holdsTasks }.sorted { $0.path < $1.path }
    }

    private func locationLabel(_ c: Container) -> String {
        ContainerTree.breadcrumb(for: c.id, in: model.containers).map(\.name).joined(separator: " › ")
    }
}

/// One work block: day, start, end, delete.
private struct BlockEditor: View {
    @Environment(AppModel.self) private var model
    let block: ScheduleBlock

    var body: some View {
        HStack {
            DatePicker("", selection: Binding(
                get: { block.startsAt },
                set: { start in
                    let length = block.endsAt.timeIntervalSince(block.startsAt)
                    try? model.store.updateScheduleBlock(block.id, start: start, end: start.addingTimeInterval(length))
                }
            ))
            .labelsHidden()
            Text("–").foregroundStyle(WSColor.textTertiary)
            DatePicker("", selection: Binding(
                get: { block.endsAt },
                set: { end in try? model.store.updateScheduleBlock(block.id, start: block.startsAt, end: end) }
            ), displayedComponents: .hourAndMinute)
            .labelsHidden()
            Spacer()
            Button { try? model.store.deleteScheduleBlock(block.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(WSColor.textTertiary)
        }
    }
}
