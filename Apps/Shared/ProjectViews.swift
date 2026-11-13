import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// The bottom of a project's page: Milestones (phases with progress), Timeline
/// (bars over weeks) or Board (Kanban). Same tasks, three ways to look at them.
struct ProjectViews: View {
    @Environment(AppModel.self) private var model
    let projectId: UUID
    /// Top-level tasks in the project (from the dashboard snapshot).
    let tasks: [TaskItem]

    enum Mode: String, CaseIterable, Identifiable {
        case milestones = "Milestones", timeline = "Timeline", board = "Board"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .milestones: "diamond"
            case .timeline: "chart.bar.xaxis"
            case .board: "rectangle.split.3x1"
            }
        }
    }

    @AppStorage("projectViewMode") private var modeRaw = Mode.milestones.rawValue
    @State private var columns: [BoardColumn] = []

    private var mode: Mode { Mode(rawValue: modeRaw) ?? .milestones }
    private var project: Container? { model.container(projectId) }
    private var color: ContainerColor { ContainerColor(named: project?.color ?? "grey") }

    /// Milestones, by start (or due) date.
    private var milestones: [TaskItem] {
        tasks.filter { $0.isMilestone && $0.containerId == projectId }
            .sorted { a, b in
                let da = a.startDate ?? a.dueDate, db = b.startDate ?? b.dueDate
                switch (da, db) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.sortRank < b.sortRank
                }
            }
    }

    private var workTasks: [TaskItem] { tasks.filter { !$0.isMilestone } }

    /// A milestone's own color, else the project's. Tasks take their milestone's.
    private var tint: (TaskItem) -> ContainerColor {
        let project = color
        let byId = Dictionary(milestones.map { ($0.id, $0.color) }, uniquingKeysWith: { a, _ in a })
        return { t in
            let name = t.isMilestone ? t.color : t.milestoneId.flatMap { byId[$0] ?? nil }
            return name.map { ContainerColor(named: $0) } ?? project
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WSSpace.m) {
            HStack(spacing: WSSpace.m) {
                SectionLabel("Project", trailing: "\(workTasks.filter { !$0.status.isClosed }.count) open")
                    .fixedSize()
                Spacer()
                Picker("View", selection: $modeRaw) {
                    ForEach(Mode.allCases) { m in
                        Label(m.rawValue, systemImage: m.symbol).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            switch mode {
            case .milestones:
                MilestonesView(projectId: projectId, milestones: milestones, tasks: workTasks, color: color, tint: tint)
            case .timeline:
                ProjectTimelineView(projectId: projectId, milestones: milestones, tasks: workTasks, color: color, tint: tint)
            case .board:
                ProjectBoardView(projectId: projectId, columns: columns, tasks: workTasks, milestones: milestones)
            }
        }
        .task(id: projectId) {
            model.ensureBoard(projectId)
            let id = projectId
            let observation = ValueObservation.tracking { db in
                try BoardColumn.live().filter(Column("container_id") == id).order(Column("sort_rank")).fetchAll(db)
            }
            do {
                for try await value in observation.values(in: model.store.db) { columns = value }
            } catch {}
        }
    }
}

// MARK: - Shared row

/// A task row inside the project views (same look as the dashboard's rows).
private struct ProjectTaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    var showMilestone: String? = nil
    var order: [UUID] = []
    var tint: ContainerColor? = nil

    var body: some View {
        let today = LocalDate(Date())
        TaskRowView(
            task: task,
            context: .init(
                color: tint ?? ContainerColor(named: model.color(for: task)),
                subtitle: showMilestone,
                tag: model.tagStyle(task.categoryId),
                isStarred: model.isStarred(task),
                timeText: task.startDate.map { "from " + WSFormat.relativeDay($0, today: today) },
                dueText: WSFormat.due(task, today: today),
                isOverdue: task.dueDate.map { $0 < today && !task.status.isClosed } ?? false
            ),
            isSelected: model.isSelected(task.id),
            onToggle: { model.toggleDone(task) }
        )
        .taskInteractions(task, order: order)
    }
}

private func dateRange(_ start: LocalDate?, _ end: LocalDate?) -> String? {
    let f: (LocalDate) -> String = { $0.startOfDay(in: .current).formatted(.dateTime.month(.abbreviated).day()) }
    switch (start, end) {
    case let (s?, e?): return s == e ? f(e) : "\(f(s)) – \(f(e))"
    case let (s?, nil): return "from \(f(s))"
    case let (nil, e?): return "by \(f(e))"
    default: return nil
    }
}

/// Parses "due-<uuid>" drag payloads (rows, chips and cards all use it).
private func draggedTaskId(_ payload: String) -> UUID? {
    guard payload.hasPrefix("due-") else { return nil }
    return UUID(uuidString: String(payload.dropFirst(4)))
}

// MARK: - Milestones

private struct MilestonesView: View {
    @Environment(AppModel.self) private var model
    let projectId: UUID
    let milestones: [TaskItem]
    let tasks: [TaskItem]
    let color: ContainerColor
    let tint: (TaskItem) -> ContainerColor

    @State private var newMilestone = ""
    @State private var dropTarget: UUID??
    @State private var showDone = false

    var body: some View {
        let liveIds = Set(milestones.map(\.id))
        let byMilestone = Dictionary(grouping: tasks) { t in t.milestoneId.flatMap { liveIds.contains($0) ? $0 : nil } }
        VStack(alignment: .leading, spacing: WSSpace.l) {
            ForEach(milestones) { m in
                section(m, tasks: byMilestone[m.id] ?? [])
            }
            section(nil, tasks: byMilestone[nil] ?? [])
            HStack(spacing: WSSpace.s) {
                Image(systemName: "diamond").foregroundStyle(WSColor.textTertiary)
                TextField("New milestone — e.g. “Video 3” or “Design review”", text: $newMilestone)
                    .textFieldStyle(.plain)
                    .font(WSFont.body)
                    .onSubmit {
                        model.createMilestone(newMilestone, in: projectId)
                        newMilestone = ""
                    }
            }
            .padding(.horizontal, WSSpace.s)
            Toggle("Show completed", isOn: $showDone)
                .checkboxToggleStyle()
                .font(.system(size: 12))
                .foregroundStyle(WSColor.textSecondary)
        }
    }

    @ViewBuilder
    private func section(_ milestone: TaskItem?, tasks: [TaskItem]) -> some View {
        let done = tasks.filter { $0.status == .done }.count
        let visible = tasks.filter { showDone || $0.status != .done }
            .sorted { a, b in
                switch (a.startDate ?? a.dueDate, b.startDate ?? b.dueDate) {
                case let (x?, y?) where x != y: return x < y
                case (_?, nil): return true
                case (nil, _?): return false
                default: return a.sortRank < b.sortRank
                }
            }
        let key: UUID?? = .some(milestone?.id)
        let mColor = milestone.map(tint) ?? color
        if milestone != nil || !tasks.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: WSSpace.s) {
                    if let milestone {
                        Button { model.toggleDone(milestone) } label: {
                            Image(systemName: milestone.status == .done ? "diamond.fill" : "diamond")
                                .foregroundStyle(mColor.accent)
                        }
                        .buttonStyle(.plain)
                        .help(milestone.status == .done ? "Mark milestone not done" : "Mark milestone done")
                        Text(milestone.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(milestone.status == .done ? WSColor.textTertiary : WSColor.textPrimary)
                            .strikethrough(milestone.status == .done)
                        if let range = dateRange(milestone.startDate, milestone.dueDate) {
                            Text(range).font(WSFont.metric).foregroundStyle(WSColor.textSecondary)
                        }
                    } else {
                        Text(milestones.isEmpty ? "Tasks" : "No milestone")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(WSColor.textSecondary)
                    }
                    Spacer()
                    if !tasks.isEmpty {
                        Text("\(done)/\(tasks.count)").font(WSFont.metric).foregroundStyle(WSColor.textTertiary)
                        ProgressBar(value: Double(done) / Double(tasks.count), color: mColor).frame(width: 70, height: 4)
                    }
                    Button {
                        model.quickAdd = QuickAddRequest(presetContainer: projectId, presetMilestone: milestone?.id)
                    } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain)
                        .foregroundStyle(WSColor.textSecondary)
                        .help(milestone.map { "Add a task to \($0.title)" } ?? "Add a task")
                }
                .padding(.horizontal, WSSpace.s)
                .padding(.vertical, 4)
                // Selected like any task row.
                .background(RoundedRectangle(cornerRadius: WSRadius.block)
                    .fill(milestone.map { model.isSelected($0.id) } == true ? WSColor.hairline : .clear))
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { if let milestone { model.openDetails(milestone.id) } }
                .simultaneousGesture(TapGesture().onEnded { if let milestone { model.click(milestone.id, in: []) } })
                .contextMenu {
                    if let milestone {
                        Button("Open Details") { model.openDetails(milestone.id) }
                        MilestoneColorMenu(milestone: milestone)
                        Divider()
                        Button("Delete Milestone", role: .destructive) { model.deleteTask(milestone.id) }
                    }
                }

                ForEach(visible) { t in ProjectTaskRow(task: t, order: visible.map(\.id), tint: mColor) }
                if visible.isEmpty {
                    Text(tasks.isEmpty ? "Drag tasks here, or press + to add one." : "All done.")
                        .font(.system(size: 12))
                        .foregroundStyle(WSColor.textTertiary)
                        .padding(.horizontal, WSSpace.s).padding(.vertical, 4)
                }
            }
            .padding(.vertical, WSSpace.xs)
            .background(RoundedRectangle(cornerRadius: WSRadius.block)
                .fill(dropTarget == key ? WSColor.hairline : .clear))
            .dropDestination(for: String.self) { items, _ in
                guard let id = items.first.flatMap(draggedTaskId) else { return false }
                model.editTasks(model.targets(for: id), "Change Milestone") { $0.milestoneId = milestone?.id }
                return true
            } isTargeted: { on in
                if on { dropTarget = key } else if dropTarget == key { dropTarget = nil }
            }
        }
    }
}

