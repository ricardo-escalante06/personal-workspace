import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// The scoped dashboard (DESIGN.md §4.2). The same view serves All Workspace,
/// folders, lists, classes and projects; only the scope changes.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    let scope: UUID?

    @State private var data: DashboardData

    /// Loads the first snapshot synchronously so switching scopes never shows an
    /// empty dashboard for a frame; the observation below keeps it live afterwards.
    init(scope: UUID?, store: WorkspaceStore, weekStart: LocalDate) {
        self.scope = scope
        let initial = (try? store.db.read { try Dashboard.fetch($0, scope: scope, weekStart: weekStart) }) ?? .empty
        _data = State(initialValue: initial)
    }
    @State private var categoryFilter: UUID?? = nil   // nil = All, .some(nil) = Uncategorized
    @State private var showCompleted = false
    @State private var showOverdue = true

    private var today: LocalDate { LocalDate(Date()) }
    private var scopeContainer: Container? { model.container(scope) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: WSSpace.xl) {
                header
                if data.tasks.isEmpty && children.isEmpty {
                    emptyState
                } else {
                    WeekStripView(
                        days: data.week,
                        today: today,
                        selectedTaskIds: model.selectedTaskIds,
                        colorFor: { ContainerColor(named: model.color(for: $0)) },
                        tagFor: { model.tagStyle($0.categoryId) },
                        actions: .init(
                            previousWeek: { model.shiftWeek(-1) },
                            nextWeek: { model.shiftWeek(1) },
                            thisWeek: { model.goToThisWeek() },
                            openCalendar: { model.openCalendar(scope: scope, weekStart: model.weekStart) },
                            selectTask: { model.click($0, in: []) },
                            openTask: { model.openDetails($0) },
                            toggleTask: { model.toggleDone($0) },
                            addOnDay: { model.quickAdd = QuickAddRequest(presetDue: $0) },
                            moveChip: { model.moveChip($0, to: $1) }
                        )
                    )
                    todayAndUpcoming
                    // The full task list belongs to task-holding views (lists, classes, projects).
                    // All Workspace and folders show what's inside them instead.
                    if scopeContainer?.kind == .project, let scope {
                        ProjectViews(projectId: scope, tasks: data.tasks)
                    } else if scopeContainer?.kind.holdsTasks == true {
                        taskList
                    }
                    if !children.isEmpty { childrenSection }
                }
            }
            .padding(.horizontal, WSSpace.xxl)
            .padding(.vertical, WSSpace.xl)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(WSColor.canvas)
        .task(id: ObservationKey(scope: scope, weekStart: model.weekStart)) {
            let scope = scope, weekStart = model.weekStart
            let observation = ValueObservation.tracking { db in
                try Dashboard.fetch(db, scope: scope, weekStart: weekStart)
            }
            do {
                for try await value in observation.values(in: model.store.db) {
                    data = value
                }
            } catch {}
        }
    }

    private struct ObservationKey: Hashable {
        var scope: UUID?
        var weekStart: LocalDate
    }

    // MARK: Header

    private var header: some View {
        let crumbs = scope.map { ContainerTree.breadcrumb(for: $0, in: model.containers) } ?? []
        return VStack(alignment: .leading, spacing: WSSpace.s) {
            if crumbs.count > 1 {
                HStack(spacing: WSSpace.xs) {
                    ForEach(crumbs.dropLast()) { c in
                        Button(c.name) { model.selection = .container(c.id) }
                            .buttonStyle(.plain)
                        Image(systemName: "chevron.right").imageScale(.small)
                    }
                }
                .font(WSFont.metric)
                .foregroundStyle(WSColor.textSecondary)
            }
            HStack(alignment: .center, spacing: WSSpace.s + 2) {
                Image(systemName: scopeContainer?.kind.symbol ?? "square.grid.2x2")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(scopeContainer.map { ContainerColor(named: $0.color).accent } ?? WSColor.textSecondary)
                Text(scopeContainer?.name ?? "All Workspace")
                    .font(WSFont.pageTitle)
                    .foregroundStyle(WSColor.textPrimary)
                if let kind = scopeContainer?.kind {
                    Text(kind.displayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(WSColor.textTertiary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(Capsule().strokeBorder(WSColor.hairline))
                }
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
                .help("New task (⌘N)")
            }
            metricsLine
        }
    }

    private var metricsLine: some View {
        let m = data.metrics
        var parts: [String] = []
        if m.dueToday > 0 { parts.append("\(m.dueToday) due today") }
        if m.scheduledToday > 0 { parts.append("\(m.scheduledToday) scheduled today") }
        if m.overdue > 0 { parts.append("\(m.overdue) overdue") }
        parts.append("\(m.next7Days) in the next 7 days")
        if m.completedToday > 0 { parts.append("\(m.completedToday) done today") }
        return HStack(spacing: WSSpace.m) {
            Text(parts.joined(separator: " · "))
                .font(WSFont.metric)
                .foregroundStyle(WSColor.textSecondary)
            if !data.tasks.isEmpty {
                HStack(spacing: 6) {
                    ProgressBar(value: m.progress, color: scopeContainer.map { ContainerColor(named: $0.color) } ?? .grey)
                        .frame(width: 80, height: 4)
                    Text("\(Int((m.progress * 100).rounded()))%")
                        .font(WSFont.metric)
                        .foregroundStyle(WSColor.textTertiary)
                }
            }
        }
    }

    // MARK: Today + Upcoming

    private var todayAndUpcoming: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: WSSpace.xxl) {
                todayNotepad.frame(minWidth: 380, maxWidth: .infinity, alignment: .topLeading)
                dueSoonSection.frame(minWidth: 240, idealWidth: 300, maxWidth: 340, alignment: .topLeading)
            }
            VStack(alignment: .leading, spacing: WSSpace.xl) {
                todayNotepad
                dueSoonSection
            }
        }
    }

    /// Today as a ruled notepad: it's the one list you work through, so it gets its own look.
    private var todayNotepad: some View {
        let dateText = today.startOfDay(in: .current).formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        let openCount = data.today.filter { $0.task.status != .done }.count
        return Notepad(title: "Today", subtitle: openCount > 0 ? "\(dateText) · \(openCount) left" : dateText) {
            ForEach(data.today) { item in
                notepadRow(item.task,
                           trailing: item.blocks.first.map { WSFormat.range($0.startsAt, $0.endsAt) }
                               ?? (item.isDueToday ? (item.task.dueTime.map(WSFormat.time) ?? "due today") : nil))
            }
            if !data.overdue.isEmpty {
                HStack(spacing: 0) {
                    Color.clear.frame(width: NotepadMetrics.marginX)
                    Button {
                        withAnimation(.smooth(duration: 0.25)) { showOverdue.toggle() }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.right")
                                .rotationEffect(.degrees(showOverdue ? 90 : 0))
                                .imageScale(.small)
                            Text("Overdue (\(data.overdue.count))")
                        }
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(WSColor.now)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, WSSpace.s + 2)
                    Spacer()
                }
                .frame(height: NotepadMetrics.lineHeight)
                .overlay(alignment: .bottom) { Rectangle().fill(WSColor.paperRule).frame(height: 1) }
                if showOverdue {
                    ForEach(data.overdue) { task in
                        notepadRow(task, trailing: WSFormat.due(task, today: today), overdue: true)
                    }
                }
            }
            NotepadBlankLine(placeholder: data.today.isEmpty ? "Nothing yet — add something for today…" : "Add to today…") {
                model.quickAdd = QuickAddRequest(presetDue: today)
            }
            NotepadBlankLine()
        }
    }

    private func notepadRow(_ task: TaskItem, trailing: String?, overdue: Bool = false) -> some View {
        let order = data.today.map(\.task.id) + data.overdue.map(\.id)
        let container = model.container(for: task)
        let subtitle: String? = (container?.id == scope) ? nil : (container?.name ?? "Inbox")
        return NotepadRow(
            title: task.title,
            subtitle: subtitle,
            isDone: task.status == .done,
            ink: ContainerColor(named: container?.color ?? "grey"),
            isSelected: model.isSelected(task.id),
            onToggle: { model.toggleDone(task) }
        ) {
            if let tag = model.tagStyle(task.categoryId) { TagPill(tag) }
            if let trailing {
                Text(trailing).foregroundStyle(overdue ? WSColor.now : WSColor.textSecondary)
            }
        }
        .taskInteractions(task, order: order)
    }

    /// Deadlines only, two weeks out. Work blocks already show in the week strip.
    /// Starred first (with days left), then the rest by day.
    private var dueSoonSection: some View {
        let starredIds = Set(data.starred.map(\.id))
        let rest = data.dueSoon.filter { !starredIds.contains($0.id) }
        let groups = Dictionary(grouping: rest) { $0.dueDate! }.sorted { $0.key < $1.key }
        return VStack(alignment: .leading, spacing: WSSpace.xs) {
            SectionLabel("Due soon", trailing: "next 2 weeks")
                .padding(.bottom, WSSpace.xs)
                .padding(.top, 12)
            if !data.starred.isEmpty {
                VStack(spacing: WSSpace.xs) {
                    ForEach(data.starred) { task in
                        StarredCard(task: task, today: today)
                            .taskInteractions(task, order: data.starred.map(\.id))
                    }
                }
                .padding(.bottom, WSSpace.xs)
            }
            if groups.isEmpty && data.starred.isEmpty {
                Text("No deadlines in the next two weeks.")
                    .font(WSFont.body)
                    .foregroundStyle(WSColor.textTertiary)
                    .padding(.vertical, WSSpace.xs)
            }
            ForEach(groups, id: \.key) { date, tasks in
                VStack(alignment: .leading, spacing: 0) {
                    Text(WSFormat.relativeDay(date, today: today))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(WSColor.textTertiary)
                        .padding(.leading, WSSpace.s)
                        .padding(.top, WSSpace.xs)
                    ForEach(tasks) { task in
                        row(task, dueText: task.dueTime.map(WSFormat.time), order: groups.flatMap { $0.value.map(\.id) })
                    }
                }
            }
        }
    }

    // MARK: Task list

    private var presentCategories: [TaskCategory] {
        let ids = Set(data.tasks.compactMap(\.categoryId))
        return model.categories.filter { ids.contains($0.id) }
    }

    private var taskList: some View {
        let visible = data.tasks.filter { task in
            (showCompleted || task.status != .done)
                && (categoryFilter == nil || task.categoryId == categoryFilter!)
        }
        let groups = Dictionary(grouping: visible) { $0.categoryId }
            .sorted { a, b in
                // Named categories alphabetically, uncategorized last.
                switch (model.category(a.key)?.name, model.category(b.key)?.name) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                default: return false
                }
            }

        let listOrder = groups.flatMap { $0.value.sorted(by: taskOrder).map(\.id) }
        return VStack(alignment: .leading, spacing: WSSpace.s) {
            if scopeContainer?.kind == .class, let scope { SeriesStrip(classId: scope) }
            HStack {
                SectionLabel("Tasks", trailing: "\(data.tasks.filter { $0.status != .done }.count) open")
                Toggle("Show completed", isOn: $showCompleted)
                    .checkboxToggleStyle()
                    .font(.system(size: 12))
                    .foregroundStyle(WSColor.textSecondary)
            }
            if !presentCategories.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: WSSpace.xs) {
                        FilterChip(title: "All", isOn: categoryFilter == nil) { categoryFilter = nil }
                        ForEach(presentCategories) { c in
                            FilterChip(title: c.name, tag: TagStyle(c), isOn: categoryFilter == .some(c.id)) {
                                categoryFilter = categoryFilter == .some(c.id) ? nil : .some(c.id)
                            }
                            .contextMenu { TagMenu(tag: c) }
                        }
                    }
                }
            }
            if visible.isEmpty {
                Text(data.tasks.isEmpty ? "No tasks yet." : "Everything here is done.")
                    .font(WSFont.body)
                    .foregroundStyle(WSColor.textTertiary)
                    .padding(.vertical, WSSpace.xs)
            }
            ForEach(groups, id: \.key) { categoryId, tasks in
                VStack(alignment: .leading, spacing: 0) {
                    if groups.count > 1 || categoryId != nil {
                        HStack(spacing: 6) {
                            if let c = model.category(categoryId) {
                                Circle().fill(ContainerColor(named: c.color ?? "grey").accent).frame(width: 7, height: 7)
                            }
                            Text(model.category(categoryId)?.name ?? "No tag")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(WSColor.textSecondary)
                            Text("\(tasks.filter { $0.status != .done }.count)")
                                .font(.system(size: 11)).foregroundStyle(WSColor.textTertiary)
                        }
                        .padding(.top, WSSpace.s)
                        .padding(.bottom, 2)
                        .padding(.leading, WSSpace.s)
                    }
                    ForEach(tasks.sorted(by: taskOrder)) { task in
                        row(task, dueText: WSFormat.due(task, today: today), order: listOrder,
                            overdue: task.dueDate.map { $0 < today } ?? false)
                    }
                }
            }
        }
    }

    /// Open first; then by due date (no date last); then manual order.
    private func taskOrder(_ a: TaskItem, _ b: TaskItem) -> Bool {
        if (a.status == .done) != (b.status == .done) { return a.status != .done }
        switch (a.dueDate, b.dueDate) {
        case let (x?, y?) where x != y: return x < y
        case (_?, nil): return true
        case (nil, _?): return false
        default: return a.sortRank < b.sortRank
        }
    }

    // MARK: Children

    private var children: [Container] {
        model.containers
            .filter { $0.parentId == scope }
            .sorted { $0.sortRank < $1.sortRank }
    }

    private var childrenSection: some View {
        let paths = Dictionary(uniqueKeysWithValues: model.containers.map { ($0.id, $0.path) })
        return VStack(alignment: .leading, spacing: WSSpace.s) {
            SectionLabel(scope == nil ? "Areas" : "Inside \(scopeContainer?.name ?? "")")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: WSSpace.s)], spacing: WSSpace.s) {
                ForEach(children) { child in
                    let tasks = data.tasks.filter { t in t.containerId.flatMap { paths[$0] }?.hasPrefix(child.path) ?? false }
                    let open = tasks.filter { !$0.status.isClosed }
                    let next = open.compactMap(\.dueDate).min()
                    let done = tasks.filter { $0.status == .done }.count
                    ChildCard(
                        container: child,
                        openCount: open.count,
                        nextDue: next.map { WSFormat.relativeDay($0, today: today) },
                        progress: tasks.isEmpty ? nil : Double(done) / Double(tasks.count)
                    )
                    .onTapGesture { model.selection = .container(child.id) }
                }
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: WSSpace.m) {
            Text(scope == nil ? "Your workspace is empty." : "Nothing in \(scopeContainer?.name ?? "here") yet.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(WSColor.textSecondary)
            HStack(spacing: WSSpace.s) {
                Button("New Task  ⌘N") { model.quickAdd = QuickAddRequest() }
                if scope == nil, model.containers.isEmpty {
                    Button("Load sample data") { model.loadSampleData() }
                }
            }
        }
        .padding(.top, WSSpace.xl)
    }

    // MARK: Rows

    private func row(_ task: TaskItem, timeText: String? = nil, dueText: String? = nil, order: [UUID] = [],
                     overdue: Bool = false, showDueDateOnly: Bool = false) -> some View {
        let container = model.container(for: task)
        // In broader scopes, say where the task lives.
        let subtitle: String? = (container?.id == scope) ? nil : (container?.name ?? "Inbox")
        return TaskRowView(
            task: task,
            context: .init(
                color: ContainerColor(named: container?.color ?? "grey"),
                subtitle: subtitle,
                tag: model.tagStyle(task.categoryId),
                isStarred: model.isStarred(task),
                subtasks: data.subtaskProgress[task.id],
                timeText: timeText,
                dueText: dueText,
                isOverdue: overdue
            ),
            isSelected: model.isSelected(task.id),
            onToggle: { model.toggleDone(task) }
        )
        .taskInteractions(task, order: order)
    }
}

