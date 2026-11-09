import Foundation
import GRDB

extension WorkspaceStore {
    // MARK: Containers

    public func setColor(_ id: UUID, _ color: String) throws {
        try update(Container.self, id) { $0.color = color }
    }

    /// Moves a container among its siblings (and optionally to a new parent),
    /// placing it just before `beforeId`, or at the end when nil.
    public func reorderContainer(_ id: UUID, parent: UUID?, before beforeId: UUID?) throws {
        let current = try db.read { try Container.live().filter(id: id).fetchOne($0) }
        guard let current else { throw WorkspaceError.notFound("Container") }
        if current.parentId != parent {
            try moveContainer(id, to: parent)
        }
        try db.write { db in
            let siblings = try Container.live()
                .filter(Column("parent_id") == parent)
                .filter(Column("id") != id)
                .order(Column("sort_rank"))
                .fetchAll(db)
            let rank: String
            if let beforeId, let index = siblings.firstIndex(where: { $0.id == beforeId }) {
                let lower = index > 0 ? siblings[index - 1].sortRank : nil
                rank = Rank.between(lower, siblings[index].sortRank)
            } else {
                rank = Rank.between(siblings.last?.sortRank, nil)
            }
            guard var c = try Container.live().filter(id: id).fetchOne(db) else { return }
            c.sortRank = rank
            try Self.save(&c, in: db)
        }
    }

    // MARK: Tasks

    /// Creates a task applying its category's defaults (due time, estimate)
    /// and placing it at the end of its container's list.
    @discardableResult
    public func addTask(
        title: String,
        containerId: UUID?,
        categoryId: UUID? = nil,
        priority: Int? = nil,
        dueDate: LocalDate? = nil,
        dueTime: LocalTime? = nil,
        parentTaskId: UUID? = nil,
        timeZone: TimeZone = .current
    ) throws -> TaskItem {
        try db.write { db in
            var dueTime = dueTime
            var estimate: Int?
            if let categoryId, let category = try TaskCategory.fetchOne(db, id: categoryId) {
                if dueDate != nil, dueTime == nil { dueTime = category.defaultDueTime }
                estimate = category.defaultEstimate
            }
            let lastRank = try String.fetchOne(
                db,
                TaskItem.live()
                    .filter(Column("container_id") == containerId)
                    .select(max(Column("sort_rank")))
            )
            return try Self.createTask(TaskItem(
                containerId: containerId, parentTaskId: parentTaskId, title: title,
                categoryId: categoryId, priority: priority,
                dueDate: dueDate, dueTime: dueTime, dueTz: dueTime == nil ? nil : timeZone.identifier,
                estimatedMinutes: estimate,
                sortRank: Rank.between(lastRank, nil)
            ), in: db)
        }
    }

    /// Edits task fields through the outbox. Keeps `completedAt` consistent with
    /// status and the due time zone consistent with the due time.
    public func editTask(_ id: UUID, timeZone: TimeZone = .current, _ change: (inout TaskItem) throws -> Void) throws {
        try db.write { db in
            guard var t = try TaskItem.live().filter(id: id).fetchOne(db) else {
                throw WorkspaceError.notFound("Task")
            }
            let before = t
            try change(&t)
            t.title = t.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.title.isEmpty { throw WorkspaceError.invalidTitle }
            if t.status != before.status {
                t.completedAt = t.status == .done ? Date() : nil
            }
            if t.dueDate == nil { t.dueTime = nil }
            if t.dueTime == nil { t.dueTz = nil } else if t.dueTz == nil { t.dueTz = timeZone.identifier }
            if t.containerId != before.containerId {
                if let containerId = t.containerId {
                    guard let c = try Container.live().filter(id: containerId).fetchOne(db) else {
                        throw WorkspaceError.notFound("Container")
                    }
                    guard c.kind.holdsTasks else { throw WorkspaceError.taskInFolder }
                }
                t.boardColumnId = nil  // columns belong to the old project
            }
            try Self.save(&t, in: db)
        }
    }

    public func updateScheduleBlock(_ id: UUID, start: Date, end: Date) throws {
        try update(ScheduleBlock.self, id) { b in
            b.startsAt = start
            b.endsAt = max(end, start.addingTimeInterval(60))
        }
    }

    public func deleteScheduleBlock(_ id: UUID) throws {
        try update(ScheduleBlock.self, id) { $0.deletedAt = Date() }
    }

    // MARK: Lookups

    public func categories() throws -> [TaskCategory] {
        try db.read { try TaskCategory.live().order(Column("name")).fetchAll($0) }
    }

    /// Creates the built-in categories if none exist yet (first launch).
    public func ensureBuiltInCategories() throws {
        try db.write { db in
            guard try TaskCategory.live().fetchCount(db) == 0 else { return }
            for (name, symbol, global) in TaskCategory.builtIns {
                var c = TaskCategory(name: name, symbol: symbol, isGlobal: global)
                try Self.save(&c, in: db)
            }
        }
    }
}

/// Small subsequence matcher for the ⌘K palette: "cs6b" matches "CS61B".
/// Higher scores for prefix and word-start matches; nil when not a match.
public enum FuzzyMatch {
    public static func score(_ query: String, in text: String) -> Int? {
        let q = Array(query.lowercased().filter { !$0.isWhitespace })
        guard !q.isEmpty else { return 0 }
        let t = Array(text.lowercased())
        var score = 0
        var qi = 0
        var previousMatch = -2
        for (ti, ch) in t.enumerated() where qi < q.count && ch == q[qi] {
            score += 1
            if ti == previousMatch + 1 { score += 3 }                       // consecutive
            if ti == 0 || t[ti - 1] == " " || t[ti - 1] == "/" { score += 5 } // word start
            previousMatch = ti
            qi += 1
        }
        guard qi == q.count else { return nil }
        if t.starts(with: q) { score += 10 }
        return score - t.count / 10   // shorter wins ties
    }
}

extension WorkspaceStore {
    /// Reverses `deleteTask`: restores the task plus the subtasks and work blocks
    /// that were deleted along with it (same tombstone time). Used by ⌘Z.
    public func undeleteTask(_ id: UUID) throws {
        try db.write { db in
            guard var task = try TaskItem.fetchOne(db, id: id), let deletedAt = task.deletedAt else { return }
            task.deletedAt = nil
            try Self.save(&task, in: db)
            let window = (deletedAt.addingTimeInterval(-1))...(deletedAt.addingTimeInterval(1))
            let children = try TaskItem.filter(Column("parent_task_id") == id).fetchAll(db)
            for var child in children where child.deletedAt.map(window.contains) == true {
                child.deletedAt = nil
                try Self.save(&child, in: db)
            }
            let taskIds = [id] + children.map(\.id)
            let blocks = try ScheduleBlock.filter(taskIds.contains(Column("task_id"))).fetchAll(db)
            for var block in blocks where block.deletedAt.map(window.contains) == true {
                block.deletedAt = nil
                try Self.save(&block, in: db)
            }
        }
    }
}
