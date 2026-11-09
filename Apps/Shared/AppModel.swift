import Foundation
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
    private(set) var userId: UUID?
    private(set) var syncStatus: SyncStatus
    private(set) var pendingChanges = 0
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
    var errorMessage: String?

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
                    self?.containers = containers
                    self?.tree = ContainerTree.build(containers)
                }
            } catch {
                self?.errorMessage = error.localizedDescription
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
        containers.first { $0.id == id }
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

        pathMonitor.pathUpdateHandler = { [weak self] path in
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
        Task { await scheduler?.request(.appActive) }
    }

    /// Toolbar button / ⇧⌘R: sync immediately.
    func syncNow() async {
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

    func createContainer(_ kind: ContainerKind, under parent: UUID?) {
        perform {
            let created = try store.createContainer(name: "New \(kind.displayName)", kind: kind, parentId: parent)
            selection = .container(created.id)
        }
    }

    func toggleDone(_ task: TaskItem) {
        perform { try store.setStatus(task.id, task.status == .done ? .notStarted : .done) }
    }

    func delete(_ containerId: UUID) {
        perform {
            try store.deleteContainer(containerId)
            if selection == .container(containerId) { selection = .allWorkspace }
        }
    }

    private func perform(_ work: () throws -> Void) {
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
    case container(UUID)
}

enum AppPaths {
    static var databaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PersonalWorkspace/workspace.sqlite")
    }
}
