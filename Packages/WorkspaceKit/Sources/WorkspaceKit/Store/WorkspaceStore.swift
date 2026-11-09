import Foundation
import GRDB

public enum WorkspaceError: Error, Equatable, LocalizedError {
    case notFound(String)
    case invalidNesting(parent: ContainerKind, child: ContainerKind)
    case cycle
    case taskInFolder
    case kindChangeBlocked(String)
    case invalidTitle

    public var errorDescription: String? {
        switch self {
        case .notFound(let what): "\(what) not found."
        case .invalidNesting(let p, let c): "A \(p.displayName.lowercased()) can't contain a \(c.displayName.lowercased())."
        case .cycle: "A container can't be moved inside itself."
        case .taskInFolder: "Tasks can't live directly in a folder. Use one of its lists."
        case .kindChangeBlocked(let why): why
        case .invalidTitle: "A name is required."
        }
    }
}

/// The local, offline-first store. Every write:
///  1. validates the same rules the server enforces,
///  2. stamps `updatedAt`,
///  3. records the row in `sync_outbox` so the sync engine pushes it.
///
/// Reads always come from local SQLite; the UI never waits on the network.
public final class WorkspaceStore: Sendable {
    public let db: any DatabaseWriter

    public init(db: any DatabaseWriter) throws {
        self.db = db
        try LocalSchema.migrator.migrate(db)
    }

    public static func inMemory() throws -> WorkspaceStore {
        try WorkspaceStore(db: DatabaseQueue())
    }

    /// File-backed store. Uses a DatabasePool so widgets/extensions can read concurrently.
    public static func onDisk(at url: URL) throws -> WorkspaceStore {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.busyMode = .timeout(5)
        return try WorkspaceStore(db: DatabasePool(path: url.path, configuration: config))
    }

    // MARK: - Generic write path

    /// Saves a record locally and queues it for push. Use inside `db.write`.
    public static func save<R: SyncRecord>(_ record: inout R, in db: Database) throws {
        record.updatedAt = Date()
        try record.save(db)
        try enqueue(R.databaseTableName, record.id, in: db)
    }