// MARK: - Small pieces

/// Right-click on a tag: color, auto-star, rename, delete.
struct TagMenu: View {
    @Environment(AppModel.self) private var model
    let tag: TaskCategory

    var body: some View {
        Menu("Color") {
            ForEach(ContainerColor.allCases) { c in
                Button { model.setTagColor(tag.id, c.rawValue) } label: {
                    Label { Text(c.displayName + (tag.color == c.rawValue ? "  ✓" : "")) } icon: { ColorSwatchImage.image(for: c) }
                }
            }
        }
        Toggle("Star Automatically", isOn: Binding(get: { tag.autoStar }, set: { model.setAutoStar(tag.id, $0) }))
        Button("Rename…") { model.renamingTag = tag }
        Button("Manage Tags…") { model.showTagManager = true }
        Divider()
        Button("Delete Tag", role: .destructive) { model.deleteTag(tag.id) }
    }
}

struct FilterChip: View {
    let title: String
    var tag: TagStyle?
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let tag { Circle().fill(tag.color.accent).frame(width: 7, height: 7) }
                Text(title)
            }
            .font(.system(size: 12, weight: isOn ? .semibold : .regular))
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(isOn ? WSColor.textPrimary : WSColor.textSecondary)
            .background(Capsule().fill(isOn ? WSColor.hairline : .clear))
            .overlay(Capsule().strokeBorder(WSColor.hairline))
        }
        .buttonStyle(.plain)
    }
}

