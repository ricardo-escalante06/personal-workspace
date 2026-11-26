import Foundation
import SwiftUI
import GRDB
import Network
import Observation
import WorkspaceKit
import WorkspaceRemote
import WorkspaceUI

/// App-wide state: the local store, the (optional) Supabase backend, and sync status.
/// The UI reads from the local store only; sync runs in the background.
@MainActor
@Observable
final class AppModel {
    enum SyncStatus: Equatable {
        case localOnly          // built without Supabase credentials
        case signedOut
        case idle
        case syncing
        case synced(Date)
        case failed(String)
    }

    let store: WorkspaceStore
    let backend: SupabaseBackend?
    private var engine: SyncEngine?

    // Automatic sync (see startAutoSync)
    private var scheduler: SyncScheduler?
    private var changeFeed: ChangeFeed?
    private var timerTask: Task<Void, Never>?
    private let pathMonitor = NWPathMonitor()
    private var networkWasDown = false
    /// How often to pull even if Realtime is quiet (missed events, dropped socket).
    private let safetyNetInterval: Duration = .seconds(120)

    private(set) var containers: [Container] = []
    private(set) var tree: [ContainerNode] = []
    /// O(1) lookups; rebuilt whenever containers change (used per block/row while drawing).
    @ObservationIgnored private var containerById: [UUID: Container] = [:]
    /// "School › CS61B" for every container, for pickers.
    private(set) var locationLabels: [UUID: String] = [:]
    /// Task-holding containers in tree order, for "Location" pickers.
    private(set) var taskHolders: [Container] = []
    private(set) var userId: UUID?
    private(set) var syncStatus: SyncStatus
    private(set) var pendingChanges = 0
    /// Open tasks with no list (Inbox).
    private(set) var inboxCount = 0
    /// What the sidebar has selected. Never nil in practice: it falls back to All Workspace.
    var selection: SidebarItem? = .allWorkspace {
        // Clicking empty sidebar space clears the selection; treat that as All Workspace.
        didSet { if selection == nil { selection = .allWorkspace } }
    }

    /// The dashboard scope for the current selection (nil = All Workspace).
    var selectedScope: UUID? {
        if case .container(let id) = selection { return id }
        return nil
    }

    // Calendar page
    let calendarSource = CalendarSource()
    var calendarMode: CalendarMode = .week
    /// Any date inside the visible day/week/month.
    var calendarAnchor = LocalDate(Date())
    /// nil = everything; otherwise a container's subtree (+ events mapped into it).
    var calendarScope: UUID?

    /// A drag of a Google/system event waiting for confirmation ("This updates Google Calendar").
    var pendingEventMove: PendingEventMove?
    var pendingEventDelete: [ExternalEvent] = []
    var pendingEventEdit: PendingEventEdit?
    /// "Email guests about this change?" waiting for Send / Don't Send.
    var pendingGuestNotice: PendingGuestNotice?
    /// Calendar items copied with ⌘C.
    var calendarClipboard: [CalendarItem] = []
    /// Event moves/deletes that are saving (or waiting on "This / Following / All").
    enum EventOverride: Hashable { case moved(Date, Date), deleted, edited(EventChanges) }
    var eventOverrides: [String: EventOverride] = [:]
    /// New events shown right away while Google/Apple saves them.
    var pendingEventCreates: [String: ExternalEvent] = [:]
    /// Account the "New Calendar" prompt is open for.
    var newCalendarAccount: String?
    var pendingCalendarDelete: CalendarSource.CalendarInfo?

    /// "Open in Calendar" from a dashboard: same week, same scope.
    func openCalendar(scope: UUID?, weekStart: LocalDate) {
        calendarScope = scope
        let today = LocalDate(Date())
        let containsToday = (0..<7).contains(weekStart.daysUntil(today))
        calendarAnchor = weekAnchor(for: containsToday ? today : weekStart)
        calendarMode = .week
        selection = .calendar
    }
    var errorMessage: String?
    /// A one-off informational message (shown as an alert).
    var notice: String?

    // Dashboard / editing state
    private(set) var categories: [TaskCategory] = []
    var showTagManager = false
    /// Tag whose rename prompt is open.
    var renamingTag: TaskCategory?
    /// Class whose assignment-series sheet is open (and the series being edited, if any).
    var seriesEditor: SeriesEditorRequest?
    /// Task shown in the inspector (the last one clicked).
    var selectedTaskId: UUID? {
        didSet {
            if selectedTaskId != nil { inspectedEvent = nil }
            // Setting it directly (new task, palette…) makes it the whole selection.
            if let id = selectedTaskId {
                if !selectedTaskIds.contains(id) { selectedTaskIds = [id] }
            } else if !selectedTaskIds.isEmpty {
                selectedTaskIds = []
            }
        }
    }
    /// Every selected task (⌘-click / ⇧-click add to it). Always contains `selectedTaskId`.
    var selectedTaskIds: Set<UUID> = []
    /// Where a ⇧-click range starts.
    @ObservationIgnored private var selectionAnchor: UUID?
    /// Calendar event shown in the inspector (instead of a task).
    var inspectedEvent: ExternalEvent?
    /// Which window you're working in (the main one, or the calendar's own window):
    /// dialogs, sheets and the details panel follow it.
    enum WindowKind { case main, calendar }
    var activeWindow: WindowKind = .main
    var showMainInspector = false
    /// iPhone: the calendar list with show/hide switches.
    var showCalendarPicker = false
    /// What's left in Today (iPhone tab badge).
    var todayLeft = 0
    /// Main window's left sidebar (⌘I).
    var sidebarVisibility: NavigationSplitViewVisibility = .all

    func toggleSidebar() {
        withAnimation(.smooth(duration: 0.32)) {
            sidebarVisibility = sidebarVisibility == .detailOnly ? .all : .detailOnly
        }
    }
    var showCalendarInspector = false
    /// The details panel of the window you're in.
    var showInspector: Bool {
        get { activeWindow == .calendar ? showCalendarInspector : showMainInspector }
        set { if activeWindow == .calendar { showCalendarInspector = newValue } else { showMainInspector = newValue } }
    }
    /// The window's undo manager (set by RootView) so ⌘Z / Edit › Undo covers task actions.
    @ObservationIgnored weak var undoManager: UndoManager?
    /// The week shown by the dashboard week strip (shared across scopes).
    var weekStart: LocalDate = Dashboard.weekStart(containing: LocalDate(Date()))
    /// Non-nil while the quick-add sheet is open.
    var quickAdd: QuickAddRequest?
    var showPalette = false
    /// Non-nil while the create/edit container sheet is open.
    var containerEditor: ContainerEditorRequest?
    /// "Completed HW 9 · Undo" toast.
    private(set) var toast: Toast?

