import Foundation
import GRDB

/// The one place that decides "which tasks belong to this dashboard".
/// Mac, iPhone and widgets all use it, so scoping rules never diverge. (DESIGN.md §9)
///
/// A scope is a container id (descendants included) or nil for All Workspace.
public enum ScopeQuery {
    /// Live tasks in the scope, including subtasks. Root scope includes the Inbox.
    public static func tasks(in scope: UUID?) -> QueryInterfaceRequest<TaskItem> {
        let live = TaskItem.live()
        // Tasks under a hidden container are left out, unless you're looking at that
        // container (or something inside it) directly.
        let scopePath: SQL = scope.map { SQL("(SELECT path FROM containers WHERE id = \($0))") } ?? SQL("NULL")
        let notHidden: SQLExpression = SQL("""
            (container_id IS NULL OR NOT EXISTS (
                SELECT 1 FROM containers c, containers h
                WHERE c.id = tasks.container_id
                  AND h.archived_at IS NOT NULL AND h.deleted_at IS NULL
                  AND c.path LIKE h.path || '%'
                  AND NOT (COALESCE(\(scopePath), '') LIKE h.path || '%')
            ))
            """).sqlExpression
        guard let scope else {
            return live.filter(notHidden).order(Column("sort_rank"))
        }
        let inScope: SQLExpression = SQL("""
            container_id IN (
                SELECT id FROM containers
                WHERE deleted_at IS NULL
                  AND path LIKE \(scopePath) || '%'
            )
            """).sqlExpression
        return live.filter(inScope).filter(notHidden).order(Column("sort_rank"))
    }

    /// Paths of hidden (archived) containers; anything under them is hidden too.
    public static func hiddenPaths(_ db: Database) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT path FROM containers WHERE archived_at IS NOT NULL AND deleted_at IS NULL")
    }

    /// Live containers in the subtree under `scope` (excluding the scope itself).
    public static func descendants(of scope: UUID) -> QueryInterfaceRequest<Container> {
        let scopePath = SQL("(SELECT path FROM containers WHERE id = \(scope))")
        return Container.live()
            .filter(SQL("path LIKE \(scopePath) || '%'").sqlExpression)
            .filter(Column("id") != scope)
            .order(Column("sort_rank"))
    }

    /// Schedule blocks for tasks in the scope that overlap [start, end).
    public static func scheduleBlocks(in scope: UUID?, from start: Date, to end: Date) -> QueryInterfaceRequest<ScheduleBlock> {
        let taskIds = tasks(in: scope).select(Column("id"))
        return ScheduleBlock.live()
            .filter(taskIds.contains(Column("task_id")))
            .filter(Column("starts_at") < end && Column("ends_at") > start)
            .order(Column("starts_at"))
    }
}