// MARK: - Timeline

/// Weeks run left to right. A milestone is one bar (its own dates, or the span of its
/// tasks, drawn dashed); open it to see its tasks as thinner bars underneath. A task
/// with only a due date is a marker on that day. Drag a bar to move it; drag its
/// ends to change the start or due date.
private struct ProjectTimelineView: View {
    @Environment(AppModel.self) private var model
    let projectId: UUID
    let milestones: [TaskItem]
    let tasks: [TaskItem]
    let color: ContainerColor
    let tint: (TaskItem) -> ContainerColor

    @State private var collapsed: Set<UUID> = []
    /// The drag in progress (shared so a whole selection moves together).
    @State private var drag: TimelineDrag?

    static let dayWidth: CGFloat = 26
    static let rowHeight: CGFloat = 30
    static let labelWidth: CGFloat = 190

    private enum RowKind { case milestone, task }
    private struct Row: Identifiable {
        var task: TaskItem
        var kind: RowKind
        var start: LocalDate?
        var end: LocalDate?
        /// Span computed from the milestone's tasks rather than set on it.
        var isDerived = false
        var id: UUID { task.id }
    }

    private var today: LocalDate { LocalDate(Date()) }

    private var rows: [Row] {
        let liveIds = Set(milestones.map(\.id))
        let byMilestone = Dictionary(grouping: tasks) { t in t.milestoneId.flatMap { liveIds.contains($0) ? $0 : nil } }
        func taskRow(_ t: TaskItem) -> Row { Row(task: t, kind: .task, start: t.startDate, end: t.dueDate) }
        func dated(_ ts: [TaskItem]) -> [TaskItem] {
            ts.filter { $0.dueDate != nil || $0.startDate != nil }
                .sorted { ($0.startDate ?? $0.dueDate!, $0.title) < ($1.startDate ?? $1.dueDate!, $1.title) }
        }
        var out: [Row] = []
        for m in milestones {
            let members = byMilestone[m.id] ?? []
            var row = Row(task: m, kind: .milestone, start: m.startDate, end: m.dueDate)
            if row.start == nil && row.end == nil {
                row.start = members.compactMap { $0.startDate ?? $0.dueDate }.min()
                row.end = members.compactMap { $0.dueDate ?? $0.startDate }.max()
                row.isDerived = true
            }
            out.append(row)
            if !collapsed.contains(m.id) { out += dated(members).map(taskRow) }
        }
        out += dated(byMilestone[nil] ?? []).map(taskRow)
        return out
    }

