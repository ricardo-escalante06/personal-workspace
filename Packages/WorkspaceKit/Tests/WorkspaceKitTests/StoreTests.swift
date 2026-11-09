import Foundation
import GRDB
import Testing
@testable import WorkspaceKit

@Suite struct ContainerRuleTests {
    @Test func pathsFollowTheTree() throws {
        let store = try WorkspaceStore.inMemory()
        let school = try store.createContainer(name: "School", kind: .folder)
        let cs61b = try store.createContainer(name: "CS61B", kind: .class, parentId: school.id)
        let p3 = try store.createContainer(name: "Project 3", kind: .project, parentId: cs61b.id)
        #expect(school.path == "/\(school.id.lowercased)/")
        #expect(p3.path == "/\(school.id.lowercased)/\(cs61b.id.lowercased)/\(p3.id.lowercased)/")
        #expect(p3.depth == 3)
    }

    @Test func nestingRules() throws {
        let store = try WorkspaceStore.inMemory()
        let school = try store.createContainer(name: "School", kind: .folder)
        let cs61b = try store.createContainer(name: "CS61B", kind: .class, parentId: school.id)
        #expect(throws: WorkspaceError.invalidNesting(parent: .class, child: .folder)) {
            try store.createContainer(name: "X", kind: .folder, parentId: cs61b.id)
        }
        #expect(throws: WorkspaceError.invalidNesting(parent: .class, child: .list)) {
            try store.createContainer(name: "X", kind: .list, parentId: cs61b.id)
        }
        #expect(throws: WorkspaceError.invalidTitle) {
            try store.createContainer(name: "   ", kind: .folder)
        }
        _ = try store.createContainer(name: "Project 3", kind: .project, parentId: cs61b.id)
    }

    @Test func tasksCannotLiveInFolders() throws {
        let store = try WorkspaceStore.inMemory()
        let personal = try store.createContainer(name: "Personal", kind: .folder)
        #expect(throws: WorkspaceError.taskInFolder) {
            try store.createTask(TaskItem(containerId: personal.id, title: "Groceries"))
        }
        let list = try store.createContainer(name: "General", kind: .list, parentId: personal.id)
        let task = try store.createTask(TaskItem(containerId: list.id, title: "Groceries"))
        #expect(throws: WorkspaceError.taskInFolder) { try store.moveTask(task.id, to: personal.id) }
    }

    @Test func moveRepathsSubtreeAndRejectsCycles() throws {
        let store = try WorkspaceStore.inMemory()
        let a = try store.createContainer(name: "A", kind: .folder)
        let b = try store.createContainer(name: "B", kind: .folder, parentId: a.id)
        let c = try store.createContainer(name: "C", kind: .list, parentId: b.id)
        let other = try store.createContainer(name: "Other", kind: .folder)

        #expect(throws: WorkspaceError.cycle) { try store.moveContainer(a.id, to: c.id) }
        #expect(throws: WorkspaceError.cycle) { try store.moveContainer(a.id, to: a.id) }

        try store.moveContainer(b.id, to: other.id)
        let moved = try #require(try store.containers().first { $0.id == c.id })
        #expect(moved.path == "/\(other.id.lowercased)/\(b.id.lowercased)/\(c.id.lowercased)/")

        try store.moveContainer(b.id, to: nil)
        let root = try #require(try store.containers().first { $0.id == b.id })
        #expect(root.parentId == nil)
        #expect(root.path == "/\(b.id.lowercased)/")
    }

    @Test func kindChanges() throws {
        let store = try WorkspaceStore.inMemory()
        let folder = try store.createContainer(name: "Personal", kind: .folder)
        let list = try store.createContainer(name: "General", kind: .list, parentId: folder.id)
        _ = try store.createTask(TaskItem(containerId: list.id, title: "T"))

        try store.changeKind(list.id, to: .project)   // list -> project keeps tasks
        #expect(try store.tasks(inScope: list.id).count == 1)
        #expect(throws: WorkspaceError.self) { try store.changeKind(list.id, to: .folder) }  // has tasks
        // Folder's only child is now a project, so it may become a list…
        let other = try store.createContainer(name: "Other", kind: .folder)
        _ = try store.createContainer(name: "Errands", kind: .list, parentId: other.id)
        // …but a folder holding a list may not.
        #expect(throws: WorkspaceError.self) { try store.changeKind(other.id, to: .list) }
        try store.changeKind(folder.id, to: .list)
    }

    @Test func folderQuickAddUsesDefaultList() throws {
        let store = try WorkspaceStore.inMemory()
        let clubs = try store.createContainer(name: "Clubs", kind: .folder, color: "violet")
        let dest = try store.quickAddDestination(for: clubs.id)
        let general = try #require(try store.containers().first { $0.id == dest })
        #expect(general.name == "General")
        #expect(general.kind == .list)
        #expect(general.parentId == clubs.id)
        #expect(general.color == "violet")
        #expect(try store.quickAddDestination(for: clubs.id) == dest)   // reused, not recreated
        #expect(try store.quickAddDestination(for: dest) == dest)       // lists are their own destination
    }

    @Test func deleteIsSoftAndCascades() throws {
        let store = try WorkspaceStore.inMemory()
        let h = try SampleData.install(into: store)
        let before = try store.tasks(inScope: nil).count
        let schoolTasks = try store.tasks(inScope: h.school).count
        try store.deleteContainer(h.school)
        #expect(try store.tasks(inScope: nil).count == before - schoolTasks)
        #expect(try store.containers().contains { $0.id == h.cs61b } == false)
        // Tombstones remain locally so the deletion can sync.
        let tombstoned = try store.db.read { try Container.filter(id: h.cs61b).fetchOne($0) }
        #expect(tombstoned?.deletedAt != nil)
    }

    @Test func clearingAFieldPersistsNull() throws {
        let store = try WorkspaceStore.inMemory()
        let list = try store.createContainer(name: "L", kind: .list)
        let t = try store.createTask(TaskItem(containerId: list.id, title: "T", dueDate: LocalDate(year: 2026, month: 1, day: 1)))
        try store.update(TaskItem.self, t.id) { $0.dueDate = nil }
        let reloaded = try store.db.read { try TaskItem.fetchOne($0, id: t.id) }
        #expect(reloaded?.dueDate == nil)
    }
}

