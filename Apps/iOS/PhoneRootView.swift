import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// iPhone: Today · Calendar · Browse · Settings, with quick add on every tab.
/// The logic is the same WorkspaceKit the Mac uses; only the layout differs.
struct PhoneRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.undoManager) private var undoManager
    @State private var tab = PhoneTab.today

    enum PhoneTab: Hashable { case today, calendar, browse, settings }

    var body: some View {
        @Bindable var model = model
        TabView(selection: $tab) {
            Tab("Today", systemImage: "sun.max", value: .today) {
                NavigationStack { PhoneTodayView() }
            }
            Tab("Calendar", systemImage: "calendar", value: .calendar) {
                NavigationStack { CalendarView().toolbar(.hidden, for: .navigationBar) }
            }
            Tab("Browse", systemImage: "square.grid.2x2", value: .browse) {
                NavigationStack { PhoneBrowseView() }
            }
            Tab("Settings", systemImage: "gearshape", value: .settings) {
                NavigationStack { PhoneSettingsView() }
            }
        }
        .tint(WSColor.action)
        .sheet(item: $model.quickAdd) { request in
            QuickAddView(request: request, scope: request.presetContainer ?? model.selectedScope)
                .presentationDetents([.height(150), .medium])
        }
        .sheet(isPresented: $model.showInspector) {
            NavigationStack {
                Group {
                    if let event = model.inspectedEvent {
                        EventInspector(event: event)
                    } else if let id = model.selectedTaskId {
                        TaskInspector(taskId: id)
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.setInspector(visible: false) }
                    }
                }
            }
            .presentationDetents([.large])
        }
        .sheet(isPresented: $model.showTagManager) { NavigationStack { TagManagerView() } }
        .sheet(item: $model.seriesEditor) { request in AssignmentSeriesSheet(request: request) }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                HStack(spacing: WSSpace.m) {
                    Text(toast.message).lineLimit(1)
                    Button("Undo") { model.undoToast() }.fontWeight(.semibold)
                }
                .font(.system(size: 14))
                .padding(.horizontal, WSSpace.l).padding(.vertical, WSSpace.m)
                .background(Capsule().fill(WSColor.raised))
                .overlay(Capsule().strokeBorder(WSColor.hairline))
                .padding(.bottom, 64)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.smooth(duration: 0.25), value: model.toast?.id)
        .alert("Something went wrong", isPresented: .constant(model.errorMessage != nil)) {
            Button("OK") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
        .alert("Done", isPresented: .constant(model.notice != nil)) {
            Button("OK") { model.notice = nil }
        } message: {
            Text(model.notice ?? "")
        }
        .modifier(PhoneEventDialogs())
        .onOpenURL { url in
            if url.host == "today" { tab = .today }
            if url.host == "calendar" { tab = .calendar }
        }
        .onAppear { model.undoManager = undoManager }
        .onChange(of: undoManager) { _, m in model.undoManager = m }
    }
}

/// Round "+" in the bottom-right corner (thumb reach): quick add into `container`
/// when given, due `due` when given.
struct QuickAddButton: View {
    @Environment(AppModel.self) private var model
    var container: UUID? = nil
    var due: LocalDate? = nil

    var body: some View {
        FloatingAddButton {
            model.quickAdd = QuickAddRequest(presetDue: due, presetContainer: container)
        }
    }
}

struct FloatingAddButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "plus")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .background(Circle().fill(WSColor.action))
                .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
        }
        .accessibilityLabel("New")
        .padding(.trailing, 20)
        .padding(.bottom, 16)
    }
}

// MARK: - Rows