    private var unscheduled: [TaskItem] {
        tasks.filter { $0.dueDate == nil && $0.startDate == nil && !$0.status.isClosed }
    }

    /// First and last day drawn: a little before the earliest date, a few weeks past the last.
    private var range: (LocalDate, Int) {
        let dates = rows.flatMap { [$0.start, $0.end] }.compactMap { $0 } + [today]
        let first = Dashboard.weekStart(containing: dates.min()!.adding(days: -3))
        let last = max(dates.max()!.adding(days: 21), first.adding(days: 7 * 8))
        return (first, first.daysUntil(last) + 1)
    }

    var body: some View {
        let (first, dayCount) = range
        let rows = rows
        VStack(alignment: .leading, spacing: WSSpace.m) {
            HStack(alignment: .top, spacing: 0) {
                // Labels
                VStack(alignment: .leading, spacing: 0) {
                    Color.clear.frame(height: 34)
                    ForEach(rows) { row in label(row).frame(height: Self.rowHeight) }
                }
                .frame(width: Self.labelWidth)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        VStack(alignment: .leading, spacing: 0) {
                            header(first: first, dayCount: dayCount)
                            ZStack(alignment: .topLeading) {
                                grid(first: first, dayCount: dayCount, height: CGFloat(rows.count) * Self.rowHeight)
                                VStack(spacing: 0) {
                                    let order = rows.map(\.id)
                                    ForEach(rows) { row in
                                        TimelineBar(row: barModel(row), first: first, dayWidth: Self.dayWidth,
                                                    color: tint(row.task),
                                                    isSelected: model.isSelected(row.task.id),
                                                    drag: $drag,
                                                    order: order,
                                                    dragIds: { dragGroup(for: row, in: rows) },
                                                    commit: commit)
                                            .frame(width: CGFloat(dayCount) * Self.dayWidth, height: Self.rowHeight, alignment: .leading)
                                    }
                                }
                                .coordinateSpace(name: TimelineBar.space)
                            }
                        }
                        .padding(.bottom, WSSpace.s)
                    }
                    .onAppear {
                        let back = max(0, first.daysUntil(today) - 7)
                        proxy.scrollTo("day-\(back)", anchor: .leading)
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: WSRadius.block).strokeBorder(WSColor.hairline))

            if rows.isEmpty {
                Text("Give milestones or tasks a start or due date to see them here.")
                    .font(.system(size: 12)).foregroundStyle(WSColor.textTertiary)
            }
            if !unscheduled.isEmpty {
                VStack(alignment: .leading, spacing: WSSpace.xs) {
                    SectionLabel("Unscheduled", trailing: "\(unscheduled.count)")
                    FlowChips(tasks: unscheduled)
                }
            }
        }
    }

    /// What moves when `row` is dragged: the selection if the row is in it, otherwise
    /// the row alone. A milestone always brings its tasks along.
    private func dragGroup(for row: Row, in rows: [Row]) -> Set<UUID> {
        var ids: Set<UUID> = model.isSelected(row.id) ? model.selectedTaskIds : [row.id]
        let milestoneIds = Set(milestones.map(\.id)).intersection(ids)
        for t in tasks where t.milestoneId.map(milestoneIds.contains) == true { ids.insert(t.id) }
        return ids
    }

    /// Drop: shift every dragged task by whole days (one ⌘Z step), or move one edge.
    private func commit(_ d: TimelineDrag) {
        let days = Int((d.dx / Self.dayWidth).rounded())
        guard days != 0 else { return }
        switch d.part {
        case .body:
            let ids = Array(d.ids)
            model.editTasks(ids, ids.count == 1 ? "Move" : "Move \(ids.count) Items") { t in
                t.startDate = t.startDate?.adding(days: days)
                t.dueDate = t.dueDate?.adding(days: days)
            }
        case .start:
            model.editTasks([d.anchor], "Change Start") { t in
                // A bar drawn from only a due date gains a start when you pull its left edge.
                let base = t.startDate ?? t.dueDate
                t.startDate = base.map { b in t.dueDate.map { min(b.adding(days: days), $0) } ?? b.adding(days: days) }
            }
        case .end:
            model.editTasks([d.anchor], "Change Due Date") { t in
                let base = t.dueDate ?? t.startDate
                t.dueDate = base.map { b in t.startDate.map { max(b.adding(days: days), $0) } ?? b.adding(days: days) }
            }
        }
    }

    private func barModel(_ row: Row) -> TimelineBar.Model {
        TimelineBar.Model(task: row.task, isMilestone: row.kind == .milestone, start: row.start, end: row.end,
                          isDerived: row.isDerived)
    }

    private func label(_ row: Row) -> some View {
        HStack(spacing: 5) {
            if row.kind == .milestone {
                Button {
                    if collapsed.contains(row.task.id) { collapsed.remove(row.task.id) } else { collapsed.insert(row.task.id) }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(collapsed.contains(row.task.id) ? 0 : 90))
                        .frame(width: 12)
                }
                .buttonStyle(.plain)
                .foregroundStyle(WSColor.textTertiary)
                Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(tint(row.task).accent)
            } else {
                Color.clear.frame(width: row.task.milestoneId == nil ? 0 : 17)
            }
            Text(row.task.title)
                .font(.system(size: 12.5, weight: row.kind == .milestone ? .semibold : .regular))
                .foregroundStyle(row.task.status == .done ? WSColor.textTertiary : WSColor.textPrimary)
                .strikethrough(row.task.status == .done)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, WSSpace.s)
        .frame(maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 5)
            .fill(model.isSelected(row.task.id) ? WSColor.hairline : .clear)
            .padding(.vertical, 2).padding(.leading, 4))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { model.openDetails(row.task.id) }
        .simultaneousGesture(TapGesture().onEnded { model.click(row.task.id, in: rows.map(\.id)) })
        .contextMenu {
            if row.kind == .milestone { MilestoneColorMenu(milestone: row.task) }
            TaskContextMenu(task: row.task)
        }
    }

    private func header(first: LocalDate, dayCount: Int) -> some View {
        HStack(spacing: 0) {
            ForEach(0..<dayCount, id: \.self) { i in
                let d = first.adding(days: i)
                VStack(alignment: .leading, spacing: 1) {
                    Text(d.day == 1 || i == 0 ? d.startOfDay(in: .current).formatted(.dateTime.month(.abbreviated)) : " ")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(WSColor.textSecondary)
                        .fixedSize()
                    Text("\(d.day)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(d == today ? Color.white : (Self.isWeekend(d) ? WSColor.textTertiary : WSColor.textSecondary))
                        .frame(width: 18, height: 16)
                        .background(Circle().fill(d == today ? WSColor.now : .clear))
                        .frame(width: Self.dayWidth)   // centered over its column, like the bars and today line
                }
                .frame(width: Self.dayWidth, height: 34, alignment: .leading)
                .id("day-\(i)")
            }
        }
    }

    private func grid(first: LocalDate, dayCount: Int, height: CGFloat) -> some View {
        let todayIndex = first.daysUntil(today)
        return Canvas { context, size in
            for i in 0..<dayCount {
                let d = first.adding(days: i)
                let x = CGFloat(i) * Self.dayWidth
                if Self.isWeekend(d) {
                    context.fill(Path(CGRect(x: x, y: 0, width: Self.dayWidth, height: size.height)),
                                 with: .color(WSColor.weekend))
                }
                if Dashboard.weekStart(containing: d) == d {
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(WSColor.hairline))
                }
            }
            if todayIndex >= 0 && todayIndex < dayCount {
                let x = (CGFloat(todayIndex) + 0.5) * Self.dayWidth
                context.fill(Path(CGRect(x: x, y: 0, width: 1.5, height: size.height)), with: .color(WSColor.now.opacity(0.8)))
            }
        }
        .frame(width: CGFloat(dayCount) * Self.dayWidth, height: max(height, Self.rowHeight))
    }

    static func isWeekend(_ d: LocalDate) -> Bool {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        let wd = c.component(.weekday, from: d.startOfDay(in: c.timeZone))
        return wd == 1 || wd == 7
    }
}

