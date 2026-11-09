import Foundation
import GRDB
import Testing
@testable import WorkspaceKit

@Suite struct EditingTests {
    @Test func reorderPlacesBeforeSibling() throws {
        let store = try WorkspaceStore.inMemory()
        let a = try store.createContainer(name: "A", kind: .folder)
        let b = try store.createContainer(name: "B", kind: .folder)
        let c = try store.createContainer(name: "C", kind: .folder)
        try store.reorderContainer(c.id, parent: nil, before: a.id)
        #expect(ContainerTree.build(try store.containers()).map(\.container.name) == ["C", "A", "B"])
        try store.reorderContainer(c.id, parent: nil, before: nil)
        #expect(ContainerTree.build(try store.containers()).map(\.container.name) == ["A", "B", "C"])
        // Reparent + position in one step.
        let list = try store.createContainer(name: "L", kind: .list, parentId: a.id)
        try store.reorderContainer(list.id, parent: b.id, before: nil)
        let moved = try #require(try store.containers().first { $0.id == list.id })
        #expect(moved.parentId == b.id)
        #expect(moved.path.hasPrefix(b.path))
    }

    @Test func addTaskAppliesCategoryDefaults() throws {
        let store = try WorkspaceStore.inMemory()
        let list = try store.createContainer(name: "CS61B", kind: .class)
        let hw = try store.db.write { db -> TaskCategory in
            var c = TaskCategory(name: "Homework", defaultDueTime: LocalTime(hour: 23, minute: 59), defaultEstimate: 120)
            try WorkspaceStore.save(&c, in: db)
            return c
        }
        let t = try store.addTask(title: "HW 1", containerId: list.id, categoryId: hw.id,
                                  dueDate: LocalDate(year: 2026, month: 11, day: 13))
        #expect(t.dueTime == LocalTime(hour: 23, minute: 59))
        #expect(t.estimatedMinutes == 120)
        let t2 = try store.addTask(title: "HW 2", containerId: list.id)
        #expect(t.sortRank < t2.sortRank)
    }

    @Test func editTaskKeepsInvariants() throws {
        let store = try WorkspaceStore.inMemory()
        let list = try store.createContainer(name: "L", kind: .list)
        let t = try store.addTask(title: "T", containerId: list.id, dueDate: LocalDate(year: 2026, month: 1, day: 2),
                                  dueTime: LocalTime(hour: 9, minute: 0))
        try store.editTask(t.id) { $0.status = .done }
        var reloaded = try #require(try store.db.read { try TaskItem.fetchOne($0, id: t.id) })
        #expect(reloaded.completedAt != nil)
        try store.editTask(t.id) { $0.dueDate = nil }
        reloaded = try #require(try store.db.read { try TaskItem.fetchOne($0, id: t.id) })
        #expect(reloaded.dueTime == nil && reloaded.dueTz == nil)
        #expect(throws: WorkspaceError.invalidTitle) { try store.editTask(t.id) { $0.title = "  " } }
    }

    @Test func fuzzyMatchRanksSensibly() {
        #expect(FuzzyMatch.score("cs6b", in: "CS61B") != nil)
        #expect(FuzzyMatch.score("xyz", in: "CS61B") == nil)
        let prefix = FuzzyMatch.score("hw", in: "HW 9")!
        let scattered = FuzzyMatch.score("hw", in: "Read the chapter wisely")!
        #expect(prefix > scattered)
    }
}

@Suite struct EditTaskMoveTests {
    @Test func movingIntoAFolderIsRejectedAndNotSaved() throws {
        let store = try WorkspaceStore.inMemory()
        let folder = try store.createContainer(name: "F", kind: .folder)
        let list = try store.createContainer(name: "L", kind: .list, parentId: folder.id)
        let t = try store.addTask(title: "T", containerId: list.id)
        #expect(throws: WorkspaceError.taskInFolder) {
            try store.editTask(t.id) { $0.containerId = folder.id; $0.title = "Changed" }
        }
        let reloaded = try #require(try store.db.read { try TaskItem.fetchOne($0, id: t.id) })
        #expect(reloaded.containerId == list.id)
        #expect(reloaded.title == "T")
    }
}

@Suite struct UndeleteTests {
    @Test func undeleteRestoresTaskSubtasksAndBlocks() throws {
        let store = try WorkspaceStore.inMemory()
        let list = try store.createContainer(name: "L", kind: .list)
        let t = try store.addTask(title: "T", containerId: list.id)
        _ = try store.addTask(title: "Sub", containerId: list.id, parentTaskId: t.id)
        try store.addScheduleBlock(taskId: t.id, start: Date(), end: Date().addingTimeInterval(3600))
        try store.deleteTask(t.id)
        #expect(try store.tasks(inScope: list.id).isEmpty)
        try store.undeleteTask(t.id)
        #expect(try store.tasks(inScope: list.id).count == 2)
        let blocks = try store.db.read { try ScheduleBlock.live().fetchCount($0) }
        #expect(blocks == 1)
    }
}
