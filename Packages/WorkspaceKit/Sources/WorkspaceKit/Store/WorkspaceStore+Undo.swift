import Foundation
import GRDB

/// What some tasks (plus their subtasks and work blocks) looked like at one moment.
/// ⌘Z restores a snapshot; a row that didn't exist yet (`nil`) is deleted on restore.
public struct TaskSnapshot: Sendable {
    public var tasks: [UUID: TaskItem?] = [:]  // value nil = didn't exist
    public var blocks: [UUID: ScheduleBlock?] = [:]
    public var taskIds: [UUID] { Array(tasks.keys) }
    public init() {}
}

extension WorkspaceStore {
    /// Captures `taskIds`, their subtasks and their work blocks (deleted rows included).
    /// `creating` are ids about to be made: recorded as absent so undo removes them.
    public func snapshot(_ taskIds: some Collection<UUID>, creating: [UUID] = []) throws -> TaskSnapshot {
        try db.read { db in
            var snap = TaskSnapshot()
            let ids = Array(Set(taskIds))
            var tasks = try TaskItem.filter(ids.contains(Column("id"))).fetchAll(db)
            tasks += try TaskItem.filter(ids.contains(Column("parent_task_id"))).fetchAll(db)
            for t in tasks { snap.tasks[t.id] = .some(t) }
            for id in ids where snap.tasks[id] == nil { snap.tasks[id] = .some(nil) }
            for id in creating { snap.tasks[id] = .some(nil) }
            let all = Array(snap.tasks.keys)
            for b in try ScheduleBlock.filter(all.contains(Column("task_id"))).fetchAll(db) {
                snap.blocks[b.id] = .some(b)
            }
            return snap
        }
    }

    /// Writes a snapshot back. Rows created since it was taken are deleted.
    public func restore(_ snap: TaskSnapshot) throws {
        try db.write { db in
            let now = Date()
            // Parents and milestones first so the push order stays valid.
            func level(_ t: TaskItem?) -> Int {
                guard let t else { return 0 }
                return (t.parentTaskId == nil && t.milestoneId == nil) ? 0 : 1
            }
            let ordered: [(key: UUID, value: TaskItem?)] = snap.tasks.sorted { level($0.value) < level($1.value) }
            for (id, old) in ordered {
                if var t = old {
                    try Self.save(&t, in: db)
                } else if var current = try TaskItem.fetchOne(db, id: id), current.deletedAt == nil {
                    current.deletedAt = now
                    try Self.save(&current, in: db)
                }
            }
            let taskIds = Array(snap.tasks.keys)
            let currentBlocks = try ScheduleBlock.filter(taskIds.contains(Column("task_id"))).fetchAll(db)
            for var b in currentBlocks where snap.blocks[b.id] == nil && b.deletedAt == nil {
                b.deletedAt = now  // added after the snapshot
                try Self.save(&b, in: db)
            }
            for (_, old) in snap.blocks {
                if var b = old ?? nil { try Self.save(&b, in: db) }
            }
        }
    }
}
