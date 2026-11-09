import Foundation
import GRDB

/// Which alerts to schedule for the next few days (pure; the app hands the result to
/// the system). Defaults:
///  - timed deadline: an hour before ("Due at 11:59 PM")
///  - date-only deadline: 9 AM that day ("Due today")
///  - starred / Exam: also 9 AM the day before ("Tomorrow")
///  - work block: when it starts
public enum ReminderPlanner {
    public struct Settings: Codable, Equatable, Sendable {
        public var minutesBeforeTimed = 60
        public var morningHour = 9
        public var dayBeforeStarred = true
        public var workBlocks = true
        public init() {}
    }

    public struct Reminder: Equatable, Sendable {
        public var id: String
        public var date: Date
        public var title: String
        public var body: String
        /// The task (or occurrence) to open when tapped.
        public var taskId: UUID
        public var seriesId: UUID?
        public var occurrenceKey: String?
    }

    public static func plan(
        tasks: [TaskItem], overrides: [OccurrenceOverride], blocks: [ScheduleBlock],
        autoStarCategories: Set<UUID>, containerNames: [UUID: String],
        now: Date, timeZone: TimeZone, settings: Settings = Settings(), days: Int = 7, limit: Int = 60
    ) -> [Reminder] {
        let today = LocalDate(now, in: timeZone)
        let end = today.adding(days: days)
        let expanded = Occurrences.expandAll(tasks, overrides: overrides, from: today, through: end.adding(days: 1))
        let open = expanded.filter { $0.deletedAt == nil && !$0.status.isClosed }
        let byId = Dictionary(expanded.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Reminder] = []

        func where_(_ t: TaskItem) -> String { t.containerId.flatMap { containerNames[$0] } ?? "Inbox" }
        func morning(_ d: LocalDate) -> Date { d.at(LocalTime(hour: settings.morningHour, minute: 0), in: timeZone) }
        func add(_ id: String, _ date: Date, _ t: TaskItem, _ body: String) {
            guard date > now else { return }
            out.append(Reminder(id: id, date: date, title: t.title, body: body, taskId: t.id,
                                seriesId: t.occurrenceOf, occurrenceKey: t.occurrenceKey))
        }

        for t in open {
            guard let due = t.dueDate, due <= end else { continue }
            if let time = t.dueTime, let instant = t.dueInstant(in: timeZone) {
                add("due-\(t.id)", instant.addingTimeInterval(-Double(settings.minutesBeforeTimed) * 60), t,
                    "Due at \(Self.format(time)) · \(where_(t))")
            } else {
                add("due-\(t.id)", morning(due), t, "Due today · \(where_(t))")
            }
            let starred = t.isStarred || (t.categoryId.map(autoStarCategories.contains) ?? false)
            if starred, settings.dayBeforeStarred {
                add("eve-\(t.id)", morning(due.adding(days: -1)), t,
                    "Tomorrow\(t.dueTime.map { " at " + Self.format($0) } ?? "") · \(where_(t))")
            }
        }
        if settings.workBlocks {
            let horizon = end.startOfDay(in: timeZone)
            for b in blocks where b.deletedAt == nil && b.startsAt > now && b.startsAt < horizon {
                // A repeating task's block belongs to an occurrence.
                let key = b.occurrenceKey ?? LocalDate(b.startsAt, in: timeZone).description
                let task = byId[b.taskId] ?? byId[OccurrenceRegistry.id(series: b.taskId, key: key)]
                guard let task, !task.status.isClosed else { continue }
                let minutes = Int(b.endsAt.timeIntervalSince(b.startsAt) / 60)
                add("block-\(b.id)", b.startsAt, task, "Time to work on this · \(minutes) min")
            }
        }
        return Array(out.sorted { $0.date < $1.date }.prefix(limit))
    }

    /// Everything `plan` needs, read in one go.
    public static func plan(_ db: Database, now: Date = Date(), timeZone: TimeZone = .current,
                            settings: Settings = Settings()) throws -> [Reminder] {
        let tasks = try TaskItem.live().filter(Column("parent_task_id") == nil).fetchAll(db)
        let overrides = try OccurrenceOverride.live().fetchAll(db)
        let blocks = try ScheduleBlock.live().filter(Column("starts_at") > now).fetchAll(db)
        let autoStar = Set(try TaskCategory.live().filter(Column("auto_star") == true).fetchAll(db).map(\.id))
        let names = Dictionary(uniqueKeysWithValues: try Container.live().fetchAll(db).map { ($0.id, $0.name) })
        // Hidden containers stay quiet.
        let hidden = Set(try Container.live().filter(Column("archived_at") != nil).fetchAll(db).map(\.id))
        return plan(tasks: tasks.filter { !($0.containerId.map(hidden.contains) ?? false) },
                    overrides: overrides, blocks: blocks, autoStarCategories: autoStar,
                    containerNames: names, now: now, timeZone: timeZone, settings: settings)
    }

    static func format(_ t: LocalTime) -> String {
        let h = t.hour % 12 == 0 ? 12 : t.hour % 12
        let m = t.minute == 0 ? "" : String(format: ":%02d", t.minute)
        return "\(h)\(m) \(t.hour < 12 ? "AM" : "PM")"
    }
}