struct TimelineDrag: Equatable {
    enum Part { case body, start, end }
    var part: Part
    /// The bar under the pointer.
    var anchor: UUID
    /// Everything moving with it (body drags).
    var ids: Set<UUID>
    /// Pointer travel in points; snapped to days only on drop.
    var dx: CGFloat
}

/// One bar (or due-date marker) on the timeline. Drags follow the pointer smoothly
/// and snap to whole days when you let go; a hint shows where it will land.
private struct TimelineBar: View {
    struct Model {
        var task: TaskItem
        var isMilestone: Bool
        var start: LocalDate?
        var end: LocalDate?
        var isDerived: Bool
    }

    /// Fixed coordinate space for drags. Measuring in the bar's own space made the
    /// translation jump as the bar moved under the pointer.
    static let space = "timeline-bars"

    @Environment(AppModel.self) private var model
    let row: Model
    let first: LocalDate
    let dayWidth: CGFloat
    let color: ContainerColor
    let isSelected: Bool
    @Binding var drag: TimelineDrag?
    let order: [UUID]
    let dragIds: () -> Set<UUID>
    let commit: (TimelineDrag) -> Void

    var body: some View {
        if let s = row.start ?? row.end, let e = row.end ?? row.start {
            let x = CGFloat(first.daysUntil(s)) * dayWidth
            let width = CGFloat(s.daysUntil(e) + 1) * dayWidth
            let (dx, dw) = liveOffset(width: width)
            ZStack(alignment: .topLeading) {
                if row.start == nil && !row.isDerived {
                    marker
                        .offset(x: x + dx + dayWidth / 2 - 7, y: 8)
                } else {
                    bar(width: width + dw)
                        .offset(x: x + dx, y: row.isMilestone ? 4 : 7)
                }
                if let hint = dropHint(s, e) {
                    Text(hint)
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Capsule().fill(WSColor.raised))
                        .overlay(Capsule().strokeBorder(WSColor.hairline))
                        .foregroundStyle(WSColor.textSecondary)
                        .fixedSize()
                        .offset(x: x + dx + width + dw + 6, y: 7)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            Color.clear
        }
    }

    private var done: Bool { row.task.status == .done }
    private var isMoving: Bool {
        guard let drag else { return false }
        return drag.part == .body ? drag.ids.contains(row.task.id) : drag.anchor == row.task.id
    }

    /// Smooth (unsnapped) shift and width change while this bar is part of a drag.
    private func liveOffset(width: CGFloat) -> (CGFloat, CGFloat) {
        guard let drag, isMoving else { return (0, 0) }
        switch drag.part {
        case .body: return (drag.dx, 0)
        case .start:
            let dx = min(drag.dx, width - dayWidth)
            return (dx, -dx)
        case .end: return (0, max(drag.dx, dayWidth - width))
        }
    }

    /// "Nov 14 – Nov 20" (or "+3d") next to the bar under the pointer.
    private func dropHint(_ s: LocalDate, _ e: LocalDate) -> String? {
        guard let drag, drag.anchor == row.task.id else { return nil }
        let days = Int((drag.dx / dayWidth).rounded())
        func f(_ d: LocalDate) -> String { d.startOfDay(in: .current).formatted(.dateTime.month(.abbreviated).day()) }
        switch drag.part {
        case .body:
            let ns = s.adding(days: days), ne = e.adding(days: days)
            let range = ns == ne ? f(ns) : "\(f(ns)) – \(f(ne))"
            return drag.ids.count > 1 ? "\(range) · \(drag.ids.count) items" : range
        case .start: return "Start " + f(min(s.adding(days: days), e))
        case .end: return "Due " + f(max(e.adding(days: days), s))
        }
    }

    /// A task with only a due date: a flag (or diamond for a milestone) on that day.
    private var marker: some View {
        Image(systemName: row.isMilestone ? "diamond.fill" : "flag.fill")
            .font(.system(size: 11))
            .foregroundStyle(color.accent)
            .frame(width: 14, height: 14)
            .padding(2)
            .background(RoundedRectangle(cornerRadius: 3).strokeBorder(isSelected ? WSColor.textPrimary.opacity(0.85) : .clear))
            .opacity(done ? 0.45 : 1)
            .contentShape(Rectangle())
            .modifier(BarTaps(model: model, id: row.task.id, order: order))
            .gesture(moveGesture)
            .contextMenu { barMenu }
            .help("\(row.task.title) · due \(row.end.map { WSFormat.relativeDay($0, today: LocalDate(Date())) } ?? "")")
    }

    private func bar(width: CGFloat) -> some View {
        let height: CGFloat = row.isMilestone ? 22 : 16
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 5)
                .fill(row.isDerived ? Color.clear : (row.isMilestone ? color.fill : color.fill.opacity(0.75)))
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(isSelected ? WSColor.textPrimary.opacity(0.85) : color.accent.opacity(row.isMilestone ? 0.9 : 0.5),
                              style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: row.isDerived ? [3, 3] : []))
            if width > 60 {
                Text(row.task.title)
                    .font(.system(size: row.isMilestone ? 11.5 : 10.5, weight: row.isMilestone ? .semibold : .medium))
                    .foregroundStyle(WSColor.textPrimary)
                    .lineLimit(1)
                    .padding(.horizontal, 7)
            }
            if !row.isDerived {
                HStack {
                    edgeHandle(.start)
                    Spacer(minLength: 0)
                    edgeHandle(.end)
                }
            }
        }
        .frame(width: max(width, dayWidth), height: height)
        .opacity(done ? 0.45 : 1)
        .shadow(color: .black.opacity(isMoving ? 0.35 : 0), radius: 4, y: 2)
        .contentShape(Rectangle())
        .modifier(BarTaps(model: model, id: row.task.id, order: order))
        .gesture(moveGesture)
        .contextMenu { barMenu }
        .help(row.isDerived ? "\(row.task.title) · spans its tasks; dragging it moves them all" : row.task.title)
    }

    @ViewBuilder private var barMenu: some View {
        if row.isMilestone { MilestoneColorMenu(milestone: row.task) }
        TaskContextMenu(task: row.task)
    }

    private func edgeHandle(_ part: TimelineDrag.Part) -> some View {
        Color.clear
            .frame(width: 8)
            .contentShape(Rectangle())
            #if os(macOS)
            .onContinuousHover { phase in
                switch phase {
                case .active: NSCursor.resizeLeftRight.set()
                case .ended: NSCursor.arrow.set()
                }
            }
            #endif
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named(Self.space))
                .onChanged { v in
                    drag = TimelineDrag(part: part, anchor: row.task.id, ids: [row.task.id], dx: v.translation.width)
                }
                .onEnded { _ in finish() })
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if drag?.anchor == row.task.id, drag?.part == .body {
                    drag?.dx = v.translation.width
                } else {
                    drag = TimelineDrag(part: .body, anchor: row.task.id, ids: dragIds(), dx: v.translation.width)
                }
            }
            .onEnded { _ in finish() }
    }

    private func finish() {
        guard let d = drag else { return }
        drag = nil
        commit(d)
    }
}

