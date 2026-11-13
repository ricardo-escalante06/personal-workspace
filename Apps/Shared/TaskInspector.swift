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
    @State private var milestones: [TaskItem] = []
    @State private var showNewTag = false
    @State private var newTagName = ""
    @FocusState private var titleFocused: Bool
    /// The repeating task this occurrence belongs to (nil for a plain task).
    @State private var series: TaskItem?
    @State private var pendingTimeChange: LocalTime??
    @State private var editingRepeat = false

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
        // An occurrence of a repeating task: show it, backed by its series + override.
        let occurrence = OccurrenceRegistry.shared.resolve(taskId)
        let id = occurrence?.series ?? taskId
        let observation = ValueObservation.tracking { db -> (TaskItem?, [ScheduleBlock], [TaskItem], [TaskItem], TaskItem?) in
            let stored = try TaskItem.live().filter(id: id).fetchOne(db)
            var task = stored
            if let occurrence, let stored {
                let o = try OccurrenceOverride.live()
                    .filter(Column("task_id") == id && Column("occurrence_key") == occurrence.key).fetchOne(db)
                task = Occurrences.instance(of: stored, key: occurrence.key, override: o)
            }
            let blocks = try ScheduleBlock.live().filter(Column("task_id") == id).order(Column("starts_at")).fetchAll(db)
                .filter { b in occurrence == nil || b.occurrenceKey == nil || b.occurrenceKey == occurrence?.key }
            let subtasks = try TaskItem.live().filter(Column("parent_task_id") == id).order(Column("sort_rank")).fetchAll(db)
            let milestones = try TaskItem.live()
                .filter(Column("container_id") == task?.containerId && Column("is_milestone") == true)
                .order(Column("due_date"), Column("sort_rank")).fetchAll(db)
            return (task, blocks, subtasks, milestones, stored?.isRecurring == true ? stored : nil)
        }
        do {
            for try await (t, b, s, m, series) in observation.values(in: model.store.db) {
                self.series = series
                milestones = m
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

            if task.isMilestone {
                Section {
                    MilestoneSwatches(milestone: task)
                } header: {
                    Text("Milestone color")
                } footer: {
                    Text("Its tasks use this color on the timeline.")
                        .font(.caption).foregroundStyle(WSColor.textTertiary)
                }
            }

            Section(task.isOccurrence ? "This occurrence" : "Dates") {
                if !task.isOccurrence {
                Toggle("Start date", isOn: Binding(
                    get: { task.startDate != nil },
                    set: { on in model.editTask(task.id) { $0.startDate = on ? (task.dueDate.map { min($0, LocalDate(Date())) } ?? LocalDate(Date())) : nil } }
                ))
                if let start = task.startDate {
                    DateField("Starts", date: start) { d in model.editTask(task.id) { $0.startDate = d } }
                }
                }
                if !task.isRecurring {
                Toggle("Due date", isOn: Binding(
                    get: { task.dueDate != nil },
                    set: { on in model.editTask(task.id) { $0.dueDate = on ? LocalDate(Date()) : nil } }
                ))
                }
                if let due = task.dueDate {
                    DateField("Due", date: due) { d in model.editTask(task.id) { $0.dueDate = d } }
                    Toggle("Specific time", isOn: Binding(
                        get: { task.dueTime != nil },
                        set: { on in changeTime(task, on ? LocalTime(hour: 23, minute: 59) : nil) }
                    ))
                    if let time = task.dueTime {
                        DatePicker("Time", selection: Binding(
                            get: { due.at(time) },
                            set: { d in
                                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                                changeTime(task, LocalTime(hour: c.hour ?? 0, minute: c.minute ?? 0))
                            }
                        ), displayedComponents: .hourAndMinute)
                    }
                }
            }

            Section {
                Picker("Status", selection: binding(\.status)) {
                    Text("Not started").tag(TaskStatus.notStarted)
                    Text("In progress").tag(TaskStatus.inProgress)
                    Text("Done").tag(TaskStatus.done)
                    Text("Cancelled").tag(TaskStatus.cancelled)
                }
                HStack {
                    Picker("Tag", selection: binding(\.categoryId)) {
                        Text("None").tag(UUID?.none)
                        ForEach(model.categories) { c in
                            Text(c.name).tag(UUID?.some(c.id))
                        }
                    }
                    Button { newTagName = ""; showNewTag = true } label: { Image(systemName: "plus") }
                        .buttonStyle(.borderless)
                        .help("New tag")
                    Button { model.showTagManager = true } label: { Image(systemName: "slider.horizontal.3") }
                        .buttonStyle(.borderless)
                        .help("Manage tags")
                }
                .alert("New Tag", isPresented: $showNewTag) {
                    TextField("Name", text: $newTagName)
                    Button("Add") { model.applyNewTag(newTagName, to: task.id) }
                    Button("Cancel", role: .cancel) {}
                }
                Toggle(isOn: binding(\.isStarred)) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Starred")
                        if !task.isStarred, let c = model.category(task.categoryId), c.autoStar {
                            Text("Starred automatically: \(c.name) tag")
                                .font(.caption).foregroundStyle(WSColor.textTertiary)
                        }
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
                    ForEach(model.taskHolders) { c in
                        Text(model.locationLabels[c.id] ?? c.name).tag(UUID?.some(c.id))
                    }
                }
            }

            if model.container(task.containerId)?.kind == .project {
                Section("Project") {
                    Toggle("This is a milestone", isOn: binding(\.isMilestone))
                    if !task.isMilestone {
                        Picker("Milestone", selection: binding(\.milestoneId)) {
                            Text("None").tag(UUID?.none)
                            ForEach(milestones) { m in Text(m.title).tag(UUID?.some(m.id)) }
                        }
                    }
                }
            }

            RepeatSection(task: task, series: series, editing: $editingRepeat)

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
                    set: { v in model.editTask(task.id, typing: "Link") { $0.sourceUrl = v.isEmpty ? nil : v } }
                ))
            }

            Section("Notes") {
                TextEditor(text: $notesDraft)
                    .font(WSFont.body)
                    .frame(minHeight: 90)
                    .onChange(of: notesDraft) { _, value in
                        guard value != task.notes else { return }
                        model.editTask(task.id, typing: "Notes") { $0.notes = value }
                    }
            }

            Section {
                if task.isOccurrence {
                    Button("Skip This One") { model.deleteTask(task.id) }
                    Button("Delete Repeating Task", role: .destructive) { if let s = series { model.deleteTask(s.id) } }
                } else {
                    Button("Delete Task", role: .destructive) { model.deleteTask(task.id) }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Change the time for…", isPresented: Binding(
            get: { pendingTimeChange != nil }, set: { if !$0 { pendingTimeChange = nil } }), titleVisibility: .visible) {
            Button("Only This One") { applyTime(.one) }
            Button("This and Future Ones") { applyTime(.following) }
            Button("All of Them") { applyTime(.all) }
            Button("Cancel", role: .cancel) { pendingTimeChange = nil }
        } message: {
            Text("Earlier ones keep their time with “This and Future Ones”.")
        }
        .sheet(isPresented: $editingRepeat) {
            if let base = series ?? self.task { RepeatEditorSheet(task: base) }
        }
        .scrollContentBackground(.hidden)
        .background(WSColor.raised)
    }

    /// Due time on a repeating task asks which occurrences it applies to.
    private func changeTime(_ task: TaskItem, _ time: LocalTime?) {
        if task.isOccurrence {
            pendingTimeChange = .some(time)
        } else {
            model.editTask(task.id) { $0.dueTime = time }
        }
    }

    private func applyTime(_ scope: EventEditScope) {
        guard let task, case .some(let time) = pendingTimeChange else { return }
        pendingTimeChange = nil
        model.editRepeating(task, scope: scope) { $0.dueTime = time }
    }

    private func commitTitle() {
        guard let task, titleDraft != task.title,
              !titleDraft.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let value = titleDraft
        model.editTask(task.id, typing: "Title") { $0.title = value }
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

}

