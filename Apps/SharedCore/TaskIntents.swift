import AppIntents
import Foundation
import WorkspaceKit

/// Checks a task off (or back on). Used by the interactive widget's checkboxes; runs
/// in whichever process shows the button and writes to the shared database. The app
/// syncs the change the next time it runs.
struct ToggleTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle Task"
    static let isDiscoverable = false

    @Parameter(title: "Task") var taskId: String
    /// For an occurrence of a repeating task: its series and key.
    @Parameter(title: "Series") var seriesId: String?
    @Parameter(title: "Occurrence") var occurrenceKey: String?
    @Parameter(title: "Done") var done: Bool

    init() {}

    init(task: TaskItem, done: Bool) {
        taskId = task.id.uuidString
        seriesId = task.occurrenceOf?.uuidString
        occurrenceKey = task.occurrenceKey
        self.done = done
    }

    func perform() async throws -> some IntentResult {
        let store = try SharedStore.open()
        let status: TaskStatus = done ? .done : .notStarted
        if let s = seriesId.flatMap(UUID.init(uuidString:)), let key = occurrenceKey {
            try store.setOccurrenceStatus(s, key: key, status)
        } else if let id = UUID(uuidString: taskId) {
            try store.setStatus(id, status)
        }
        await QuickSync.run()
        return .result()
    }
}