/// Click selects (⌘/⇧ to add), double-click opens details.
private struct BarTaps: ViewModifier {
    let model: AppModel
    let id: UUID
    let order: [UUID]
    func body(content: Content) -> some View {
        content
            .onTapGesture(count: 2) { model.openDetails(id) }
            .simultaneousGesture(TapGesture().onEnded { model.click(id, in: order) })
    }
}

/// Wrapping chips for unscheduled tasks: drag one onto the calendar, or double-click to set dates.
private struct FlowChips: View {
    @Environment(AppModel.self) private var model
    let tasks: [TaskItem]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: WSSpace.xs)], alignment: .leading, spacing: WSSpace.xs) {
            ForEach(tasks) { t in
                HStack(spacing: 5) {
                    Circle().fill(ContainerColor(named: model.color(for: t)).accent).frame(width: 6, height: 6)
                    Text(t.title).font(.system(size: 12)).lineLimit(1)
                    if let tag = model.tagStyle(t.categoryId) { TagPill(tag, compact: true) }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).strokeBorder(WSColor.hairline))
                .contentShape(Rectangle())
                .taskInteractions(t, order: tasks.map(\.id))
            }
        }
    }
}

// MARK: - Board

private struct ProjectBoardView: View {
    @Environment(AppModel.self) private var model
    let projectId: UUID
    let columns: [BoardColumn]
    let tasks: [TaskItem]
    let milestones: [TaskItem]