/// One work block: day, start, end, delete.
private struct BlockEditor: View {
    @Environment(AppModel.self) private var model
    let block: ScheduleBlock

    var body: some View {
        HStack {
            // Day as plain text with a popover calendar; times stay steppers.
            DateField("", date: LocalDate(block.startsAt)) { day in
                let cal = Calendar.current
                let length = block.endsAt.timeIntervalSince(block.startsAt)
                let t = cal.dateComponents([.hour, .minute], from: block.startsAt)
                let start = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0,
                                     of: day.startOfDay(in: .current)) ?? block.startsAt
                model.updateBlock(block.id, start: start, end: start.addingTimeInterval(length), coalesce: true)
            }
            .fixedSize()
            DatePicker("", selection: Binding(
                get: { block.startsAt },
                set: { start in
                    let length = block.endsAt.timeIntervalSince(block.startsAt)
                    model.updateBlock(block.id, start: start, end: start.addingTimeInterval(length), coalesce: true)
                }
            ), displayedComponents: .hourAndMinute)
            .labelsHidden()
            Text("–").foregroundStyle(WSColor.textTertiary)
            DatePicker("", selection: Binding(
                get: { block.endsAt },
                set: { end in model.updateBlock(block.id, start: block.startsAt, end: end, coalesce: true) }
            ), displayedComponents: .hourAndMinute)
            .labelsHidden()
            Spacer()
            Button { model.deleteBlock(block.id) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless)
                .foregroundStyle(WSColor.textTertiary)
        }
    }
}