struct ProgressBar: View {
    let value: Double
    let color: ContainerColor
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WSColor.hairline)
                Capsule().fill(color.accent).frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
    }
}

private struct ChildCard: View {
    let container: Container
    let openCount: Int
    let nextDue: String?
    let progress: Double?

    var body: some View {
        let color = ContainerColor(named: container.color)
        HStack(spacing: WSSpace.m) {
            Image(systemName: container.kind.symbol)
                .foregroundStyle(color.accent)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(container.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(WSColor.textPrimary)
                    .lineLimit(1)
                Text([openCount > 0 ? "\(openCount) open" : "All clear", nextDue.map { "next \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 11))
                    .foregroundStyle(WSColor.textTertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if let progress {
                ProgressBar(value: progress, color: color).frame(width: 36, height: 3)
            }
        }
        .padding(WSSpace.m)
        .background(RoundedRectangle(cornerRadius: WSRadius.block).fill(WSColor.weekend))
        .overlay(RoundedRectangle(cornerRadius: WSRadius.block).strokeBorder(WSColor.hairline))
        .contentShape(Rectangle())
    }
}

/// One starred item: what, where, when, and how far off.
private struct StarredCard: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    let today: LocalDate

    var body: some View {
        let container = model.container(for: task)
        let color = ContainerColor(named: container?.color ?? "grey")
        let days = task.dueDate.map { today.daysUntil($0) }
        HStack(alignment: .top, spacing: WSSpace.s) {
            RoundedRectangle(cornerRadius: 1.5).fill(color.accent).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(Color(hex: 0xD6A740))
                    Text(task.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(WSColor.textPrimary)
                        .lineLimit(1)
                    if let tag = model.tagStyle(task.categoryId) { TagPill(tag) }
                }
                HStack(spacing: 4) {
                    Text(container?.name ?? "Inbox")
                    if let due = task.dueDate {
                        Text("·")
                        Text(WSFormat.relativeDay(due, today: today) + (task.dueTime.map { " " + WSFormat.time($0) } ?? ""))
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(WSColor.textSecondary)
                .lineLimit(1)
            }
            Spacer(minLength: WSSpace.s)
            if let days {
                VStack(spacing: 0) {
                    Text(days <= 0 ? "Today" : "\(days)")
                        .font(.system(size: days <= 0 ? 12 : 17, weight: .semibold).monospacedDigit())
                    if days > 0 {
                        Text(days == 1 ? "day" : "days").font(.system(size: 9.5))
                    }
                }
                .foregroundStyle(days <= 3 ? WSColor.now : WSColor.textSecondary)
                .frame(minWidth: 34)
            }
        }
        .padding(.vertical, WSSpace.s).padding(.horizontal, WSSpace.s + 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: WSRadius.block).fill(WSColor.weekend))
        .overlay(RoundedRectangle(cornerRadius: WSRadius.block)
            .strokeBorder(model.isSelected(task.id) ? color.accent : WSColor.hairline))
        .contentShape(Rectangle())
    }
}