    @State private var dropTarget: UUID?
    @State private var renaming: BoardColumn?
    @State private var renameText = ""

    /// Which column a task shows in: its own, else the first column for its status.
    private func column(for t: TaskItem) -> UUID? {
        let status: TaskStatus = t.status == .cancelled ? .done : t.status
        // Its own column, as long as the column still matches its status (checking a card
        // off elsewhere sends it to Done).
        if let id = t.boardColumnId, let c = columns.first(where: { $0.id == id }), c.mapsToStatus == status { return id }
        return (columns.first { $0.mapsToStatus == status } ?? columns.first)?.id
    }

    var body: some View {
        let grouped = Dictionary(grouping: tasks) { column(for: $0) }
        let milestoneNames = Dictionary(uniqueKeysWithValues: milestones.map { ($0.id, $0.title) })
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: WSSpace.m) {
                ForEach(columns) { col in
                    let cards = (grouped[col.id] ?? []).sorted { a, b in
                        (a.boardRank ?? a.sortRank) < (b.boardRank ?? b.sortRank)
                    }
                    columnView(col, cards: cards, milestoneNames: milestoneNames)
                }
                Button {
                    model.addBoardColumn(to: projectId)
                } label: {
                    Label("Add column", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 140, height: 32)
                        .overlay(RoundedRectangle(cornerRadius: WSRadius.block)
                            .strokeBorder(WSColor.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
                .buttonStyle(.plain)
                .foregroundStyle(WSColor.textSecondary)
            }
            .padding(.bottom, WSSpace.s)
        }
        .alert("Rename Column", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { if let c = renaming { model.renameBoardColumn(c.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func columnView(_ col: BoardColumn, cards: [TaskItem], milestoneNames: [UUID: String]) -> some View {
        VStack(alignment: .leading, spacing: WSSpace.xs) {
            HStack(spacing: 6) {
                Circle().fill(statusColor(col.mapsToStatus)).frame(width: 7, height: 7)
                Text(col.name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(WSColor.textPrimary)
                Text("\(cards.count)").font(.system(size: 11)).foregroundStyle(WSColor.textTertiary)
                Spacer()
                Menu {
                    Button("Rename…") { renameText = col.name; renaming = col }
                    Menu("Counts as") {
                        ForEach([TaskStatus.notStarted, .inProgress, .done], id: \.self) { s in
                            Button { model.setColumnStatus(col.id, s) } label: {
                                if col.mapsToStatus == s { Label(statusName(s), systemImage: "checkmark") } else { Text(statusName(s)) }
                            }
                        }
                    }
                    Divider()
                    Button("Delete Column", role: .destructive) { model.deleteBoardColumn(col.id) }
                } label: {
                    Image(systemName: "ellipsis").frame(width: 18, height: 16)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .foregroundStyle(WSColor.textTertiary)
            }
            .padding(.horizontal, 4)

            ForEach(cards) { t in
                BoardCard(task: t, milestone: t.milestoneId.flatMap { milestoneNames[$0] }, order: cards.map(\.id))
            }
            Button {
                model.quickAdd = QuickAddRequest(presetContainer: projectId)
            } label: {
                Label("New", systemImage: "plus").font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6).padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(WSColor.textTertiary)
            Spacer(minLength: 0)
        }
        .padding(WSSpace.s)
        .frame(width: 250)
        .frame(minHeight: 200, alignment: .top)
        .background(RoundedRectangle(cornerRadius: WSRadius.block + 2)
            .fill(dropTarget == col.id ? WSColor.hairline : WSColor.weekend))
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(draggedTaskId) else { return false }
            model.moveTasks(model.targets(for: id), toColumn: col)
            return true
        } isTargeted: { on in
            if on { dropTarget = col.id } else if dropTarget == col.id { dropTarget = nil }
        }
    }

    private func statusName(_ s: TaskStatus) -> String {
        switch s {
        case .notStarted: "Not started"
        case .inProgress: "In progress"
        case .done: "Done"
        case .cancelled: "Cancelled"
        }
    }

    private func statusColor(_ s: TaskStatus) -> Color {
        switch s {
        case .notStarted: WSColor.textTertiary
        case .inProgress: Color(hex: 0xD6A740)
        case .done, .cancelled: Color(hex: 0x4FA66A)
        }
    }
}

private struct BoardCard: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    let milestone: String?
    var order: [UUID] = []

    var body: some View {
        let today = LocalDate(Date())
        let done = task.status == .done
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                TaskCheckbox(isDone: done, color: ContainerColor(named: model.color(for: task))) { model.toggleDone(task) }
                Text(task.title)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(done ? WSColor.textTertiary : WSColor.textPrimary)
                    .strikethrough(done)
                    .lineLimit(3)
                Spacer(minLength: 0)
                if model.isStarred(task) {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color(hex: 0xD6A740))
                }
            }
            let due = WSFormat.due(task, today: today)
            if model.tagStyle(task.categoryId) != nil || due != nil || milestone != nil {
                HStack(spacing: 6) {
                    if let tag = model.tagStyle(task.categoryId) { TagPill(tag) }
                    if let due {
                        Label(due, systemImage: "flag").labelStyle(.titleAndIcon)
                            .foregroundStyle((task.dueDate.map { $0 < today } ?? false) && !done ? WSColor.now : WSColor.textSecondary)
                    }
                    if let milestone {
                        Label(milestone, systemImage: "diamond").labelStyle(.titleAndIcon).lineLimit(1)
                            .foregroundStyle(WSColor.textTertiary)
                    }
                }
                .font(.system(size: 10.5))
                .imageScale(.small)
            }
        }
        .padding(WSSpace.s)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WSRadius.block).fill(WSColor.raised))
        .overlay(RoundedRectangle(cornerRadius: WSRadius.block)
            .strokeBorder(model.isSelected(task.id) ? WSColor.textPrimary.opacity(0.7) : WSColor.hairline))
        .contentShape(Rectangle())
        .taskInteractions(task, order: order)
    }
}

/// Color submenu for a milestone ("Project color" resets it).
struct MilestoneColorMenu: View {
    @Environment(AppModel.self) private var model
    let milestone: TaskItem

    var body: some View {
        Menu("Color") {
            Button {
                model.setMilestoneColor(milestone.id, nil)
            } label: {
                Label { Text("Project color") } icon: {
                    ColorSwatchImage.image(for: ContainerColor(named: model.container(milestone.containerId)?.color ?? "grey"))
                }
            }
            Divider()
            ForEach(ContainerColor.allCases) { c in
                Button { model.setMilestoneColor(milestone.id, c.rawValue) } label: {
                    Label { Text(c.displayName + (milestone.color == c.rawValue ? "  ✓" : "")) } icon: { ColorSwatchImage.image(for: c) }
                }
            }
        }
    }
}
