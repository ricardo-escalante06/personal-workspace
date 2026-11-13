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
        let today = LocalDate(Date())
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // Title
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    TaskCheckbox(isDone: task.status == .done, color: color) { model.toggleDone(task) }
                    TextField("Title", text: $titleDraft, axis: .vertical)
                        .font(.system(size: 18, weight: .medium))
                        .textFieldStyle(.plain)
                        .focused($titleFocused)
                        .onSubmit(commitTitle)
                        .onChange(of: titleFocused) { _, focused in if !focused { commitTitle() } }
                }
                .padding(.horizontal, WSSpace.l)
                .padding(.top, WSSpace.l)
                .padding(.bottom, WSSpace.m)

                // Dates first: they change the most.
                PanelRow(icon: "flag") {
                    HStack(spacing: 10) {
                        if let due = task.dueDate {
                            DayChoice(day: due) { d in model.editTask(task.id) { $0.dueDate = d } }
                            if let time = task.dueTime {
                                TimeChoice(time: due.at(time), earliest: nil, reference: nil) { d in
                                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                                    changeTime(task, LocalTime(hour: c.hour ?? 0, minute: c.minute ?? 0))
                                }
                                QuietButton("✕", help: "No time") { changeTime(task, nil) }
                            } else {
                                QuietButton("Add time") { changeTime(task, LocalTime(hour: 23, minute: 59)) }
                            }
                            Spacer(minLength: 0)
                            if !task.isRecurring {
                                QuietButton("Clear", help: "No due date") { model.editTask(task.id) { $0.dueDate = nil } }
                            }
                        } else {
                            DayChoice(day: nil, placeholder: "Due date") { d in model.editTask(task.id) { $0.dueDate = d } }
                        }
                    }
                }
                if !task.isOccurrence {
                    PanelRow(icon: "arrow.right.to.line") {
                        HStack {
                            DayChoice(day: task.startDate, placeholder: "Start date", prefix: "Starts ") { d in
                                model.editTask(task.id) { t in t.startDate = t.dueDate.map { min(d, $0) } ?? d }
                            }
                            Spacer(minLength: 0)
                            if task.startDate != nil {
                                QuietButton("Clear", help: "No start date") { model.editTask(task.id) { $0.startDate = nil } }
                            }
                        }
                    }
                }
                RepeatRow(task: task, series: series, editing: $editingRepeat)

                PanelDivider()

                PanelRow(icon: "circle.dashed") {
                    PlainMenu {
                        ForEach([TaskStatus.notStarted, .inProgress, .done, .cancelled], id: \.self) { st in
                            Button(Self.statusName(st)) { model.editTask(task.id) { $0.status = st } }
                        }
                    } label: { Text(Self.statusName(task.status)) }
                }
                PanelRow(icon: "tag") {
                    HStack(spacing: 8) {
                        PlainMenu {
                            Button("None") { model.editTask(task.id) { $0.categoryId = nil } }
                            Divider()
                            ForEach(model.categories) { c in
                                Button(c.name) { model.editTask(task.id) { $0.categoryId = c.id } }
                            }
                            Divider()
                            Button("New Tag…") { newTagName = ""; showNewTag = true }
                            Button("Manage Tags…") { model.showTagManager = true }
                        } label: {
                            if let tag = model.tagStyle(task.categoryId) { TagPill(tag) }
                            else { Text("Tag").foregroundStyle(WSColor.textTertiary) }
                        }
                        if !task.isStarred, let c = model.category(task.categoryId), c.autoStar {
                            Text("auto-starred").font(.system(size: 11)).foregroundStyle(WSColor.textTertiary)
                        }
                    }
                    .alert("New Tag", isPresented: $showNewTag) {
                        TextField("Name", text: $newTagName)
                        Button("Add") { model.applyNewTag(newTagName, to: task.id) }
                        Button("Cancel", role: .cancel) {}
                    }
                }
                PanelRow(icon: "tray") {
                    PlainMenu {
                        Button("Inbox") { model.editTask(task.id) { $0.containerId = nil } }
                        Divider()
                        ForEach(model.taskHolders) { c in
                            Button(model.locationLabels[c.id] ?? c.name) { model.editTask(task.id) { $0.containerId = c.id } }
                        }
                    } label: {
                        Text(task.containerId.flatMap { model.locationLabels[$0] ?? model.container($0)?.name } ?? "Inbox").lineLimit(1)
                    }
                }
                PanelRow(icon: nil) {
                    HStack(spacing: 18) {
                        QuietToggle(task.isStarred ? "★ Starred" : "☆ Star", on: task.isStarred) {
                            model.editTask(task.id) { $0.isStarred.toggle() }
                        }
                        PlainMenu {
                            Button("No priority") { model.editTask(task.id) { $0.priority = nil } }
                            Button("Low") { model.editTask(task.id) { $0.priority = 1 } }
                            Button("Medium") { model.editTask(task.id) { $0.priority = 2 } }
                            Button("High") { model.editTask(task.id) { $0.priority = 3 } }
                        } label: {
                            Text(task.priority.map { ["", "Low", "Medium", "High"][min($0, 3)] + " priority" } ?? "Priority")
                                .foregroundStyle(task.priority == nil ? WSColor.textTertiary : WSColor.textSecondary)
                        }
                    }
                }

                if model.container(task.containerId)?.kind == .project {
                    PanelRow(icon: "diamond") {
                        HStack(spacing: 18) {
                            QuietToggle("Milestone", on: task.isMilestone) {
                                model.editTask(task.id) { $0.isMilestone.toggle() }
                            }
                            if !task.isMilestone {
                                PlainMenu {
                                    Button("None") { model.editTask(task.id) { $0.milestoneId = nil } }
                                    ForEach(milestones) { m in
                                        Button(m.title) { model.editTask(task.id) { $0.milestoneId = m.id } }
                                    }
                                } label: {
                                    Text(milestones.first { $0.id == task.milestoneId }.map { "In " + $0.title } ?? "Part of a milestone")
                                        .foregroundStyle(task.milestoneId == nil ? WSColor.textTertiary : WSColor.textSecondary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                    if task.isMilestone {
                        PanelRow(icon: nil) { MilestoneSwatches(milestone: task) }
                    }
                }

                PanelDivider()

                // Work blocks
                ForEach(blocks) { block in
                    PanelRow(icon: "checklist") { BlockEditor(block: block) }
                }
                PanelRow(icon: blocks.isEmpty ? "checklist" : nil) {
                    QuietButton(blocks.isEmpty ? "Plan time to work on this" : "Add work block") { model.addBlock(to: task) }
                }

                // Subtasks
                ForEach(subtasks) { sub in
                    PanelRow(icon: nil) {
                        HStack(spacing: WSSpace.s) {
                            TaskCheckbox(isDone: sub.status == .done, color: color) { model.toggleDone(sub) }
                            Text(sub.title)
                                .strikethrough(sub.status == .done)
                                .foregroundStyle(sub.status == .done ? WSColor.textTertiary : WSColor.textPrimary)
                            Spacer()
                            Button { model.deleteTask(sub.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.plain)
                                .foregroundStyle(WSColor.textTertiary)
                        }
                    }
                }
                PanelRow(icon: "plus") {
                    TextField("Add subtask", text: $newSubtask)
                        .textFieldStyle(.plain)
                        .onSubmit {
                            let title = newSubtask.trimmingCharacters(in: .whitespaces)
                            guard !title.isEmpty else { return }
                            model.addSubtask(to: task, title: title)
                            newSubtask = ""
                        }
                }

                PanelDivider()

                PanelRow(icon: "timer") {
                    TextField("Estimate (minutes)", value: binding(\.estimatedMinutes), format: .number)
                        .textFieldStyle(.plain)
                }
                PanelRow(icon: "link") {
                    TextField("Link", text: Binding(
                        get: { task.sourceUrl ?? "" },
                        set: { v in model.editTask(task.id, typing: "Link") { $0.sourceUrl = v.isEmpty ? nil : v } }
                    ))
                    .textFieldStyle(.plain)
                }
                PanelRow(icon: "text.alignleft") {
                    TextField("Notes", text: $notesDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .lineLimit(2...20)
                        .onChange(of: notesDraft) { _, value in
                            guard value != task.notes else { return }
                            model.editTask(task.id, typing: "Notes") { $0.notes = value }
                        }
                }

                // Footer
                HStack(spacing: 16) {
                    if task.isOccurrence {
                        QuietButton("Skip this one") { model.deleteTask(task.id) }
                        Spacer()
                        Button("Delete repeating task") { if let s = series { model.deleteTask(s.id) } }
                            .buttonStyle(.plain).foregroundStyle(WSColor.now.opacity(0.85))
                    } else {
                        if let due = task.dueDate, due < today, !task.status.isClosed {
                            Text("Overdue").foregroundStyle(WSColor.now.opacity(0.85))
                        }
                        Spacer()
                        Button("Delete") { model.deleteTask(task.id) }
                            .buttonStyle(.plain).foregroundStyle(WSColor.now.opacity(0.85))
                    }
                }
                .font(.system(size: 12))
                .padding(.horizontal, WSSpace.l)
                .padding(.top, WSSpace.m)
            }
            .padding(.bottom, WSSpace.m)
        }
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
        .background(WSColor.raised)
    }

    static func statusName(_ s: TaskStatus) -> String {
        switch s {
        case .notStarted: "Not started"
        case .inProgress: "In progress"
        case .done: "Done"
        case .cancelled: "Cancelled"
        }
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

/// One work block: day, start → end, all plain text you click to change.
private struct BlockEditor: View {
    @Environment(AppModel.self) private var model
    let block: ScheduleBlock

    var body: some View {
        HStack(spacing: 8) {
            DayChoice(day: LocalDate(block.startsAt)) { day in
                let cal = Calendar.current
                let t = cal.dateComponents([.hour, .minute], from: block.startsAt)
                let start = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0,
                                     of: day.startOfDay(in: .current)) ?? block.startsAt
                move(to: start)
            }
            TimeChoice(time: block.startsAt, earliest: nil, reference: nil) { move(to: $0) }
            Image(systemName: "arrow.right").font(.system(size: 9)).foregroundStyle(WSColor.textTertiary)
            TimeChoice(time: block.endsAt, earliest: block.startsAt, reference: block.startsAt) { end in
                model.updateBlock(block.id, start: block.startsAt, end: end, coalesce: true)
            }
            Spacer(minLength: 0)
            Button { model.deleteBlock(block.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                .buttonStyle(.plain)
                .foregroundStyle(WSColor.textTertiary)
                .help("Remove this block")
        }
    }

    /// Keeps the block's length.
    private func move(to start: Date) {
        let length = block.endsAt.timeIntervalSince(block.startsAt)
        model.updateBlock(block.id, start: start, end: start.addingTimeInterval(length), coalesce: true)
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
