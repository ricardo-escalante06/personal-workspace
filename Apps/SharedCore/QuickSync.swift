import Foundation
import WorkspaceKit
import WorkspaceRemote

/// A one-off sync from outside the app (a widget check-off): pushes the change right
/// away so the Mac sees it within seconds, without opening the iPhone app.
enum QuickSync {
    static func run(timeout: Duration = .seconds(8)) async {
        guard let config = BackendConfig.fromInfoPlist(), let store = try? SharedStore.open() else { return }
        let backend = SupabaseBackend(config: config)
        guard let userId = await backend.currentUserId() else { return }
        let engine = SyncEngine(database: store.db, remote: backend.remote)
        await withTaskGroup(of: Void.self) { group in
            group.addTask { _ = try? await engine.sync(ownerId: userId) }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
        }
    }
}