/// A tappable task row with swipe actions: check off (left), and on the right
/// Tomorrow and Delete (Skip for a repeating task).
struct PhoneTaskRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    var subtitle: String? = nil
    var trailing: String? = nil
    var overdue = false
    var showLocation = true
    /// Off in Today, where "due today" is a given.
    var showDue = true
    /// Today rows: checked state and checkbox action (a work session vs. the task).
    var isChecked: Bool? = nil
    var toggle: (() -> Void)? = nil

    var body: some View {
        let today = LocalDate(Date())
        let container = model.container(for: task)
        TaskRowView(
            task: task,
            context: .init(
                color: ContainerColor(named: container?.color ?? "grey"),
                subtitle: subtitle ?? (showLocation ? (container?.name ?? "Inbox") : nil),
                tag: model.tagStyle(task.categoryId),
                isStarred: model.isStarred(task),
                timeText: trailing,
                dueText: trailing == nil && showDue ? WSFormat.due(task, today: today) : nil,
                isOverdue: overdue || (task.dueDate.map { $0 < today } ?? false),
                isChecked: isChecked
            ),
            onToggle: toggle ?? { model.toggleDone(task) }
        )
        .contentShape(Rectangle())
        .onTapGesture { model.openDetails(task.id) }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button { (toggle ?? { model.toggleDone(task) })() } label: {
                Label((isChecked ?? (task.status == .done)) ? "Not Done" : "Done", systemImage: "checkmark")
            }
            .tint(ContainerColor.green.accent)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) { model.deleteTask(task.id) } label: {
                Label(task.isOccurrence ? "Skip" : "Delete", systemImage: task.isOccurrence ? "forward" : "trash")
            }
            Button { model.editTask(task.id) { $0.dueDate = today.adding(days: 1) } } label: {
                Label("Tomorrow", systemImage: "arrow.right.to.line")
            }
            .tint(ContainerColor.steel.accent)
        }
        .contextMenu { TaskContextMenu(task: task) }
        .listRowBackground(WSColor.canvas)
        .listRowSeparator(.hidden)
        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 12))
    }
}

/// Starred and due within two weeks: title, where, when, days left.
struct PhoneStarredRow: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem

    var body: some View {
        let today = LocalDate(Date())
        let container = model.container(for: task)
        let days = task.dueDate.map { today.daysUntil($0) } ?? 0
        HStack(spacing: WSSpace.m) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(ContainerColor(named: container?.color ?? "grey").accent)
                .frame(width: 3, height: 34)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: "star.fill").font(.system(size: 10)).foregroundStyle(Color(hex: 0xD6A740))
                    Text(task.title).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if let tag = model.tagStyle(task.categoryId) { TagPill(tag) }
                }
                Text([container?.name ?? "Inbox", task.dueDate.map { WSFormat.relativeDay($0, today: today) }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 12)).foregroundStyle(WSColor.textSecondary)
            }
            Spacer()
            VStack(spacing: 0) {
                Text(days <= 0 ? "Today" : "\(days)").font(.system(size: days <= 0 ? 13 : 20, weight: .semibold).monospacedDigit())
                if days > 0 { Text(days == 1 ? "day" : "days").font(.system(size: 10)) }
            }
            .foregroundStyle(days <= 3 ? WSColor.now : WSColor.textSecondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { model.openDetails(task.id) }
        .contextMenu { TaskContextMenu(task: task) }
        .listRowBackground(WSColor.raised)
    }
}

// MARK: - Today

struct PhoneTodayView: View {
    @Environment(AppModel.self) private var model
    @State private var data = DashboardData.empty
    @State private var showOverdue = true

    private var today: LocalDate { LocalDate(Date()) }

    var body: some View {
        let starredIds = Set(data.starred.map(\.id))
        let soon = Dictionary(grouping: data.dueSoon.filter { !starredIds.contains($0.id) }) { $0.dueDate! }
            .sorted { $0.key < $1.key }
        List {
            if !data.starred.isEmpty {
                Section("Starred") {
                    ForEach(data.starred) { PhoneStarredRow(task: $0) }
                }
            }
            Section {
                if data.today.isEmpty {
                    Text("Nothing due or planned today.").foregroundStyle(WSColor.textTertiary)
                        .listRowBackground(WSColor.canvas)
                }
                ForEach(data.today) { item in
                    PhoneTaskRow(task: item.task,
                                 trailing: WSFormat.todayDetail(item, today: today),
                                 overdue: item.isDueToday && !item.isChecked,
                                 showDue: false,
                                 isChecked: item.isChecked,
                                 toggle: { model.toggleToday(item) })
                }
            } header: {
                Text("Today · " + today.startOfDay(in: .current).formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))
            }
            if !data.overdue.isEmpty {
                Section {
                    if showOverdue {
                        ForEach(data.overdue) { PhoneTaskRow(task: $0, overdue: true) }
                    }
                } header: {
                    Button { withAnimation { showOverdue.toggle() } } label: {
                        HStack {
                            Text("Overdue (\(data.overdue.count))").foregroundStyle(WSColor.now)
                            Image(systemName: "chevron.right").rotationEffect(.degrees(showOverdue ? 90 : 0))
                                .font(.system(size: 10, weight: .semibold))
                        }
                    }
                }
            }
            ForEach(soon, id: \.key) { date, tasks in
                Section(WSFormat.relativeDay(date, today: today)) {
                    ForEach(tasks) { PhoneTaskRow(task: $0, trailing: $0.dueTime.map(WSFormat.time)) }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WSColor.canvas)
        .navigationTitle("Today")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { PhoneSyncBadge() }
        }
        .overlay(alignment: .bottomTrailing) { QuickAddButton(due: today) }
        .refreshable { await model.syncNow() }
        .task(id: today) {
            let weekStart = Dashboard.weekStart(containing: today)
            let observation = ValueObservation.tracking { db in
                try Dashboard.fetch(db, scope: nil, weekStart: weekStart)
            }
            do { for try await value in observation.values(in: model.store.db) { data = value } } catch {}
        }
    }
}

