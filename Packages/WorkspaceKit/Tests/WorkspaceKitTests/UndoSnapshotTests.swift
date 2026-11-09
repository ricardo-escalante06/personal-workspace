import Foundation
import GRDB
import Testing
@testable import WorkspaceKit

@Suite struct UndoSnapshotTests {
    @Test func restoreUndoesEditsDeletesAndCreates() throws {
        let store = try WorkspaceStore.inMemory()
        let a = try store.addTask(title: "A", containerId: nil)
        let b = try store.addTask(title: "B", containerId: nil)
        let sub = try store.addTask(title: "A.1", containerId: nil, parentTaskId: a.id)
        let block = try store.addScheduleBlock(taskId: a.id, start: Date(), end: Date().addingTimeInterval(3600))
        let newId = UUID()

        let before = try store.snapshot([a.id, b.id], creating: [newId])
        try store.editTask(b.id) { $0.title = "B edited" }
        try store.deleteTask(a.id)
        try store.createTask(TaskItem(id: newId, containerId: nil, title: "New"))

        try store.restore(before)
        let live = try store.db.read { try TaskItem.live().fetchAll($0) }
        #expect(Set(live.map(\.title)) == ["A", "B", "A.1"])
        #expect(live.contains { $0.id == sub.id })
        let liveBlocks = try store.db.read { try ScheduleBlock.live().fetchAll($0) }
        #expect(liveBlocks.map(\.id) == [block.id])
    }
}