    static func enqueue(_ table: String, _ id: UUID, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO sync_outbox (table_name, row_id, seq)
                VALUES (?, ?, (SELECT COALESCE(MAX(seq), 0) + 1 FROM sync_outbox))
                ON CONFLICT (table_name, row_id) DO UPDATE SET seq = excluded.seq
                """,
            arguments: [table, id]
        )
    }

    public func pendingChangeCount() throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM sync_outbox") ?? 0 }
    }

    // MARK: - Containers

    @discardableResult
    public func createContainer(
        name: String,
        kind: ContainerKind,
        parentId: UUID? = nil,
        color: String = "grey",
        id: UUID = UUID()
    ) throws -> Container {
        try db.write { db in
            try Self.createContainer(name: name, kind: kind, parentId: parentId, color: color, id: id, in: db)
        }
    }

    @discardableResult
    public static func createContainer(
        name: String, kind: ContainerKind, parentId: UUID?, color: String = "grey", id: UUID = UUID(),
        in db: Database
    ) throws -> Container {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw WorkspaceError.invalidTitle }

        var parentPath = "/"
        if let parentId {
            guard let parent = try Container.live().filter(id: parentId).fetchOne(db) else {
                throw WorkspaceError.notFound("Parent container")
            }
            guard parent.kind.canContain(kind) else {
                throw WorkspaceError.invalidNesting(parent: parent.kind, child: kind)
            }
            parentPath = parent.path
        }

        let lastRank = try String.fetchOne(
            db,
            Container.live()
                .filter(Column("parent_id") == parentId)
                .select(max(Column("sort_rank")))
        )
        var container = Container(
            id: id, parentId: parentId, kind: kind, name: trimmed, color: color,
            path: parentPath + id.lowercased + "/",
            sortRank: Rank.between(lastRank, nil)
        )
        try save(&container, in: db)
        return container
    }

    /// Moves a container (and its subtree) under a new parent.
    public func moveContainer(_ id: UUID, to newParentId: UUID?) throws {
        try db.write { db in
            guard var container = try Container.live().filter(id: id).fetchOne(db) else {
                throw WorkspaceError.notFound("Container")
            }
            var newParentPath = "/"
            if let newParentId {
                guard let parent = try Container.live().filter(id: newParentId).fetchOne(db) else {
                    throw WorkspaceError.notFound("Parent container")
                }
                if newParentId == id || parent.path.contains("/\(id.lowercased)/") {
                    throw WorkspaceError.cycle
                }
                guard parent.kind.canContain(container.kind) else {
                    throw WorkspaceError.invalidNesting(parent: parent.kind, child: container.kind)
                }
                newParentPath = parent.path
            }

            let oldPath = container.path
            let newPath = newParentPath + id.lowercased + "/"
            container.parentId = newParentId
            container.path = newPath
            try Self.save(&container, in: db)

            // Re-path descendants. Each one is queued too; the server recomputes
            // paths anyway, so these pushes are idempotent.
            let descendants = try Container
                .filter(Column("path").like("\(oldPath)%"))
                .filter(Column("id") != id)
                .fetchAll(db)
            for var d in descendants {
                d.path = newPath + d.path.dropFirst(oldPath.count)
                try Self.save(&d, in: db)
            }
        }
    }

    public func renameContainer(_ id: UUID, to name: String) throws {
        try update(Container.self, id) { c in
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw WorkspaceError.invalidTitle }
            c.name = trimmed
        }
    }

    /// Changes a container's kind (list ⇄ class ⇄ project, etc.) without losing tasks.
    public func changeKind(_ id: UUID, to kind: ContainerKind) throws {
        try db.write { db in
            guard var c = try Container.live().filter(id: id).fetchOne(db) else {
                throw WorkspaceError.notFound("Container")
            }
            guard c.kind != kind else { return }
            if let parentId = c.parentId,
               let parent = try Container.live().filter(id: parentId).fetchOne(db),
               !parent.kind.canContain(kind) {
                throw WorkspaceError.invalidNesting(parent: parent.kind, child: kind)
            }
            if kind == .folder {
                let taskCount = try TaskItem.live().filter(Column("container_id") == id).fetchCount(db)
                if taskCount > 0 {
                    throw WorkspaceError.kindChangeBlocked("\(c.name) still has tasks, so it can't become a folder.")
                }
            } else {
                let blocking = try Container.live()
                    .filter(Column("parent_id") == id)
                    .filter(Column("kind") != ContainerKind.project.rawValue)
                    .fetchCount(db)
                if blocking > 0 {
                    throw WorkspaceError.kindChangeBlocked("\(c.name) contains folders or lists, so it has to stay a folder.")
                }
                c.defaultListId = nil
            }
            c.kind = kind
            try Self.save(&c, in: db)
        }
    }

    /// Soft-deletes a container, its whole subtree, and every task inside.
    public func deleteContainer(_ id: UUID) throws {
        try db.write { db in
            guard let root = try Container.live().filter(id: id).fetchOne(db) else { return }
            let now = Date()
            let subtree = try Container.live().filter(Column("path").like("\(root.path)%")).fetchAll(db)
            let ids = subtree.map(\.id)
            for var c in subtree {
                c.deletedAt = now
                try Self.save(&c, in: db)
            }
            let tasks = try TaskItem.live().filter(ids.contains(Column("container_id"))).fetchAll(db)
            for var t in tasks {
                t.deletedAt = now
                try Self.save(&t, in: db)
            }
            // Folders whose default list just disappeared fall back to "none".
            let folders = try Container.live().filter(ids.contains(Column("default_list_id"))).fetchAll(db)
            for var f in folders {
                f.defaultListId = nil
                try Self.save(&f, in: db)
            }
        }
    }

    /// Where quick-add from `containerId`'s dashboard puts a new task.
    /// Task-holding containers return themselves. Folders return their default
    /// list, creating "General" the first time if needed. (DESIGN.md §2)
    public func quickAddDestination(for containerId: UUID) throws -> UUID {
        try db.write { db in
            guard var container = try Container.live().filter(id: containerId).fetchOne(db) else {
                throw WorkspaceError.notFound("Container")
            }
            if container.kind.holdsTasks { return container.id }

            if let listId = container.defaultListId,
               try Container.live().filter(id: listId).fetchOne(db) != nil {
                return listId
            }
            let existing = try Container.live()
                .filter(Column("parent_id") == containerId)
                .filter(Column("kind") == ContainerKind.list.rawValue)
                .order(Column("sort_rank"))
                .fetchOne(db)
            let list = try existing ?? Self.createContainer(
                name: "General", kind: .list, parentId: containerId, color: container.color, in: db
            )
            container.defaultListId = list.id
            try Self.save(&container, in: db)
            return list.id
        }
    }

    // MARK: - Tasks

    @discardableResult
    public func createTask(_ task: TaskItem) throws -> TaskItem {
        try db.write { db in try Self.createTask(task, in: db) }
    }

    @discardableResult
    public static func createTask(_ task: TaskItem, in db: Database) throws -> TaskItem {
        var task = task
        task.title = task.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.title.isEmpty else { throw WorkspaceError.invalidTitle }
        if let containerId = task.containerId {
            guard let container = try Container.live().filter(id: containerId).fetchOne(db) else {
                throw WorkspaceError.notFound("Container")
            }
            guard container.kind.holdsTasks else { throw WorkspaceError.taskInFolder }
        }
        if task.status == .done, task.completedAt == nil { task.completedAt = Date() }
        try save(&task, in: db)
        return task
    }

    public func setStatus(_ taskId: UUID, _ status: TaskStatus) throws {
        try update(TaskItem.self, taskId) { t in
            t.status = status
            t.completedAt = status == .done ? (t.completedAt ?? Date()) : nil
        }
    }

    public func moveTask(_ taskId: UUID, to containerId: UUID?) throws {
        try db.write { db in
            if let containerId {
                guard let c = try Container.live().filter(id: containerId).fetchOne(db) else {
                    throw WorkspaceError.notFound("Container")
                }
                guard c.kind.holdsTasks else { throw WorkspaceError.taskInFolder }
            }
            guard var t = try TaskItem.live().filter(id: taskId).fetchOne(db) else {
                throw WorkspaceError.notFound("Task")
            }
            t.containerId = containerId
            t.boardColumnId = nil
            try Self.save(&t, in: db)
        }
    }

    public func deleteTask(_ taskId: UUID) throws {
        try db.write { db in
            let now = Date()
            let tasks = try TaskItem.live()
                .filter(Column("id") == taskId || Column("parent_task_id") == taskId)
                .fetchAll(db)
            for var t in tasks {
                t.deletedAt = now
                try Self.save(&t, in: db)
            }
            let blocks = try ScheduleBlock.live().filter(tasks.map(\.id).contains(Column("task_id"))).fetchAll(db)
            for var b in blocks {
                b.deletedAt = now
                try Self.save(&b, in: db)
            }
        }
    }

    @discardableResult
    public func addScheduleBlock(taskId: UUID, start: Date, end: Date) throws -> ScheduleBlock {
        try db.write { db in
            guard try TaskItem.live().filter(id: taskId).fetchOne(db) != nil else {
                throw WorkspaceError.notFound("Task")
            }
            var block = ScheduleBlock(taskId: taskId, startsAt: start, endsAt: max(end, start.addingTimeInterval(60)))
            try Self.save(&block, in: db)
            return block
        }
    }

    // MARK: - Generic update

    /// Loads a live record, applies `change`, and saves it through the outbox.
    public func update<R: SyncRecord>(_ type: R.Type, _ id: UUID, _ change: (inout R) throws -> Void) throws {
        try db.write { db in
            guard var record = try R.live().filter(id: id).fetchOne(db) else {
                throw WorkspaceError.notFound(R.databaseTableName)
            }
            try change(&record)
            try Self.save(&record, in: db)
        }
    }

    // MARK: - Reads

    public func containers() throws -> [Container] {
        try db.read { try Container.live().order(Column("sort_rank")).fetchAll($0) }
    }

    public func tasks(inScope scope: UUID?) throws -> [TaskItem] {
        try db.read { try ScopeQuery.tasks(in: scope).fetchAll($0) }
    }
}
