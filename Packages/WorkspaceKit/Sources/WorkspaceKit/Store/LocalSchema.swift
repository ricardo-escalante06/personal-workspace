import Foundation
import GRDB

/// Local SQLite schema. Synced tables mirror their Postgres counterparts column
/// for column (see supabase/migrations). Local-only tables are prefixed `sync_`.
///
/// No foreign keys locally: sync can deliver rows in any order, and the server
/// enforces referential integrity.
enum LocalSchema {
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        #if DEBUG
        m.eraseDatabaseOnSchemaChange = false
        #endif

        m.registerMigration("v1") { db in
            func synced(_ name: String, _ body: (TableDefinition) -> Void) throws {
                try db.create(table: name) { t in
                    t.primaryKey("id", .blob)
                    t.column("owner_id", .blob)
                    body(t)
                    t.column("created_at", .datetime).notNull()
                    t.column("updated_at", .datetime).notNull()
                    t.column("deleted_at", .datetime)
                }
            }

            try synced("containers") { t in
                t.column("parent_id", .blob).indexed()
                t.column("kind", .text).notNull()
                t.column("name", .text).notNull()
                t.column("color", .text).notNull()
                t.column("icon", .text)
                t.column("path", .text).notNull().indexed()
                t.column("default_list_id", .blob)
                t.column("sort_rank", .text).notNull()
                t.column("archived_at", .datetime)
                t.column("settings", .text).notNull()
            }
            try synced("class_terms") { t in
                t.column("container_id", .blob).notNull().indexed()
                t.column("term_start", .text)
                t.column("term_end", .text)
                t.column("skip_ranges", .text).notNull()
                t.column("course_code", .text)
                t.column("event_title_pattern", .text)
            }
            try synced("project_meta") { t in
                t.column("container_id", .blob).notNull().indexed()
                t.column("status", .text).notNull()
                t.column("target_date", .text)
                t.column("description", .text).notNull()
            }
            try synced("board_columns") { t in
                t.column("container_id", .blob).notNull().indexed()
                t.column("name", .text).notNull()
                t.column("maps_to_status", .text).notNull()
                t.column("sort_rank", .text).notNull()
                t.column("wip_limit", .integer)
            }
            try synced("categories") { t in
                t.column("name", .text).notNull()
                t.column("symbol", .text).notNull()
                t.column("color", .text)
                t.column("default_due_time", .text)
                t.column("default_estimate", .integer)
                t.column("default_subtasks", .text).notNull()
                t.column("is_global", .boolean).notNull()
            }
            try synced("container_categories") { t in
                t.column("container_id", .blob).notNull().indexed()
                t.column("category_id", .blob).notNull()
            }
            try synced("tasks") { t in
                t.column("container_id", .blob).indexed()
                t.column("parent_task_id", .blob).indexed()
                t.column("title", .text).notNull()
                t.column("notes", .text).notNull()
                t.column("category_id", .blob)
                t.column("priority", .integer)
                t.column("status", .text).notNull()
                t.column("due_date", .text).indexed()
                t.column("due_time", .text)
                t.column("due_tz", .text)
                t.column("estimated_minutes", .integer)
                t.column("source_url", .text)
                t.column("board_column_id", .blob)
                t.column("board_rank", .text)
                t.column("sort_rank", .text).notNull()
                t.column("rrule", .text)
                t.column("rrule_tz", .text)
                t.column("rrule_anchor", .text)
                t.column("generated_by_rule_id", .blob)
                t.column("template_origin_id", .blob)
                t.column("detached_fields", .text).notNull()
                t.column("completed_at", .datetime)
            }
            try synced("task_schedule_blocks") { t in
                t.column("task_id", .blob).notNull().indexed()
                t.column("starts_at", .datetime).notNull().indexed()
                t.column("ends_at", .datetime).notNull()
                t.column("occurrence_key", .text)
                t.column("external_event_key", .text)
            }
            try synced("task_occurrence_overrides") { t in
                t.column("task_id", .blob).notNull().indexed()
                t.column("occurrence_key", .text).notNull()
                t.column("status", .text)
                t.column("completed_at", .datetime)
                t.column("due_date", .text)
                t.column("due_time", .text)
                t.column("skipped", .boolean).notNull()
                t.column("title", .text)
            }

            // Rows changed locally and not yet confirmed by the server.
            // `seq` increases on every local write, so a push can tell whether
            // a row changed again while its request was in flight.
            try db.create(table: "sync_outbox") { t in
                t.column("table_name", .text).notNull()
                t.column("row_id", .blob).notNull()
                t.column("seq", .integer).notNull()
                t.primaryKey(["table_name", "row_id"])
            }
            // Pull cursor per table: the highest server updated_at seen.
            try db.create(table: "sync_state") { t in
                t.primaryKey("table_name", .text)
                t.column("cursor", .datetime).notNull()
            }
        }

        // Milestone 2: calendar mapping tables.
        m.registerMigration("v2-calendar") { db in
            func synced(_ name: String, _ body: (TableDefinition) -> Void) throws {
                try db.create(table: name) { t in
                    t.primaryKey("id", .blob)
                    t.column("owner_id", .blob)
                    body(t)
                    t.column("created_at", .datetime).notNull()
                    t.column("updated_at", .datetime).notNull()
                    t.column("deleted_at", .datetime)
                }
            }
            try synced("event_mapping_rules") { t in
                t.column("match_type", .text).notNull()
                t.column("match_value", .text).notNull()
                t.column("container_id", .blob).notNull()
                t.column("priority", .integer).notNull()
            }
            try synced("event_links") { t in
                t.column("external_event_key", .text).notNull().indexed()
                t.column("occurrence_start", .datetime)
                t.column("container_id", .blob)
                t.column("task_id", .blob)
                t.column("notes", .text)
            }
        }
        // Milestone 3: stars, start dates, project milestones, assignment series.
        m.registerMigration("v3-milestone3") { db in
            try db.alter(table: "tasks") { t in
                t.add(column: "is_starred", .boolean).notNull().defaults(to: false)
                t.add(column: "start_date", .text)
                t.add(column: "is_milestone", .boolean).notNull().defaults(to: false)
                t.add(column: "milestone_id", .blob)
                t.add(column: "series_index", .integer)
            }
            try db.create(index: "tasks_milestone_id", on: "tasks", columns: ["milestone_id"])
            try db.create(index: "tasks_generated_by_rule_id", on: "tasks", columns: ["generated_by_rule_id"])
            try db.alter(table: "categories") { t in
                t.add(column: "auto_star", .boolean).notNull().defaults(to: false)
            }
            try db.create(table: "assignment_rules") { t in
                t.primaryKey("id", .blob)
                t.column("owner_id", .blob)
                t.column("container_id", .blob).notNull().indexed()
                t.column("category_id", .blob)
                t.column("title_pattern", .text).notNull()
                t.column("start_number", .integer).notNull()
                t.column("count", .integer)
                t.column("first_due_date", .text)
                t.column("due_time", .text)
                t.column("repeat", .text).notNull()
                t.column("estimated_minutes", .integer)
                t.column("created_at", .datetime).notNull()
                t.column("updated_at", .datetime).notNull()
                t.column("deleted_at", .datetime)
            }
        }
        // Milestone colors.
        m.registerMigration("v4-milestone-color") { db in
            try db.alter(table: "tasks") { t in t.add(column: "color", .text) }
        }
        return m
    }
}