    init() {
        do {
            store = try SharedStore.open()
        } catch {
            fatalError("Could not open the local database: \(error)")
        }
        if let config = BackendConfig.fromInfoPlist() {
            let backend = SupabaseBackend(config: config)
            self.backend = backend
            engine = SyncEngine(database: store.db, remote: backend.remote)
            syncStatus = .signedOut
        } else {
            backend = nil
            syncStatus = .localOnly
        }
        // Debug aid: `open Workspace.app --args --sample-data` seeds an empty workspace.
        if ProcessInfo.processInfo.arguments.contains("--sample-data"),
           (try? store.containers().isEmpty) == true {
            loadSampleData()
        }
        // Debug aid: `--calendar` opens on the Calendar page.
        if ProcessInfo.processInfo.arguments.contains("--calendar") { selection = .calendar }
        try? store.ensureBuiltInCategories()
        try? store.pruneOrphanedRecords()
        convertImportedRepeats()
        observe()
        NotificationScheduler.shared.start(model: self)
        #if os(iOS)
        watchCalendarForWidget()
        #endif
        Task { await restoreSession() }
    }

    // MARK: Observation

    private func observe() {
        let containerObservation = ValueObservation.tracking { db in
            try Container.live().order(Column("sort_rank")).fetchAll(db)
        }
        Task { [weak self] in
            guard let db = self?.store.db else { return }
            do {
                for try await containers in containerObservation.values(in: db) {
                    self?.applyContainers(containers)
                }
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }

        let categoryObservation = ValueObservation.tracking { db in
            try TaskCategory.live().order(Column("name")).fetchAll(db)
        }
        Task { [weak self] in
            guard let db = self?.store.db else { return }
            for try await categories in categoryObservation.values(in: db) {
                self?.categories = categories
            }
        }

        let inboxObservation = ValueObservation.tracking { db in
            try TaskItem.live()
                .filter(Column("container_id") == nil)
                .filter(Column("parent_task_id") == nil)
                .filter(![TaskStatus.done.rawValue, TaskStatus.cancelled.rawValue].contains(Column("status")))
                .fetchCount(db)
        }
        Task { [weak self] in
            guard let db = self?.store.db else { return }
            for try await count in inboxObservation.values(in: db) {
                self?.inboxCount = count
            }
        }

        syncHiddenCalendars()

        let outboxObservation = ValueObservation.tracking { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sync_outbox") ?? 0
        }
        Task { [weak self] in
            guard let db = self?.store.db else { return }
            for try await count in outboxObservation.values(in: db) {
                self?.pendingChanges = count
                // Local edits queue rows in the outbox; upload them shortly after.
                if count > 0 { await self?.scheduler?.request(.localChange) }
            }
        }
    }

    private struct HiddenSets: Equatable {
        var calendars: Set<String>
        var accounts: Set<String>
        var everSaved: Bool
    }

    /// Hidden calendars live in the synced store, so hiding one on the Mac hides it on
    /// the iPhone. The first time, this device's existing choices seed the store.
    private func syncHiddenCalendars() {
        let source = calendarSource
        if (try? store.hasHiddenCalendarHistory()) == false,
           !source.hiddenCalendarIds.isEmpty || !source.hiddenAccounts.isEmpty {
            try? store.setHiddenCalendars(calendars: source.hiddenCalendarIds, accounts: source.hiddenAccounts)
        }
        source.onHiddenChange = { [weak self, weak source] in
            guard let self, let source else { return }
            try? self.store.setHiddenCalendars(calendars: source.hiddenCalendarIds, accounts: source.hiddenAccounts)
        }
        let observation = ValueObservation.tracking { (db: Database) -> HiddenSets in
            let sets = try WorkspaceStore.hiddenCalendars(db)
            let everSaved = try HiddenCalendar.fetchCount(db) > 0
            return HiddenSets(calendars: sets.calendars, accounts: sets.accounts, everSaved: everSaved)
        }
        Task { [weak self] in
            guard let db = self?.store.db else { return }
            for try await hidden in observation.values(in: db) {
                // Before any device has saved a choice, keep this device's own.
                guard hidden.everSaved else { continue }
                self?.calendarSource.applySyncedHidden(calendars: hidden.calendars, accounts: hidden.accounts)
            }
        }
    }

    func container(_ id: UUID?) -> Container? {
        id.flatMap { containerById[$0] }
    }

    private func applyContainers(_ list: [Container]) {
        let byId = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        containerById = byId
        var labels: [UUID: String] = [:]
        for c in list {
            labels[c.id] = c.path.split(separator: "/")
                .compactMap { UUID(uuidString: String($0)).flatMap { byId[$0]?.name } }
                .joined(separator: " › ")
        }
        locationLabels = labels
        containers = list
        tree = ContainerTree.build(list)
        taskHolders = containersInSidebarOrder.filter { $0.kind.holdsTasks }
        // Siri learns list names ("add a task to CS61A in Workspace").
        WorkspaceShortcuts.updateAppShortcutParameters()
    }

    // MARK: Auth

    private func restoreSession() async {
        guard let backend else { return }
        if let id = await backend.currentUserId() {
            await signedIn(as: id)
        }
    }

    func signInWithApple(idToken: String, nonce: String) async {
        guard let backend else { return }
        do {
            let id = try await backend.signInWithApple(idToken: idToken, nonce: nonce)
            await signedIn(as: id)
        } catch {
            errorMessage = "Sign in failed: \(error.localizedDescription)"
        }
    }

    private func signedIn(as id: UUID) async {
        userId = id
        syncStatus = .idle
        await startAutoSync(ownerId: id)
        await scheduler?.request(.manual)
    }

    func signOut() async {
        await stopAutoSync()
        try? await backend?.signOut()
        userId = nil
        syncStatus = backend == nil ? .localOnly : .signedOut
    }

    // MARK: Automatic sync
    //
    // Sync runs on its own; the toolbar button only forces an immediate run.
    //  - local edit        → outbox observation → sync after ~1.5s (bursts batched)
    //  - edit elsewhere    → Supabase Realtime event → pull within ~1.5s
    //  - app activated, network restored, every 2 min → safety-net sync
    //  - failure           → retried with backoff (2s, 4s, … 2 min)

    private func startAutoSync(ownerId: UUID) async {
        await stopAutoSync()
        guard let engine, let backend else { return }

        let scheduler = SyncScheduler(
            operation: { try await engine.sync(ownerId: ownerId) },
            observer: { [weak self] event in await self?.apply(event) }
        )
        self.scheduler = scheduler

        do {
            changeFeed = try await backend.startChangeFeed {
                await scheduler.request(.remoteChange)
            }
        } catch {
            // Not fatal: the timer and app-activation triggers still keep data fresh.
            print("Realtime unavailable: \(error)")
        }

        let interval = safetyNetInterval
        timerTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                await scheduler.request(.timer)
            }
        }