@Suite struct ScopeTests {
    @Test func dashboardsNarrowBySubtree() throws {
        let store = try WorkspaceStore.inMemory()
        let h = try SampleData.install(into: store)
        let all = try store.tasks(inScope: nil)
        let school = try store.tasks(inScope: h.school)
        let cs61b = try store.tasks(inScope: h.cs61b)
        let personal = try store.tasks(inScope: h.personal)

        #expect(all.count > school.count)
        #expect(school.count > cs61b.count)
        #expect(Set(cs61b.map(\.id)).isSubset(of: Set(school.map(\.id))))
        // CS61B includes its nested Project 3 tasks.
        #expect(cs61b.contains { $0.title == "Read spec" })
        // Personal never shows School tasks and vice versa.
        #expect(personal.contains { $0.id == h.groceries })
        #expect(!school.contains { $0.id == h.groceries })
        #expect(!personal.contains { $0.id == h.hw9 })
        // Root includes the Inbox.
        #expect(all.contains { $0.containerId == nil })
    }

    @Test func dueAndScheduledStayIndependent() throws {
        let store = try WorkspaceStore.inMemory()
        let h = try SampleData.install(into: store)
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!
        let blocks = try store.db.read {
            try ScopeQuery.scheduleBlocks(in: h.school, from: week.start, to: week.end).fetchAll($0)
        }
        // Study block + two Lab 5 blocks; HW 9 and Quiz 4 have deadlines but no blocks.
        #expect(blocks.count == 3)
        #expect(blocks.filter { $0.taskId == h.lab5 }.count == 2)
        #expect(!blocks.contains { $0.taskId == h.hw9 })
        // One Lab 5 task, never three.
        #expect(try store.tasks(inScope: h.ee66).filter { $0.title == "Lab 5" }.count == 1)
    }

    @Test func treeAndBreadcrumbs() throws {
        let store = try WorkspaceStore.inMemory()
        let h = try SampleData.install(into: store)
        let containers = try store.containers()
        let tree = ContainerTree.build(containers)
        #expect(tree.map(\.container.name) == ["Personal", "School", "Clubs"])
        let crumbs = ContainerTree.breadcrumb(for: h.project3, in: containers).map(\.name)
        #expect(crumbs == ["School", "CS61B", "Project 3"])
    }
}