/// Small sync indicator for the navigation bar.
struct PhoneSyncBadge: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        switch model.syncStatus {
        case .syncing: ProgressView().controlSize(.small)
        case .failed: Image(systemName: "exclamationmark.icloud").foregroundStyle(WSColor.now)
        case .signedOut: Image(systemName: "icloud.slash").foregroundStyle(WSColor.textTertiary)
        default:
            if model.pendingChanges > 0 {
                Image(systemName: "arrow.triangle.2.circlepath.icloud").foregroundStyle(WSColor.textTertiary)
            } else {
                Image(systemName: "checkmark.icloud").foregroundStyle(WSColor.textTertiary)
            }
        }
    }
}

// MARK: - Browse

struct PhoneBrowseView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        List {
            Section {
                NavigationLink(value: PhoneDestination.inbox) {
                    HStack {
                        Label("Inbox", systemImage: "tray")
                        Spacer()
                        if model.inboxCount > 0 { Text("\(model.inboxCount)").foregroundStyle(WSColor.textTertiary) }
                    }
                }
                NavigationLink(value: PhoneDestination.container(nil)) {
                    Label("All Workspace", systemImage: "square.grid.2x2")
                }
            }
            .listRowBackground(WSColor.raised)
            Section("Workspace") {
                OutlineGroup(model.tree.filter { $0.container.archivedAt == nil }, children: \.childrenOrNil) { node in
                    NavigationLink(value: PhoneDestination.container(node.id)) {
                        Label {
                            Text(node.container.name)
                        } icon: {
                            Image(systemName: node.container.kind.symbol)
                                .foregroundStyle(ContainerColor(named: node.container.color).accent)
                        }
                    }
                }
            }
            .listRowBackground(WSColor.raised)
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(WSColor.canvas)
        .navigationTitle("Browse")
        .overlay(alignment: .bottomTrailing) { QuickAddButton() }
        .navigationDestination(for: PhoneDestination.self) { dest in
            switch dest {
            case .inbox: PhoneInboxView()
            case .container(let id): PhoneContainerView(scope: id)
            }
        }
    }
}

enum PhoneDestination: Hashable {
    case inbox
    case container(UUID?)
}

struct PhoneInboxView: View {
    @Environment(AppModel.self) private var model
    @State private var tasks: [TaskItem] = []

    var body: some View {
        List {
            if tasks.isEmpty {
                Text("Inbox zero.").foregroundStyle(WSColor.textTertiary).listRowBackground(WSColor.canvas)
            }
            ForEach(tasks) { PhoneTaskRow(task: $0, showLocation: false) }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(WSColor.canvas)
        .navigationTitle("Inbox")
        .overlay(alignment: .bottomTrailing) { QuickAddButton() }
        .task {
            let observation = ValueObservation.tracking { db in
                try TaskItem.live().filter(Column("container_id") == nil).filter(Column("parent_task_id") == nil)
                    .filter(![TaskStatus.done.rawValue, TaskStatus.cancelled.rawValue].contains(Column("status")))
                    .order(Column("sort_rank")).fetchAll(db)
            }
            do { for try await value in observation.values(in: model.store.db) { tasks = value } } catch {}
        }
    }
}

/// A folder, list, class or project on iPhone.
struct PhoneContainerView: View {
    @Environment(AppModel.self) private var model
    let scope: UUID?
    @State private var data = DashboardData.empty
    @State private var tagFilter: UUID?? = nil
    @State private var showCompleted = false
    @State private var projectMode = ProjectMode.list

