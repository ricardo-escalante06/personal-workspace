import Foundation
import GRDB
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

    private(set) var containers: [Container] = []
    private(set) var tree: [ContainerNode] = []
    private(set) var userId: UUID?
    private(set) var syncStatus: SyncStatus
    private(set) var pendingChanges = 0
    var selection: UUID?
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
            userId = id
            syncStatus = .idle
            await syncNow()
        }
    }

    func signInWithApple(idToken: String, nonce: String) async {
        guard let backend else { return }
        do {
            userId = try await backend.signInWithApple(idToken: idToken, nonce: nonce)
            syncStatus = .idle
            await syncNow()
        } catch {
            errorMessage = "Sign in failed: \(error.localizedDescription)"
        }
    }

    func signOut() async {
        try? await backend?.signOut()
        userId = nil
        syncStatus = backend == nil ? .localOnly : .signedOut
    }

    // MARK: Sync

    func syncNow() async {
        guard let engine, let userId else { return }
        guard syncStatus != .syncing else { return }
        syncStatus = .syncing
        do {
            let report = try await engine.sync(ownerId: userId)
            syncStatus = .synced(report.finishedAt)
        } catch {
            syncStatus = .failed(error.localizedDescription)
        }
    }

    // MARK: Commands

    func loadSampleData() {
        perform { try SampleData.install(into: store) }
    }

    func createContainer(_ kind: ContainerKind, under parent: UUID?) {
        perform {
            let created = try store.createContainer(name: "New \(kind.displayName)", kind: kind, parentId: parent)
            selection = created.id
        }
    }

    func toggleDone(_ task: TaskItem) {
        perform { try store.setStatus(task.id, task.status == .done ? .notStarted : .done) }
    }

    func delete(_ containerId: UUID) {
        perform {
            try store.deleteContainer(containerId)
            if selection == containerId { selection = nil }
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

enum AppPaths {
    static var databaseURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PersonalWorkspace/workspace.sqlite")
    }
}