        // @Sendable: NWPathMonitor calls this on its own queue; hop to the main actor inside.
        pathMonitor.pathUpdateHandler = { @Sendable [weak self] path in
            let isUp = path.status == .satisfied
            Task { @MainActor in self?.networkChanged(isUp: isUp) }
        }
        if pathMonitor.queue == nil {
            pathMonitor.start(queue: DispatchQueue(label: "workspace.network"))
        }
    }

    private func stopAutoSync() async {
        timerTask?.cancel()
        timerTask = nil
        await scheduler?.stop()
        scheduler = nil
        await changeFeed?.cancel()
        changeFeed = nil
    }

    private func networkChanged(isUp: Bool) {
        if isUp, networkWasDown {
            Task { await scheduler?.request(.networkRestored) }
        }
        networkWasDown = !isUp
    }

    /// Call when the app/window comes to the foreground.
    func appBecameActive() {
        calendarSource.refresh()
        // The widgets and Siri write to the same file from other processes; tell this
        // process's screens to re-read.
        try? store.db.write { db in
            try db.notifyChanges(in: Table("tasks"))
            try db.notifyChanges(in: Table("task_occurrence_overrides"))
            try db.notifyChanges(in: Table("sync_outbox"))
        }
        Task { await scheduler?.request(.appActive) }
    }

    /// Toolbar button / ⇧⌘R: sync immediately.
    func syncNow() async {
        calendarSource.refresh()
        await scheduler?.request(.manual)
    }

    private func apply(_ event: SyncScheduler.Event) {
        switch event {
        case .started:
            syncStatus = .syncing
        case .finished(let report):
            syncStatus = .synced(report.finishedAt)
        case .failed(let message, let retryIn):
            let seconds = Int(retryIn.components.seconds)
            syncStatus = .failed("\(message) Retrying in \(seconds)s.")
        }
    }

    // MARK: Commands

    func loadSampleData() {
        perform { try SampleData.install(into: store) }
    }

    func container(for task: TaskItem) -> Container? {
        container(task.containerId)
    }

    func color(for task: TaskItem) -> String {
        container(task.containerId)?.color ?? "grey"
    }

    func category(_ id: UUID?) -> TaskCategory? {
        guard let id else { return nil }
        return categories.first { $0.id == id }
    }

    /// The tag pill for a task (nil when untagged).
    func tagStyle(_ categoryId: UUID?) -> TagStyle? {
        category(categoryId).map(TagStyle.init)
    }

    /// Starred by hand, or tagged with an auto-star tag (Exam).
    func isStarred(_ task: TaskItem) -> Bool {
        task.isStarred || category(task.categoryId)?.autoStar == true
    }

    // Tags

    func toggleStar(_ task: TaskItem) {
        editTask(task.id) { $0.isStarred.toggle() }
    }

    func setTagColor(_ id: UUID, _ color: String) {
        perform { try store.update(TaskCategory.self, id) { $0.color = color } }
    }

    func renameTag(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        perform { try store.update(TaskCategory.self, id) { $0.name = name } }
    }

    func setAutoStar(_ id: UUID, _ on: Bool) {
        perform { try store.update(TaskCategory.self, id) { $0.autoStar = on } }
    }

    func deleteTag(_ id: UUID) {
        perform { try store.deleteTag(id) }
    }

    /// Tag picker "New Tag…": creates (or finds) the tag and applies it.
    func applyNewTag(_ name: String, to taskId: UUID) {
        undoable("Change Tag", [taskId]) {
            let tag = try store.tag(named: name)
            try store.editTask(taskId) { $0.categoryId = tag.id }
        }
    }

    // Containers

    /// Opens the create sheet (name, kind, color).
    func createContainer(_ kind: ContainerKind, under parent: UUID?) {
        containerEditor = ContainerEditorRequest(mode: .create(kind: kind, parentId: parent))
    }

    func editContainer(_ container: Container) {
        containerEditor = ContainerEditorRequest(mode: .edit(container))
    }

    /// Saves the create/edit sheet. Returns false (and shows the error) on failure.
    @discardableResult
    func saveContainer(_ request: ContainerEditorRequest, name: String, kind: ContainerKind, color: String,
                       classSetup: ClassSetup? = nil) -> Bool {
        do {
            switch request.mode {
            case .create(_, let parentId):
                let created = try store.createContainer(name: name, kind: kind, parentId: parentId, color: color)
                if kind == .project { try ensureProjectExtras(created.id) }
                if let classSetup { try applyClassSetup(classSetup, to: created.id) }
                selection = .container(created.id)
            case .edit(let original):
                if name != original.name { try store.renameContainer(original.id, to: name) }
                if color != original.color { try store.setColor(original.id, color) }
                if kind != original.kind {
                    try store.changeKind(original.id, to: kind)
                    if kind == .project { try ensureProjectExtras(original.id) }
                }
                if let classSetup { try applyClassSetup(classSetup, to: original.id) }
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func rename(_ id: UUID, to name: String) {
        perform { try store.renameContainer(id, to: name) }
    }

    func setColor(_ id: UUID, _ color: ContainerColorName) {
        perform { try store.setColor(id, color) }
    }

    func changeKind(_ id: UUID, to kind: ContainerKind) {
        perform {
            try store.changeKind(id, to: kind)
            if kind == .project { try ensureProjectExtras(id) }
        }
    }

    enum DropPlacement { case before, inside, after }

    /// Sidebar drag-and-drop: place `id` before/after `target` (same parent), or inside it.
    @discardableResult
    func placeContainer(_ id: UUID, relativeTo target: Container, _ placement: DropPlacement) -> Bool {
        guard id != target.id else { return false }
        do {
            switch placement {
            case .inside:
                try store.reorderContainer(id, parent: target.id, before: nil)
            case .before:
                try store.reorderContainer(id, parent: target.parentId, before: target.id)
            case .after:
                let siblings = containersInSidebarOrder.filter { $0.parentId == target.parentId && $0.id != id }
                let next = siblings.firstIndex { $0.id == target.id }.flatMap { i in
                    i + 1 < siblings.count ? siblings[i + 1].id : nil
                }
                try store.reorderContainer(id, parent: target.parentId, before: next)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Drop of a sidebar row onto another row: becomes its last child when allowed.
    func dropContainer(_ id: UUID, onto target: UUID?) -> Bool {
        guard id != target else { return false }
        do {
            try store.reorderContainer(id, parent: target, before: nil)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ containerId: UUID) {
        perform {
            try store.deleteContainer(containerId)
            if selection == .container(containerId) { selection = .allWorkspace }
        }
    }

    /// Project views: make sure the board has columns (projects made before Milestone 3).
    func ensureBoard(_ projectId: UUID) {
        perform { try ensureProjectExtras(projectId) }
    }

    func createMilestone(_ title: String, in projectId: UUID) {
        let title = title.trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return }
        undoableCreating("New Milestone") {
            let m = try store.addTask(title: title, containerId: projectId)
            try store.editTask(m.id) { $0.isMilestone = true }
            return [m.id]
        }
    }

    /// A milestone's color (nil = the project's). Its tasks follow it on the timeline.
    func setMilestoneColor(_ id: UUID, _ color: String?) {
        editTasks([id], "Change Color") { $0.color = color }
    }

    func addBoardColumn(to projectId: UUID) {
        perform {
            try store.db.write { db in
                let last = try String.fetchOne(db, BoardColumn.live()
                    .filter(Column("container_id") == projectId).select(max(Column("sort_rank"))))
                var col = BoardColumn(containerId: projectId, name: "New column", mapsToStatus: .inProgress,
                                      sortRank: Rank.between(last, nil))
                try WorkspaceStore.save(&col, in: db)
            }
        }
    }

    func renameBoardColumn(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        perform { try store.update(BoardColumn.self, id) { $0.name = name } }
    }

    func setColumnStatus(_ id: UUID, _ status: TaskStatus) {
        perform { try store.update(BoardColumn.self, id) { $0.mapsToStatus = status } }
    }

    /// Cards in a deleted column fall back to the first column for their status.
    func deleteBoardColumn(_ id: UUID) {
        perform { try store.update(BoardColumn.self, id) { $0.deletedAt = Date() } }
    }

    /// Drop on a board column: the card joins it (at the bottom) and takes its status.
    func moveTasks(_ taskIds: [UUID], toColumn column: BoardColumn) {
        undoable(taskIds.count == 1 ? "Move Card" : "Move \(taskIds.count) Cards", taskIds) {
            var last = try store.db.read { db in
                try String.fetchOne(db, TaskItem.live()
                    .filter(Column("board_column_id") == column.id).select(max(Column("board_rank"))))
            }
            for taskId in taskIds {
                let rank = Rank.between(last, nil)
                last = rank
                try store.editTask(taskId) { t in
                    guard t.containerId == column.containerId else { return }
                    t.boardColumnId = column.id
                    t.boardRank = rank
                    t.status = column.mapsToStatus
                }
            }
        }
    }

    private func ensureProjectExtras(_ id: UUID) throws {
        try store.db.write { db in
            if try ProjectMeta.live().filter(Column("container_id") == id).fetchCount(db) == 0 {
                var meta = ProjectMeta(containerId: id)
                try WorkspaceStore.save(&meta, in: db)
            }
            if try BoardColumn.live().filter(Column("container_id") == id).fetchCount(db) == 0 {
                for ((name, status), rank) in zip(BoardColumn.defaultColumns, Rank.sequence(count: BoardColumn.defaultColumns.count)) {
                    var col = BoardColumn(containerId: id, name: name, mapsToStatus: status, sortRank: rank)
                    try WorkspaceStore.save(&col, in: db)
                }
            }
        }
    }

    // Tasks

    func toggleDone(_ task: TaskItem) {
        let newStatus: TaskStatus = task.status == .done ? .notStarted : .done
        undoable(newStatus == .done ? "Complete “\(task.title)”" : "Reopen “\(task.title)”", [task.id]) {
            try store.setStatus(task.id, newStatus)
        }
        if newStatus == .done {
            showToast(Toast(message: "Completed “\(task.title)”", undo: { [weak self] in
                self?.undoManager?.undo()
            }))
        }
    }

    /// Today's checkbox: a row that's only here for a work session checks off the
    /// session (the task stays open for its due day); anything due today completes the task.
    func toggleToday(_ item: TodayItem) {
        guard item.isSessionOnly, item.task.status != .done else { return toggleDone(item.task) }
        let done = !item.sessionDone
        let ids = item.blocks.map(\.id)
        undoable(done ? "Finish Work Session" : "Reopen Work Session", [item.task.id]) {
            try store.setScheduleBlocksDone(ids, done)
        }
        if done {
            showToast(Toast(message: "Session done · “\(item.task.title)” stays open", undo: { [weak self] in
                self?.undoManager?.undo()
            }))
        }
    }

    // MARK: Undo

    @ObservationIgnored private var lastUndo: (key: String, at: Date)?

    /// Runs `work` as one ⌘Z step: the tasks in `ids` (with their subtasks and work
    /// blocks) go back to how they were. `work` returns the ids of tasks it created,
    /// which undo removes. Edits with the same `coalesce` key in quick succession
    /// (typing a title) share one step.
    func undoableCreating(_ name: String, _ ids: [UUID] = [], coalesce: String? = nil, _ work: () throws -> [UUID]) {
        let before = try? store.snapshot(ids)
        do {
            let created = try work()
            guard var before, let undoManager else { return }
            if let coalesce, let last = lastUndo, last.key == coalesce, Date().timeIntervalSince(last.at) < 2,
               undoManager.undoActionName == name {
                lastUndo = (coalesce, Date())
                return
            }
            lastUndo = coalesce.map { ($0, Date()) }
            for id in created where before.tasks[id] == nil { before.tasks[id] = .some(nil) }
            registerRestore(before, name: name)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func undoable(_ name: String, _ ids: [UUID], coalesce: String? = nil, _ work: () throws -> Void) {
        undoableCreating(name, ids, coalesce: coalesce) { try work(); return [] }
    }

    /// Undo puts `snapshot` back and registers the reverse (that's redo).
    private func registerRestore(_ snapshot: TaskSnapshot, name: String) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                guard let current = try? model.store.snapshot(snapshot.taskIds) else { return }
                model.perform { try model.store.restore(snapshot) }
                model.lastUndo = nil
                model.registerRestore(current, name: name)
            }
        }
        undoManager?.setActionName(name)
    }

    // MARK: Selection

    /// Single click: select just this task. The details panel follows it if open.
    func select(_ taskId: UUID?) {
        selectedTaskIds = taskId.map { [$0] } ?? []
        selectedTaskId = taskId
        selectionAnchor = taskId
    }

    /// A click on a task row. ⌘-click adds/removes it; ⇧-click selects the range
    /// from the last click within `order` (the list it was clicked in).
    func click(_ taskId: UUID, in order: [UUID]) {
        let mods = Platform.modifierFlags
        if mods.contains(.command) {
            if selectedTaskIds.contains(taskId) {
                selectedTaskIds.remove(taskId)
                selectedTaskId = selectedTaskId == taskId ? selectedTaskIds.first : selectedTaskId
            } else {
                selectedTaskIds.insert(taskId)
                selectedTaskId = taskId
            }
            selectionAnchor = taskId
        } else if mods.contains(.shift) {
            if let anchor = selectionAnchor, let a = order.firstIndex(of: anchor), let b = order.firstIndex(of: taskId) {
                selectedTaskIds.formUnion(order[min(a, b)...max(a, b)])
            } else {
                selectedTaskIds.insert(taskId)  // no list order here (week strip, cards): just add it
            }
            selectedTaskId = taskId
        } else {
            select(taskId)
        }
    }

    func isSelected(_ taskId: UUID) -> Bool { selectedTaskIds.contains(taskId) }

    /// What a right-click acts on: the whole selection if the task is part of it.
    func targets(for taskId: UUID) -> [UUID] {
        selectedTaskIds.count > 1 && selectedTaskIds.contains(taskId) ? Array(selectedTaskIds) : [taskId]
    }

    func clearSelection() { select(nil) }

    /// Double-click, ⌘O, palette: select and show the details panel.
    func openDetails(_ taskId: UUID) {
        selectedTaskId = taskId
        setInspector(visible: true)
    }

    /// Animated show/hide for the details panel.
    func setInspector(visible: Bool) {
        guard showInspector != visible else { return }
        withAnimation(.smooth(duration: 0.32)) { showInspector = visible }
    }

    func toggleInspector() {
        setInspector(visible: !showInspector)
    }

    /// `typing`: a text field edit; keystrokes in a row become one undo step.
    func editTask(_ id: UUID, typing field: String? = nil, _ change: (inout TaskItem) -> Void) {
        undoable(field.map { "Edit \($0)" } ?? "Edit Task", [id], coalesce: field.map { "\($0)-\(id)" }) {
            try store.editTask(id, change)
        }
    }

    /// The same change to several tasks, as one undo step.
    func editTasks(_ ids: [UUID], _ name: String, _ change: (inout TaskItem) -> Void) {
        guard ids.count > 1 else {
            if let id = ids.first { undoable(name, [id]) { try store.editTask(id, change) } }
            return
        }
        undoable(name, ids) {
            for id in ids { try store.editTask(id, change) }
        }
    }

    /// Done / not done for several tasks.
    func setDone(_ ids: [UUID], _ done: Bool) {
        let n = ids.count
        undoable(done ? "Complete \(n == 1 ? "Task" : "\(n) Tasks")" : "Reopen \(n == 1 ? "Task" : "\(n) Tasks")", ids) {
            for id in ids { try store.setStatus(id, done ? .done : .notStarted) }
        }
    }

    func deleteTask(_ id: UUID) { deleteTasks([id]) }

    func deleteTasks(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        let title = ids.count == 1
            ? "“\((try? store.db.read { try TaskItem.fetchOne($0, id: OccurrenceRegistry.shared.resolve(ids[0])?.series ?? ids[0]) })?.title ?? "Task")”"
            : "\(ids.count) Tasks"
        // Deleting an occurrence of a repeating task skips just that one.
        let allOccurrences = ids.allSatisfy { OccurrenceRegistry.shared.resolve($0) != nil }
        undoable("\(allOccurrences ? "Skip" : "Delete") \(title)", ids) {
            for id in ids { try store.deleteTask(id) }
        }
        if selectedTaskIds.contains(where: ids.contains) { clearSelection() }
        if ids.count > 1 || allOccurrences {
            let what = allOccurrences ? (ids.count == 1 ? "Skipped \(title)" : "Skipped \(ids.count)") : "Deleted \(ids.count) tasks"
            showToast(Toast(message: what, undo: { [weak self] in self?.undoManager?.undo() }))
        }
    }

    /// A week-strip chip was dropped on another day.
    func moveChip(_ chipId: String, to day: LocalDate) {
        let parts = chipId.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return }
        var taskId = id
        if parts[0] == "block", let b = try? store.db.read({ try ScheduleBlock.fetchOne($0, id: id) }) { taskId = b.taskId }
        let ids = parts[0] == "due" ? targets(for: id) : [taskId]
        undoable(parts[0] == "due" ? "Change Due Date" : "Move Work Block", ids) {
            if parts[0] == "due" {
                for id in ids { try store.editTask(id) { $0.dueDate = day } }
            } else if parts[0] == "block",
                      let block = try store.db.read({ try ScheduleBlock.fetchOne($0, id: id) }) {
                // Keep the time of day; move to the new date.
                let tz = TimeZone.current
                let oldDay = LocalDate(block.startsAt, in: tz)
                let shift = day.startOfDay(in: tz).timeIntervalSince(oldDay.startOfDay(in: tz))
                try store.updateScheduleBlock(id, start: block.startsAt.addingTimeInterval(shift),
                                              end: block.endsAt.addingTimeInterval(shift))
            }
        }
    }

    /// Creates a task from parsed quick-add text.
    func createTask(from parsed: QuickAddParser.Result, defaultScope: UUID?,
                    milestoneId: UUID? = nil, startDate: LocalDate? = nil, asMilestone: Bool = false) {
        undoableCreating(asMilestone ? "New Milestone" : "New Task") {
            let destination: UUID?
            if let explicit = parsed.containerId {
                destination = explicit
            } else if let scope = defaultScope {
                destination = try store.quickAddDestination(for: scope)
            } else {
                destination = nil  // Inbox
            }
            var categoryId = parsed.categoryId
            if categoryId == nil, let newTag = parsed.newTagName {
                categoryId = try store.tag(named: newTag).id
            }
            let task = try store.addTask(
                title: parsed.title, containerId: destination, categoryId: categoryId,
                priority: parsed.priority, dueDate: parsed.dueDate, dueTime: parsed.dueTime
            )
            let makeMilestone = asMilestone && container(destination)?.kind == .project
            if milestoneId != nil || startDate != nil || makeMilestone {
                try store.editTask(task.id) { t in
                    if makeMilestone {
                        t.isMilestone = true
                    } else if let milestoneId, destination == defaultScope {
                        // Only keep the milestone if the task landed in the same project.
                        t.milestoneId = milestoneId
                    }
                    if let startDate { t.startDate = startDate }
                }
            }
            if let rule = parsed.repeatRule { try store.setRepeat(task.id, rule) }
            selectedTaskId = task.id
            return [task.id]
        }
    }

    func addSubtask(to parent: TaskItem, title: String) {
        undoable("Add Subtask", [parent.id]) { try store.addTask(title: title, containerId: parent.containerId, parentTaskId: parent.id) }
    }

    func addBlock(to task: TaskItem) {
        // Next full hour, one hour long.
        let cal = Calendar.current
        let start = cal.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
        undoable("Add Work Block", [task.id]) { try store.addScheduleBlock(taskId: task.id, start: start, end: start.addingTimeInterval(3600)) }
    }

    // Calendar

    /// Shows an event in the details panel.
    func inspect(_ event: ExternalEvent, open: Bool) {
        selectedTaskId = nil
        inspectedEvent = event
        if open { setInspector(visible: true) }
    }

    func updateEvent(_ event: ExternalEvent, start: Date, end: Date) {
        requestEventMoves([.init(event: event, start: start, end: end)])
    }

    /// Event panel edits. Repeating events ask "Only This Event / All Events" first.
    func updateEvent(_ event: ExternalEvent, _ changes: EventChanges) {
        guard !changes.isEmpty else { return }
        if event.isRecurring {
            pendingEventEdit = PendingEventEdit(event: event, changes: changes)
        } else {
            editAfterAskingGuests(event, changes, wholeSeries: false)
        }
    }

    func confirmEventEdit(wholeSeries: Bool) {
        guard let p = pendingEventEdit else { return }
        pendingEventEdit = nil
        editAfterAskingGuests(p.event, p.changes, wholeSeries: wholeSeries)
    }

    private func editAfterAskingGuests(_ event: ExternalEvent, _ changes: EventChanges, wholeSeries: Bool) {
        askGuests([event], about: changes.concernsGuests, cancel: { [weak self] in
            // Put the panel back to what's saved.
            if self?.inspectedEvent?.key == event.key { self?.inspectedEvent = event }
        }) { [weak self] notify in
            self?.commitEventEdit(event, changes, wholeSeries: wholeSeries, notify: notify)
        }
    }

    // MARK: Guest emails

    enum GuestEmails: String, CaseIterable, Identifiable {
        case ask, always, never
        var id: String { rawValue }
        var label: String {
            switch self {
            case .ask: "Ask each time"
            case .always: "Always send"
            case .never: "Never send"
            }
        }
    }

    /// Whether Google emails guests when you change an event you organize.
    var guestEmails: GuestEmails {
        get { GuestEmails(rawValue: UserDefaults.standard.string(forKey: "guestEmails") ?? "") ?? .ask }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "guestEmails") }
    }

    /// Runs `commit(notify)` once it's known whether to email guests: asks when one of
    /// `events` has guests (and you organize it) and the change matters to them.
    private func askGuests(_ events: [ExternalEvent], about relevant: Bool = true,
                           cancel: @escaping () -> Void, _ commit: @escaping (Bool) -> Void) {
        let withGuests = events.filter(\.hasGuestsToNotify)
        guard relevant, !withGuests.isEmpty else { return commit(false) }
        switch guestEmails {
        case .always: commit(true)
        case .never: commit(false)
        case .ask:
            let guests = Set(withGuests.flatMap { $0.attendees.filter { !$0.isSelf }.map(\.email) }).count
            let notice = PendingGuestNotice(guestCount: guests, send: commit, cancel: cancel)
            // Wait for any dialog that led here to finish closing, or this one won't show.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(300))
                self.pendingGuestNotice = notice
            }
        }
    }

    func answerGuestNotice(_ send: Bool?) {
        guard let n = pendingGuestNotice else { return }
        pendingGuestNotice = nil
        if let send { n.send(send) } else { n.cancel() }
    }

    /// Shows the edit at once; if saving to the calendar fails, the old values come back.
    private func commitEventEdit(_ event: ExternalEvent, _ changes: EventChanges, wholeSeries: Bool, notify: Bool) {
        if case .edited(var pending) = eventOverrides[event.key] {
            // Several quick edits to one event: show them all.
            if let t = changes.title { pending.title = t }
            if let l = changes.location { pending.location = l }
            if let n = changes.notes { pending.notes = n }
            if let c = changes.colorId { pending.colorId = c }
            if let b = changes.isBusy { pending.isBusy = b }
            if let r = changes.reminders { pending.reminders = r }
            if changes.removeMeet { pending.removeMeet = true }
            eventOverrides[event.key] = .edited(pending)
        } else if eventOverrides[event.key] == nil {
            eventOverrides[event.key] = .edited(changes)
        }
        // The side panel holds its own copy of the event: show the change there too.
        if let shown = inspectedEvent, shown.key == event.key, let updated = applyingOverrides([shown]).last {
            inspectedEvent = updated
        }
        let source = calendarSource
        Task {
            do {
                try await source.update(event, changes, wholeSeries: wholeSeries, notify: notify)
                try? await Task.sleep(for: .seconds(2))
            } catch GoogleAuth.AuthError.cancelled {
            } catch {
                errorMessage = "Couldn't save that change to your calendar, so it was undone. \(error.localizedDescription)"
                if inspectedEvent?.key == event.key { inspectedEvent = event }
            }
            if case .edited = eventOverrides[event.key] { eventOverrides[event.key] = nil }
        }
    }

    /// Yes / No / Maybe on a Google invitation.
    /// `note` goes to the organizer with the reply ("" clears it, nil leaves it).
    func respond(_ event: ExternalEvent, _ response: EventAttendee.Response, note: String? = nil) {
        runCalendar { try await $0.respond(event, response, note: note) }
    }

    func createCalendar(named name: String, in account: String) {
        runCalendar { try await $0.createCalendar(named: name, inAccount: account) }
    }

    func deleteCalendar(_ info: CalendarSource.CalendarInfo) {
        pendingCalendarDelete = nil
        runCalendar { try await $0.deleteCalendar(info) }
    }

    func connectGoogle() {
        runCalendar { try await $0.connectGoogle() }
    }

    /// Runs an async calendar write and surfaces errors (cancelled sign-ins stay quiet).
    func runCalendar(_ work: @escaping (CalendarSource) async throws -> Void) {
        let source = calendarSource
        Task {
            do { try await work(source) }
            catch GoogleAuth.AuthError.cancelled {}
            catch { errorMessage = error.localizedDescription }
        }
    }

    func setHidden(_ id: UUID, _ hidden: Bool) {
        perform { try store.setHidden(id, hidden) }
    }

    func createTaskWithBlock(title: String, containerId: UUID?, start: Date, end: Date) {
        undoableCreating("New Task") {
            let task = try store.addTask(title: title, containerId: containerId)
            try store.addScheduleBlock(taskId: task.id, start: start, end: end)
            selectedTaskId = task.id
            return [task.id]
        }
    }

    func createEvent(title: String, start: Date, end: Date, calendarId: String?) {
        Task { await createEventsInstantly([NewEventSpec(title: title, start: start, end: end, calendarId: calendarId)]) }
    }

    struct NewEventSpec {
        var title: String
        var start: Date
        var end: Date
        var calendarId: String?
        var location: String? = nil
        var notes: String? = nil
        /// Copy color, alerts, busy/free and all-day from this event.
        var template: ExternalEvent? = nil
    }

    /// Creates events the "instant" way: a stand-in shows immediately, the real event
    /// replaces it once saved, and if saving fails the stand-in goes away with a message.
    @discardableResult
    func createEventsInstantly(_ specs: [NewEventSpec]) async -> [CalendarSource.CreatedEvent] {
        let source = calendarSource
        var standIns: [String] = []
        for spec in specs {
            let calendarId = spec.calendarId ?? source.defaultCalendarId ?? ""
            let info = source.calendars.first { $0.id == calendarId }
            var e = ExternalEvent(key: "pending-\(UUID().uuidString)", localId: "", calendarId: calendarId,
                                  calendarTitle: info?.title ?? "", calendarColor: info?.color ?? 0x8A8A8A,
                                  title: spec.title, start: spec.start, end: spec.end,
                                  isAllDay: spec.template?.isAllDay ?? false, isWritable: false,
                                  location: spec.location, notes: spec.notes)
            e.eventColor = spec.template?.eventColor
            pendingEventCreates[e.key] = e
            standIns.append(e.key)
        }
        var created: [CalendarSource.CreatedEvent] = []
        do {
            for (spec, key) in zip(specs, standIns) {
                if let ref = try await source.create(title: spec.title, start: spec.start, end: spec.end,
                                                     calendarId: spec.calendarId, location: spec.location,
                                                     notes: spec.notes, copying: spec.template) {
                    created.append(ref)
                }
                // The real event is in the calendar's cache now; swap out the stand-in.
                pendingEventCreates[key] = nil
            }
        } catch GoogleAuth.AuthError.cancelled {
        } catch {
            errorMessage = "Couldn't add that to your calendar, so it was removed. \(error.localizedDescription)"
        }
        for key in standIns { pendingEventCreates[key] = nil }
        return created
    }

    /// Event drags and edits apply right away; only repeating events ask
    /// "Only This Event / All Events" first.
    func requestEventMoves(_ moves: [PendingEventMove.Move]) {
        // Show them where they were dropped right away (even while the question is up).
        for m in moves { eventOverrides[m.event.key] = .moved(m.start, m.end) }
        let pending = PendingEventMove(moves: moves)
        if pending.hasRepeating {
            pendingEventMove = pending
        } else {
            moveAfterAskingGuests(moves, scope: .one)
        }
    }

    func confirmEventMove(_ scope: EventEditScope) {
        guard let pending = pendingEventMove else { return }
        pendingEventMove = nil
        moveAfterAskingGuests(pending.moves, scope: scope)
    }

    private func moveAfterAskingGuests(_ moves: [PendingEventMove.Move], scope: EventEditScope) {
        askGuests(moves.map(\.event), cancel: { [weak self] in
            for m in moves { self?.eventOverrides[m.event.key] = nil }   // back where it was
        }) { [weak self] notify in
            self?.commitEventMoves(moves, scope: scope, notify: notify)
        }
    }

    func cancelEventMove() {
        for m in pendingEventMove?.moves ?? [] { eventOverrides[m.event.key] = nil }
        pendingEventMove = nil
    }

    private func commitEventMoves(_ moves: [PendingEventMove.Move], scope: EventEditScope, notify: Bool) {
        let keys = moves.map(\.event.key)
        let source = calendarSource
        Task {
            do {
                for m in moves { try await source.move(m.event, start: m.start, end: m.end, scope: scope, notify: notify) }
                // Let the calendar reload with the saved times before dropping the stand-ins.
                try? await Task.sleep(for: .seconds(2))
            } catch GoogleAuth.AuthError.cancelled {
            } catch {
                errorMessage = error.localizedDescription
            }
            for k in keys { eventOverrides[k] = nil }
        }
    }

    /// Deletes right away: gone from the screen at once, back if Google says no, and
    /// ⌘Z (or the toast's Undo) puts it back. Repeating events ask which ones first.
    func deleteEvents(_ events: [ExternalEvent]) {
        guard !events.isEmpty else { return }
        if events.contains(where: \.isRecurring) {
            pendingEventDelete = events
            return
        }
        pendingEventDelete = events
        confirmEventDelete(.one)
    }

    /// Undo for a delete: the events come back as new copies with the same settings.
    private func restoreDeletedEvents(_ events: [ExternalEvent]) {
        for e in events { eventOverrides[e.key] = nil }
        Task {
            await createEventsInstantly(events.map {
                NewEventSpec(title: $0.title, start: $0.start, end: $0.end, calendarId: $0.calendarId,
                             location: $0.location, notes: $0.notes, template: $0)
            })
        }
    }

    func confirmEventDelete(_ scope: EventEditScope = .one) {
        let events = pendingEventDelete
        pendingEventDelete = []
        // Gone from the screen at once, even while the guest question is up.
        for e in events { eventOverrides[e.key] = .deleted }
        askGuests(events, cancel: { [weak self] in
            for e in events { self?.eventOverrides[e.key] = nil }
        }) { [weak self] notify in
            self?.commitEventDelete(events, scope: scope, notify: notify)
        }
    }

    private func commitEventDelete(_ events: [ExternalEvent], scope: EventEditScope, notify: Bool) {
        if !events.contains(where: \.isRecurring) {
            // ⌘Z (or the toast's Undo) puts plain events back.
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated { model.restoreDeletedEvents(events) }
            }
            let name = events.count == 1 ? "“\(events[0].title)”" : "\(events.count) events"
            undoManager?.setActionName("Delete \(name)")
            showToast(Toast(message: "Deleted \(name)", undo: { [weak self] in self?.undoManager?.undo() }))
        }
        let source = calendarSource
        Task {
            do {
                for e in events { try await source.delete(e, scope: scope, notify: notify) }
                try? await Task.sleep(for: .seconds(2))
            } catch GoogleAuth.AuthError.cancelled {
            } catch {
                errorMessage = "Couldn't delete it in your calendar, so it's back. \(error.localizedDescription)"
            }
            for e in events { eventOverrides[e.key] = nil }
        }
        if let inspected = inspectedEvent, events.contains(where: { $0.key == inspected.key }) { inspectedEvent = nil }
    }

    /// Applies in-flight moves/deletes so the calendar doesn't jump back while saving.
    func applyingOverrides(_ events: [ExternalEvent]) -> [ExternalEvent] {
        guard !eventOverrides.isEmpty || !pendingEventCreates.isEmpty else { return events }
        return Array(pendingEventCreates.values) + events.compactMap { e in
            switch eventOverrides[e.key] {
            case nil: return e
            case .deleted: return nil
            case .moved(let start, let end):
                var e = e
                e.start = start
                e.end = end
                return e
            case .edited(let c):
                var e = e
                if let t = c.title { e.title = t }
                if let l = c.location { e.location = l }
                if let n = c.notes { e.notes = n }
                if let color = c.colorId { e.eventColor = color.flatMap(GoogleEventColors.hex) }
                if let b = c.isBusy { e.isBusy = b }
                if let r = c.reminders { e.reminders = r }
                if c.removeMeet || (e.customLinkSpot == .location && c.location != nil)
                    || (e.customLinkSpot == .notes && c.notes != nil) {
                    e.conferenceURL = nil; e.conferenceName = nil; e.customLinkSpot = nil
                }
                // A link just added as the location / description's first line.
                if e.conferenceURL == nil {
                    if let link = ConferenceLink.url(in: e.location) {
                        e.conferenceURL = link; e.customLinkSpot = .location
                    } else if e.provider == .google, let link = ConferenceLink.url(in: ConferenceLink.firstLine(of: e.notes)) {
                        e.conferenceURL = link; e.customLinkSpot = .notes
                    }
                    if let link = e.conferenceURL { e.conferenceName = ConferenceLink.name(for: link) }
                }
                return e
            }
        }
    }

    /// Delete key on the calendar: blocks are removed (⌘Z restores), deadlines lose their
    /// due date (⌘Z restores), events are confirmed first.
    func deleteCalendarItems(_ items: [CalendarItem]) {
        var events: [ExternalEvent] = []
        var blockIds: [UUID] = []
        var blockTaskIds: [UUID] = []
        var clearedDeadlines: [(UUID, LocalDate?, LocalTime?)] = []
        var clearedStarts: [UUID] = []
        for item in items {
            switch item.source {
            case .block(let taskId, let blockId):
                blockIds.append(blockId)
                blockTaskIds.append(taskId)
            case .deadline(let taskId):
                let t = try? store.db.read { try TaskItem.fetchOne($0, id: taskId) }
                clearedDeadlines.append((taskId, t?.dueDate, t?.dueTime))
            case .span(let taskId):
                clearedStarts.append(taskId)   // the span goes; the task and its due date stay
            case .event(let e):
                // Your own events, or (for Google) invites on a calendar you can write to:
                // deleting an invite removes it from your calendar.
                let calendarWritable = calendarSource.writableCalendars.contains { $0.id == e.calendarId }
                if e.isWritable || (e.provider == .google && calendarWritable) { events.append(e) }
            }
        }
        if !blockIds.isEmpty || !clearedDeadlines.isEmpty || !clearedStarts.isEmpty {
            let name = !blockIds.isEmpty ? "Delete Work Block" : (clearedDeadlines.isEmpty ? "Clear Start Date" : "Clear Due Date")
            undoable(name, blockTaskIds + clearedDeadlines.map(\.0) + clearedStarts) {
                for id in blockIds { try store.deleteScheduleBlock(id) }
                for (taskId, _, _) in clearedDeadlines { try store.editTask(taskId) { $0.dueDate = nil } }
                for taskId in clearedStarts { try store.editTask(taskId) { $0.startDate = nil } }
            }
        }
        if !events.isEmpty { deleteEvents(events) }
    }

    /// ⌘V on the calendar: a copy of each block (same task) and event (same calendar,
    /// title, place and notes), moved by `shift` (0 = in the same spot). Returns the new
    /// blocks' calendar ids so they can be selected. ⌘Z removes them all.
    @discardableResult
    func pasteCalendarItems(_ items: [CalendarItem], shift: TimeInterval) -> [String] {
        let blocks = items.compactMap { item -> (UUID, Date, Date)? in
            if case .block(let taskId, _) = item.source { return (taskId, item.start + shift, item.end + shift) }
            return nil
        }
        var newIds: [String] = []
        if !blocks.isEmpty {
            undoable(blocks.count == 1 ? "Paste Work Block" : "Paste \(blocks.count) Work Blocks", blocks.map(\.0)) {
                for (taskId, start, end) in blocks {
                    let b = try store.addScheduleBlock(taskId: taskId, start: start, end: end)
                    newIds.append("block-\(b.id)")
                }
            }
        }
        let events = items.compactMap { item -> (ExternalEvent, Date, Date)? in
            if case .event(let e) = item.source { return (e, item.start + shift, item.end + shift) }
            return nil
        }
        if !events.isEmpty {
            let writable = Set(calendarSource.writableCalendars.map(\.id))
            let specs = events.map { e, start, end in
                NewEventSpec(title: e.title, start: start, end: end,
                             calendarId: writable.contains(e.calendarId) ? e.calendarId : nil,
                             location: e.location, notes: e.notes, template: e)
            }
            Task {
                let created = await createEventsInstantly(specs)
                guard !created.isEmpty else { return }
                registerEventPasteUndo(created, items: items, shift: shift)
            }
        }
        return newIds
    }

    /// ⌘Z after pasting events deletes them; ⌘⇧Z pastes them again.
    private func registerEventPasteUndo(_ created: [CalendarSource.CreatedEvent], items: [CalendarItem], shift: TimeInterval) {
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                let source = model.calendarSource
                model.runCalendar { _ in for ref in created { try await source.delete(ref) } }
                model.undoManager?.registerUndo(withTarget: model) { m in
                    MainActor.assumeIsolated { m.pasteCalendarItems(items, shift: shift) }
                }
                model.undoManager?.setActionName("Paste Event")
            }
        }
        undoManager?.setActionName(created.count == 1 ? "Paste Event" : "Paste \(created.count) Events")
    }

    /// Move/resize a work block (calendar drag, inspector), undoable.
    func updateBlock(_ blockId: UUID, start: Date, end: Date, coalesce: Bool = false) {
        guard let block = try? store.db.read({ try ScheduleBlock.fetchOne($0, id: blockId) }) else { return }
        undoable("Move Work Block", [block.taskId], coalesce: coalesce ? "block-\(blockId)" : nil) {
            try store.updateScheduleBlock(blockId, start: start, end: end)
        }
    }

    func deleteBlock(_ blockId: UUID) {
        guard let block = try? store.db.read({ try ScheduleBlock.fetchOne($0, id: blockId) }) else { return }
        undoable("Delete Work Block", [block.taskId]) { try store.deleteScheduleBlock(blockId) }
    }

    func addBlock(to taskId: UUID, start: Date, end: Date) {
        undoable("Add Work Block", [taskId]) { try store.addScheduleBlock(taskId: taskId, start: start, end: end) }
        selectedTaskId = taskId
    }

    /// Manual "Assign to…": maps this event (by its stable key) to a container, or clears it.
    func assign(_ event: ExternalEvent, to containerId: UUID?) {
        perform {
            try store.db.write { db in
                let existing = try EventLink.live().filter(Column("external_event_key") == event.key).fetchAll(db)
                for var link in existing {
                    link.deletedAt = Date()
                    try WorkspaceStore.save(&link, in: db)
                }
                if let containerId {
                    var link = EventLink(externalEventKey: event.key, containerId: containerId)
                    try WorkspaceStore.save(&link, in: db)
                }
            }
        }
    }

    // Week navigation

    /// ⌘[ / ⌘]: moves the calendar when it's showing, otherwise the dashboard week.
    /// Week view's first column for a jump to `day`: the day itself when weeks start
    /// on today (the default, so the days ahead stay readable), else its Sunday.
    func weekAnchor(for day: LocalDate) -> LocalDate {
        let startsToday = UserDefaults.standard.object(forKey: "weekStartsToday") as? Bool ?? true
        return startsToday || CalendarMode.weekLength != 7 ? day : Dashboard.weekStart(containing: day)
    }

    func shiftWeek(_ weeks: Int) {
        if selection == .calendar {
            stepCalendar(weeks)
        } else {
            weekStart = weekStart.adding(days: 7 * weeks)
        }
    }

    /// ⌘T: today, on the calendar or the dashboard.
    func goToThisWeek() {
        let today = LocalDate(Date())
        if selection == .calendar {
            calendarAnchor = calendarMode == .week ? weekAnchor(for: today) : today
        } else {
            weekStart = Dashboard.weekStart(containing: today)
        }
    }

    /// One period back/forward in the current calendar mode.
    func stepCalendar(_ direction: Int) {
        switch calendarMode {
        case .day: calendarAnchor = calendarAnchor.adding(days: direction)
        case .week: calendarAnchor = calendarAnchor.adding(days: CalendarMode.weekLength * direction)
        case .month:
            var c = Calendar(identifier: .gregorian)
            c.timeZone = TimeZone(identifier: "UTC")!
            let d = c.date(byAdding: .month, value: direction, to: calendarAnchor.startOfDay(in: c.timeZone))!
            calendarAnchor = LocalDate(d, in: c.timeZone)
        }
    }

    /// Containers in sidebar order (depth-first by rank), for menus that mirror the sidebar.
    var containersInSidebarOrder: [Container] {
        var out: [Container] = []
        func walk(_ nodes: [ContainerNode]) {
            for n in nodes { out.append(n.container); walk(n.children) }
        }
        walk(tree)
        return out
    }

    // Toast

    private func showToast(_ toast: Toast) {
        self.toast = toast
        let id = toast.id
        Task {
            try? await Task.sleep(for: .seconds(4))
            if self.toast?.id == id { self.toast = nil }
        }
    }

    func undoToast() {
        toast?.undo()
        withAnimation(.smooth(duration: 0.2)) { toast = nil }
    }

    func perform(_ work: () throws -> Void) {
        do {
            try work()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Sidebar rows. "All Workspace" needs its own case: SwiftUI can't select a row
/// whose tag is nil, so it couldn't be re-selected after picking a container.
enum SidebarItem: Hashable {
    case allWorkspace
    case inbox
    case calendar
    case container(UUID)
}

enum CalendarMode: String, CaseIterable, Identifiable {
    case day = "Day", week = "Week", month = "Month"
    var id: String { rawValue }
    /// On iPhone "Week" is three days, so the columns stay readable.
    static var weekLength: Int { Platform.deviceName == "iPhone" ? 3 : 7 }
    var title: String { self == .week && Self.weekLength == 3 ? "3 Days" : rawValue }
}

typealias ContainerColorName = String

struct ContainerEditorRequest: Identifiable {
    enum Mode {
        case create(kind: ContainerKind, parentId: UUID?)
        case edit(Container)
    }
    let id = UUID()
    var mode: Mode
}

struct PendingGuestNotice: Identifiable {
    let id = UUID()
    var guestCount: Int
    var send: (Bool) -> Void
    var cancel: () -> Void
}

struct PendingEventEdit: Identifiable {
    let id = UUID()
    var event: ExternalEvent
    var changes: EventChanges
}

struct QuickAddRequest: Identifiable {
    let id = UUID()
    /// Prefilled due date (from double-clicking a week-strip day).
    var presetDue: LocalDate?
    /// Where the task goes unless the text names a container (project views).
    var presetContainer: UUID?
    /// Project milestone the new task joins.
    var presetMilestone: UUID?
    var presetStart: LocalDate?
}

struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var undo: () -> Void
}