    enum ProjectMode: String, CaseIterable { case list = "List", milestones = "Milestones", board = "Board" }

    private var container: Container? { model.container(scope) }
    private var today: LocalDate { LocalDate(Date()) }

    var body: some View {
        Group {
            if container?.kind == .project, projectMode == .board, let scope {
                PhoneBoardView(projectId: scope, tasks: data.tasks)
            } else {
                list
            }
        }
        .background(WSColor.canvas)
        .navigationTitle(container?.name ?? "All Workspace")
        .overlay(alignment: .bottomTrailing) {
            QuickAddButton(container: container?.kind.holdsTasks == true ? scope : nil)
        }
        .safeAreaInset(edge: .top) {
            if container?.kind == .project {
                Picker("View", selection: $projectMode) {
                    ForEach(ProjectMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 6)
                .background(WSColor.canvas)
            }
        }
        .task(id: scope) {
            let scope = scope
            let weekStart = Dashboard.weekStart(containing: LocalDate(Date()))
            let observation = ValueObservation.tracking { db in try Dashboard.fetch(db, scope: scope, weekStart: weekStart) }
            do { for try await value in observation.values(in: model.store.db) { data = value } } catch {}
        }
    }

    private var children: [Container] {
        model.containers.filter { $0.parentId == scope && $0.archivedAt == nil }.sorted { $0.sortRank < $1.sortRank }
    }

    private var visible: [TaskItem] {
        data.tasks.filter { t in
            (showCompleted || t.status != .done) && (tagFilter == nil || t.categoryId == tagFilter!)
        }
        .sorted { a, b in
            switch (a.dueDate, b.dueDate) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.sortRank < b.sortRank
            }
        }
    }

