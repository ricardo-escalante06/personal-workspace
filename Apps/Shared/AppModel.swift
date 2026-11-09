import Foundation
import SwiftUI
import GRDB
import Network
import Observation
import WorkspaceKit
import WorkspaceRemote

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
    /// Account the "New Calendar" prompt is open for.
    var newCalendarAccount: String?
    var pendingCalendarDelete: CalendarSource.CalendarInfo?

    /// "Open in Calendar" from a dashboard: same week, same scope.
    func openCalendar(scope: UUID?, weekStart: LocalDate) {
        calendarScope = scope
        calendarAnchor = weekStart
        calendarMode = .week
        selection = .calendar
    }
    var errorMessage: String?

    // Dashboard / editing state
    private(set) var categories: [TaskCategory] = []
    /// Task shown in the inspector.
    var selectedTaskId: UUID? {
        didSet { if selectedTaskId != nil { inspectedEvent = nil } }
    }
    /// Calendar event shown in the inspector (instead of a task).
    var inspectedEvent: ExternalEvent?
    var showInspector = false
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
            store = try WorkspaceStore.onDisk(at: AppPaths.databaseURL)
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
        observe()
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
        categories.first { $0.id == id }
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
        setStatus(task.id, newStatus, previous: task.status, title: task.title)
        if newStatus == .done {
            showToast(Toast(message: "Completed “\(task.title)”", undo: { [weak self] in
                self?.undoManager?.undo()
            }))
        }
    }

    /// Changes status and registers the inverse with the undo manager (so redo works too).
    private func setStatus(_ id: UUID, _ status: TaskStatus, previous: TaskStatus, title: String) {
        perform { try store.setStatus(id, status) }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated {
                model.setStatus(id, previous, previous: status, title: title)
            }
        }
        undoManager?.setActionName(status == .done ? "Complete “\(title)”" : "Reopen “\(title)”")
    }

    /// Single click: select. The details panel follows the selection if it's open.
    func select(_ taskId: UUID?) {
        selectedTaskId = taskId
    }

    /// Double-click, ⌘I, palette: select and show the details panel.
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

    func editTask(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        perform { try store.editTask(id, change) }
    }

    func deleteTask(_ id: UUID) {
        let title = (try? store.db.read { try TaskItem.fetchOne($0, id: id) })?.title ?? "Task"
        perform { try store.deleteTask(id) }
        if selectedTaskId == id { selectedTaskId = nil }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.restoreTask(id, title: title) }
        }
        undoManager?.setActionName("Delete “\(title)”")
    }

    private func restoreTask(_ id: UUID, title: String) {
        perform { try store.undeleteTask(id) }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.deleteTask(id) }
        }
        undoManager?.setActionName("Delete “\(title)”")
    }

    /// A week-strip chip was dropped on another day.
    func moveChip(_ chipId: String, to day: LocalDate) {
        let parts = chipId.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return }
        perform {
            if parts[0] == "due" {
                try store.editTask(id) { $0.dueDate = day }
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
    func createTask(from parsed: QuickAddParser.Result, defaultScope: UUID?) {
        perform {
            let destination: UUID?
            if let explicit = parsed.containerId {
                destination = explicit
            } else if let scope = defaultScope {
                destination = try store.quickAddDestination(for: scope)
            } else {
                destination = nil  // Inbox
            }
            let task = try store.addTask(
                title: parsed.title, containerId: destination, categoryId: parsed.categoryId,
                priority: parsed.priority, dueDate: parsed.dueDate, dueTime: parsed.dueTime
            )
            selectedTaskId = task.id
        }
    }

    func addSubtask(to parent: TaskItem, title: String) {
        perform { try store.addTask(title: title, containerId: parent.containerId, parentTaskId: parent.id) }
    }

    func addBlock(to task: TaskItem) {
        // Next full hour, one hour long.
        let cal = Calendar.current
        let start = cal.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
        perform { try store.addScheduleBlock(taskId: task.id, start: start, end: start.addingTimeInterval(3600)) }
    }

    // Calendar

    /// Shows an event in the details panel.
    func inspect(_ event: ExternalEvent, open: Bool) {
        selectedTaskId = nil
        inspectedEvent = event
        if open { setInspector(visible: true) }
    }

    func updateEvent(_ event: ExternalEvent, start: Date, end: Date) {
        runCalendar { try await $0.move(event, start: start, end: end) }
    }

    /// Yes / No / Maybe on a Google invitation.
    func respond(_ event: ExternalEvent, _ response: EventAttendee.Response) {
        runCalendar { try await $0.respond(event, response) }
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
        perform {
            let task = try store.addTask(title: title, containerId: containerId)
            try store.addScheduleBlock(taskId: task.id, start: start, end: end)
            selectedTaskId = task.id
        }
    }

    func createEvent(title: String, start: Date, end: Date, calendarId: String?) {
        runCalendar { try await $0.create(title: title, start: start, end: end, calendarId: calendarId) }
    }

    func confirmEventMove() {
        guard let pending = pendingEventMove else { return }
        pendingEventMove = nil
        runCalendar { source in
            for m in pending.moves { try await source.move(m.event, start: m.start, end: m.end) }
        }
    }

    func confirmEventDelete() {
        let events = pendingEventDelete
        pendingEventDelete = []
        runCalendar { source in for e in events { try await source.delete(e) } }
        if let inspected = inspectedEvent, events.contains(where: { $0.key == inspected.key }) { inspectedEvent = nil }
    }

    /// Delete key on the calendar: blocks are removed (⌘Z restores), deadlines lose their
    /// due date (⌘Z restores), events are confirmed first.
    func deleteCalendarItems(_ items: [CalendarItem]) {
        var events: [ExternalEvent] = []
        var blockIds: [UUID] = []
        var clearedDeadlines: [(UUID, LocalDate?, LocalTime?)] = []
        for item in items {
            switch item.source {
            case .block(_, let blockId):
                blockIds.append(blockId)
            case .deadline(let taskId):
                let t = try? store.db.read { try TaskItem.fetchOne($0, id: taskId) }
                clearedDeadlines.append((taskId, t?.dueDate, t?.dueTime))
            case .event(let e):
                // Your own events, or (for Google) invites on a calendar you can write to:
                // deleting an invite removes it from your calendar.
                let calendarWritable = calendarSource.writableCalendars.contains { $0.id == e.calendarId }
                if e.isWritable || (e.provider == .google && calendarWritable) { events.append(e) }
            }
        }
        perform {
            for id in blockIds { try store.deleteScheduleBlock(id) }
            for (taskId, _, _) in clearedDeadlines { try store.editTask(taskId) { $0.dueDate = nil } }
        }
        if !blockIds.isEmpty || !clearedDeadlines.isEmpty {
            undoManager?.registerUndo(withTarget: self) { model in
                MainActor.assumeIsolated {
                    model.perform {
                        for id in blockIds { try model.store.restoreScheduleBlock(id) }
                        for (taskId, date, time) in clearedDeadlines {
                            try model.store.editTask(taskId) { $0.dueDate = date; $0.dueTime = time }
                        }
                    }
                }
            }
            undoManager?.setActionName(blockIds.isEmpty ? "Clear Due Date" : "Delete Work Block")
        }
        if !events.isEmpty { pendingEventDelete = events }
    }

    func addBlock(to taskId: UUID, start: Date, end: Date) {
        perform { try store.addScheduleBlock(taskId: taskId, start: start, end: end) }
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
            calendarAnchor = calendarMode == .week ? Dashboard.weekStart(containing: today) : today
        } else {
            weekStart = Dashboard.weekStart(containing: today)
        }
    }

    /// One period back/forward in the current calendar mode.
    func stepCalendar(_ direction: Int) {
        switch calendarMode {
        case .day: calendarAnchor = calendarAnchor.adding(days: direction)
        case .week: calendarAnchor = calendarAnchor.adding(days: 7 * direction)
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

struct QuickAddRequest: Identifiable {
    let id = UUID()
    /// Prefilled due date (from double-clicking a week-strip day).
    var presetDue: LocalDate?
}

struct Toast: Identifiable {
    let id = UUID()
    var message: String
    var undo: () -> Void
}

enum AppPaths {
    static var databaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PersonalWorkspace/workspace.sqlite")
    }
}
