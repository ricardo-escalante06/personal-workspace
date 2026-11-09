import Foundation
import GRDB

/// The server side of sync. `SupabaseSyncRemote` (WorkspaceRemote) talks to
/// PostgREST; `InMemorySyncRemote` is used in tests and previews.
///
/// Rows travel as JSON arrays (`Data`) so the protocol stays Sendable and
/// independent of any SDK.
public protocol SyncRemote: Sendable {
    /// Upserts rows by id and returns them as the server stored them
    /// (with server `updated_at`, computed `path`, etc.).
    func push(table: String, rows: Data) async throws -> Data
    /// Rows with `updated_at > after`, oldest first, at most `limit`.
    /// Includes tombstones (`deleted_at` set).
    func pull(table: String, after: Date?, limit: Int) async throws -> Data
}

/// How the engine handles one synced table.
public struct SyncTable: Sendable {
    public let name: String
    let encodePending: @Sendable (Database, [UUID], UUID) throws -> Data?
    let apply: @Sendable (Database, Data, Set<UUID>) throws -> (count: Int, maxUpdatedAt: Date?)

    public static func of<R: SyncRecord>(
        _ type: R.Type,
        pushOrder: (@Sendable (R, R) -> Bool)? = nil
    ) -> SyncTable {
        SyncTable(
            name: R.databaseTableName,
            encodePending: { db, ids, ownerId in
                var rows = try R.filter(ids: ids).fetchAll(db)
                guard !rows.isEmpty else { return nil }
                for i in rows.indices where rows[i].ownerId == nil {
                    rows[i].ownerId = ownerId
                }
                if let pushOrder { rows.sort(by: pushOrder) }
                return try SyncCoding.encodeRows(rows)
            },
            apply: { db, data, skip in
                let rows = try SyncCoding.decodeRows(R.self, from: data)
                var maxUpdatedAt: Date?
                for row in rows {
                    maxUpdatedAt = max(maxUpdatedAt ?? row.updatedAt, row.updatedAt)
                    // A row with unpushed local edits keeps the local version;
                    // it will overwrite the server on the next push (last write wins).
                    if skip.contains(row.id) { continue }
                    try row.save(db)
                }
                return (rows.count, maxUpdatedAt)
            }
        )
    }

    /// Every synced table, in push order (parents before children so server
    /// foreign-key and ownership checks pass).
    public static let all: [SyncTable] = [
        .of(TaskCategory.self),
        // Shallow containers first: the server computes a child's path from its parent.
        .of(Container.self, pushOrder: { $0.depth < $1.depth }),
        .of(ClassTerm.self),
        .of(ProjectMeta.self),
        .of(BoardColumn.self),
        .of(ContainerCategory.self),
        // Parent tasks before subtasks.
        .of(TaskItem.self, pushOrder: { ($0.parentTaskId == nil ? 0 : 1) < ($1.parentTaskId == nil ? 0 : 1) }),
        .of(ScheduleBlock.self),
        .of(OccurrenceOverride.self),
        .of(EventMappingRule.self),
        .of(EventLink.self),
    ]
}

public struct SyncReport: Sendable, Equatable {
    public var pushed = 0
    public var pulled = 0
    public var finishedAt = Date()
}

/// Local-first sync with last-write-wins per row (DESIGN.md §9).
///
/// - Push: send every row in `sync_outbox`, apply the server's version, and
///   clear the outbox entry — unless the row was edited again mid-flight.
/// - Pull: per table, fetch rows newer than the cursor (with a small overlap
///   window for transactions that committed late) and apply them, skipping
///   rows with unpushed local edits.
public actor SyncEngine {
    public let database: any DatabaseWriter
    public let remote: any SyncRemote
    public let tables: [SyncTable]
    public let pageSize: Int
    /// Re-read this much before the cursor to catch rows from transactions that
    /// started before, but committed after, rows we already saw.
    public let cursorOverlap: TimeInterval

    public init(
        database: any DatabaseWriter,
        remote: any SyncRemote,
        tables: [SyncTable] = SyncTable.all,
        pageSize: Int = 500,
        cursorOverlap: TimeInterval = 60
    ) {
        self.database = database
        self.remote = remote
        self.tables = tables
        self.pageSize = pageSize
        self.cursorOverlap = cursorOverlap
    }

    @discardableResult
    public func sync(ownerId: UUID) async throws -> SyncReport {
        var report = SyncReport()
        report.pushed = try await push(ownerId: ownerId)
        report.pulled = try await pull()
        report.finishedAt = Date()
        return report
    }

    // MARK: Push

    public func push(ownerId: UUID) async throws -> Int {
        var pushed = 0
        for table in tables {
            // Snapshot pending ids with their seq, and encode those rows.
            let (snapshot, payload) = try await database.read { db -> ([UUID: Int64], Data?) in
                let rows = try Row.fetchAll(
                    db, sql: "SELECT row_id, seq FROM sync_outbox WHERE table_name = ?", arguments: [table.name]
                )
                var snapshot: [UUID: Int64] = [:]
                for row in rows { snapshot[row["row_id"]] = row["seq"] }
                guard !snapshot.isEmpty else { return ([:], nil) }
                return (snapshot, try table.encodePending(db, Array(snapshot.keys), ownerId))
            }
            guard !snapshot.isEmpty else { continue }

            let returned: Data? = if let payload {
                try await remote.push(table: table.name, rows: payload)
            } else {
                nil  // outbox pointed at rows that no longer exist locally
            }

            try await database.write { db in
                for (id, seq) in snapshot {
                    try db.execute(
                        sql: "DELETE FROM sync_outbox WHERE table_name = ? AND row_id = ? AND seq = ?",
                        arguments: [table.name, id, seq]
                    )
                }
                if let returned {
                    let stillPending = try Self.pendingIds(table.name, db)
                    _ = try table.apply(db, returned, stillPending)
                }
            }
            pushed += snapshot.count
        }
        return pushed
    }

    // MARK: Pull

    public func pull() async throws -> Int {
        var pulled = 0
        for table in tables {
            let cursor = try await database.read { db in
                try Date.fetchOne(db, sql: "SELECT cursor FROM sync_state WHERE table_name = ?", arguments: [table.name])
            }
            var after = cursor.map { $0.addingTimeInterval(-cursorOverlap) }

            while true {
                let data = try await remote.pull(table: table.name, after: after, limit: pageSize)
                let result = try await database.write { db -> (count: Int, maxUpdatedAt: Date?) in
                    let skip = try Self.pendingIds(table.name, db)
                    let result = try table.apply(db, data, skip)
                    if let newest = result.maxUpdatedAt {
                        try db.execute(
                            sql: """
                                INSERT INTO sync_state (table_name, cursor) VALUES (?, ?)
                                ON CONFLICT (table_name) DO UPDATE SET cursor = MAX(cursor, excluded.cursor)
                                """,
                            arguments: [table.name, newest]
                        )
                    }
                    return result
                }
                pulled += result.count
                guard result.count >= pageSize, let newest = result.maxUpdatedAt else { break }
                // Always make progress, even if a whole page shares one timestamp.
                after = max(newest, (after ?? .distantPast).addingTimeInterval(0.001))
            }
        }
        return pulled
    }

    static func pendingIds(_ table: String, _ db: Database) throws -> Set<UUID> {
        Set(try UUID.fetchAll(db, sql: "SELECT row_id FROM sync_outbox WHERE table_name = ?", arguments: [table]))
    }
}
