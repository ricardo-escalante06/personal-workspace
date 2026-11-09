import Foundation
import WorkspaceKit

/// Where the local database lives. On iPhone it's in the App Group container so the
/// widgets and Siri can read (and check off) the same tasks as the app.
enum AppPaths {
    static let appGroup = "group.com.rescalante.workspace"

    static var databaseURL: URL {
        #if os(iOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return group.appendingPathComponent("PersonalWorkspace/workspace.sqlite")
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PersonalWorkspace/workspace.sqlite")
    }
}

/// One store per process (app, widget, intents), opened lazily.
enum SharedStore {
    nonisolated(unsafe) private static var cached: WorkspaceStore?
    private static let lock = NSLock()

    static func open() throws -> WorkspaceStore {
        lock.lock(); defer { lock.unlock() }
        if let cached { return cached }
        let store = try WorkspaceStore.onDisk(at: AppPaths.databaseURL)
        cached = store
        return store
    }
}