    private var list: some View {
        let tags = model.categories.filter { c in data.tasks.contains { $0.categoryId == c.id } }
        return List {
            if !children.isEmpty {
                Section(scope == nil ? "Areas" : "Inside") {
                    ForEach(children) { c in
                        NavigationLink(value: PhoneDestination.container(c.id)) {
                            Label { Text(c.name) } icon: {
                                Image(systemName: c.kind.symbol).foregroundStyle(ContainerColor(named: c.color).accent)
                            }
                        }
                    }
                }
                .listRowBackground(WSColor.raised)
            }
            if container?.kind == .class, let scope {
                Section { SeriesStrip(classId: scope).listRowBackground(WSColor.canvas) }
            }
            if !tags.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: WSSpace.xs) {
                        FilterChip(title: "All", isOn: tagFilter == nil) { tagFilter = nil }
                        ForEach(tags) { c in
                            FilterChip(title: c.name, tag: TagStyle(c), isOn: tagFilter == .some(c.id)) {
                                tagFilter = tagFilter == .some(c.id) ? nil : .some(c.id)
                            }
                        }
                    }
                }
                .listRowBackground(WSColor.canvas)
                .listRowInsets(EdgeInsets(top: 4, leading: 12, bottom: 4, trailing: 12))
            }
            if container?.kind == .project, projectMode == .milestones {
                milestoneSections
            } else {
                Section {
                    if visible.isEmpty {
                        Text(data.tasks.isEmpty ? "No tasks yet." : "All done here.")
                            .foregroundStyle(WSColor.textTertiary).listRowBackground(WSColor.canvas)
                    }
                    ForEach(visible) { PhoneTaskRow(task: $0, showLocation: container?.kind.holdsTasks != true) }
                } header: {
                    HStack {
                        Text("Tasks")
                        Spacer()
                        Button(showCompleted ? "Hide done" : "Show done") { showCompleted.toggle() }
                            .font(.caption)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    @ViewBuilder private var milestoneSections: some View {
        let milestones = data.tasks.filter(\.isMilestone)
        let ids = Set(milestones.map(\.id))
        ForEach(milestones) { m in
            let members = visible.filter { $0.milestoneId == m.id }
            Section {
                ForEach(members) { PhoneTaskRow(task: $0, showLocation: false) }
            } header: {
                HStack {
                    Image(systemName: "diamond.fill").font(.system(size: 9))
                    Text(m.title)
                    Spacer()
                    Text("\(data.tasks.filter { $0.milestoneId == m.id && $0.status == .done }.count)/\(data.tasks.filter { $0.milestoneId == m.id }.count)")
                }
            }
        }
        Section("No milestone") {
            ForEach(visible.filter { !$0.isMilestone && !($0.milestoneId.map(ids.contains) ?? false) }) {
                PhoneTaskRow(task: $0, showLocation: false)
            }
        }
    }
}

/// A project board on iPhone: one column per page; swipe between them.
struct PhoneBoardView: View {
    @Environment(AppModel.self) private var model
    let projectId: UUID
    let tasks: [TaskItem]
    @State private var columns: [BoardColumn] = []

    var body: some View {
        TabView {
            ForEach(columns) { col in
                let cards = cardsIn(col)
                List {
                    Section {
                        ForEach(cards) { t in
                            PhoneTaskRow(task: t, showLocation: false)
                                .contextMenu {
                                    ForEach(columns.filter { $0.id != col.id }) { other in
                                        Button("Move to \(other.name)") { model.moveTasks([t.id], toColumn: other) }
                                    }
                                }
                        }
                    } header: {
                        Text("\(col.name) · \(cards.count)")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollContentBackground(.hidden)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .task(id: projectId) {
            model.ensureBoard(projectId)
            let id = projectId
            let observation = ValueObservation.tracking { db in
                try BoardColumn.live().filter(Column("container_id") == id).order(Column("sort_rank")).fetchAll(db)
            }
            do { for try await value in observation.values(in: model.store.db) { columns = value } } catch {}
        }
    }

    /// Same rule as the Mac board: its column if that column's status matches, else by status.
    private func cardsIn(_ col: BoardColumn) -> [TaskItem] {
        tasks.filter { t in
            guard !t.isMilestone else { return false }
            if let cid = t.boardColumnId, let c = columns.first(where: { $0.id == cid }), c.mapsToStatus == t.status {
                return c.id == col.id
            }
            return columns.first(where: { $0.mapsToStatus == t.status })?.id == col.id
        }
    }
}

// MARK: - Settings

struct PhoneSettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Account") {
                AccountFooter()
                LabeledContent("Sync") {
                    Button {
                        Task { await model.syncNow() }
                    } label: {
                        HStack(spacing: 6) { PhoneSyncBadge(); Text("Sync now") }
                    }
                }
            }
            NotificationSettingsSection()
            Section("Tags") {
                Button("Manage Tags…") { model.showTagManager = true }
            }
            CalendarAccountsSections()
        }
        .navigationTitle("Settings")
    }
}

/// Repeating-event and delete confirmations on iPhone (the Mac has these in RootView).
private struct PhoneEventDialogs: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content
            .modifier(GuestNoticeDialog())
            .confirmationDialog(
                "Change this repeating event?",
                isPresented: Binding(get: { model.pendingEventEdit != nil }, set: { if !$0 { model.pendingEventEdit = nil } }),
                titleVisibility: .visible
            ) {
                Button("Only This Event") { model.confirmEventEdit(wholeSeries: false) }
                Button("All Events") { model.confirmEventEdit(wholeSeries: true) }
                Button("Cancel", role: .cancel) { model.pendingEventEdit = nil }
            }
            .confirmationDialog(
                model.pendingEventMove?.title ?? "Move event?",
                isPresented: Binding(get: { model.pendingEventMove != nil }, set: { if !$0 { model.cancelEventMove() } }),
                titleVisibility: .visible
            ) {
                Button("Only This Event") { model.confirmEventMove(.one) }
                Button("This and Following Events") { model.confirmEventMove(.following) }
                Button("All Events") { model.confirmEventMove(.all) }
                Button("Cancel", role: .cancel) { model.cancelEventMove() }
            }
            .confirmationDialog(
                "Delete event?",
                isPresented: Binding(get: { !model.pendingEventDelete.isEmpty }, set: { if !$0 { model.pendingEventDelete = [] } }),
                titleVisibility: .visible
            ) {
                if model.pendingEventDelete.contains(where: \.isRecurring) {
                    Button("Delete Only This Event", role: .destructive) { model.confirmEventDelete(.one) }
                    Button("Delete This and Following", role: .destructive) { model.confirmEventDelete(.following) }
                    Button("Delete All Events", role: .destructive) { model.confirmEventDelete(.all) }
                } else {
                    Button("Delete Event", role: .destructive) { model.confirmEventDelete() }
                }
            }
    }
}
