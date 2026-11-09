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
        guard let scope else {
            return live.order(Column("sort_rank"))
        }
        let scopePath = SQL("(SELECT path FROM containers WHERE id = \(scope))")
        let inScope: SQLExpression = SQL("""
            container_id IN (
                SELECT id FROM containers
                WHERE deleted_at IS NULL
                  AND path LIKE \(scopePath) || '%'
            )
            """).sqlExpression
        return live.filter(inScope).order(Column("sort_rank"))
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