/// A date shown as plain text ("Sat, Nov 14"); clicking it opens a calendar in a
/// popover, which macOS keeps on screen (the stock field's calendar got cut off at
/// the window edge).
struct DateField: View {
    let label: String
    let date: LocalDate
    let set: (LocalDate) -> Void
    @State private var open = false

    init(_ label: String, date: LocalDate, set: @escaping (LocalDate) -> Void) {
        self.label = label
        self.date = date
        self.set = set
    }

    var body: some View {
        if label.isEmpty { button } else { LabeledContent(label) { button } }
    }

    private var button: some View {
        Group {
            Button { open.toggle() } label: {
                Text(date.startOfDay(in: .current).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    .foregroundStyle(WSColor.textPrimary)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(open ? WSColor.hairline : .clear))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $open, arrowEdge: .leading) {
                DatePicker("", selection: Binding(
                    get: { date.startOfDay(in: .current) },
                    set: { d in set(LocalDate(d)); open = false }
                ), displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .padding(WSSpace.s)
                .frame(width: 240)
                .presentationCompactAdaptation(.popover)
            }
        }
    }
}

/// Every color as a dot; the first one ("project") clears the milestone's own color.
struct MilestoneSwatches: View {
    @Environment(AppModel.self) private var model
    let milestone: TaskItem

    var body: some View {
        let project = ContainerColor(named: model.container(milestone.containerId)?.color ?? "grey")
        HStack(spacing: 7) {
            dot(project, selected: milestone.color == nil, help: "Project color") {
                model.setMilestoneColor(milestone.id, nil)
            }
            Rectangle().fill(WSColor.hairline).frame(width: 1, height: 14)
            ForEach(ContainerColor.allCases) { c in
                dot(c, selected: milestone.color == c.rawValue, help: c.displayName) {
                    model.setMilestoneColor(milestone.id, c.rawValue)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func dot(_ c: ContainerColor, selected: Bool, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Circle().fill(c.accent)
                .frame(width: 16, height: 16)
                .overlay(Circle().strokeBorder(WSColor.textPrimary, lineWidth: selected ? 2 : 0).padding(-3))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}
