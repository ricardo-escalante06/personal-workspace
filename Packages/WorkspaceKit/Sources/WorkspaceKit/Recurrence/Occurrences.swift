import Foundation
import GRDB

/// Occurrences of repeating tasks are computed, never stored (DESIGN.md §8). Each one
/// appears in the UI as a TaskItem copy with its own stable id; this registry maps
/// that id back to (series, key) so completing, moving or skipping it writes an
/// override on the series instead of a new task.
public final class OccurrenceRegistry: @unchecked Sendable {
    public static let shared = OccurrenceRegistry()
    private let lock = NSLock()
    private var map: [UUID: (series: UUID, key: String)] = [:]

    public func resolve(_ id: UUID) -> (series: UUID, key: String)? {
        lock.lock(); defer { lock.unlock() }
        return map[id]
    }

    func register(_ id: UUID, series: UUID, key: String) {
        lock.lock(); defer { lock.unlock() }
        map[id] = (series, key)
    }

    /// Same series + key → same id, on every device and every launch.
    public static func id(series: UUID, key: String) -> UUID {
        var bytes = withUnsafeBytes(of: series.uuid) { Array($0) }
        var hash: UInt64 = 0xcbf29ce484222325
        for b in key.utf8 { hash = (hash ^ UInt64(b)) &* 0x100000001b3 }
        for i in 0..<8 { bytes[8 + i] ^= UInt8((hash >> (8 * UInt64(i))) & 0xff) }
        bytes[6] = (bytes[6] & 0x0f) | 0x80   // mark: never a v4 UUID, so never a real row id
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        shared.register(id, series: series, key: key)
        return id
    }
}

public enum Occurrences {
    /// The series' rule (nil for a task that doesn't repeat).
    public static func rule(of task: TaskItem) -> RepeatRule? {
        task.rrule.flatMap(RepeatRule.init(rrule:))
    }

    public static func anchor(of task: TaskItem) -> LocalDate? {
        task.rruleAnchor ?? task.dueDate
    }

    /// One occurrence as a task: the series' fields with this date, plus whatever the
    /// override changed. Skipped ones still come back (callers filter them).
    public static func instance(of series: TaskItem, key: String, override o: OccurrenceOverride?) -> TaskItem {
        var t = series
        t.id = OccurrenceRegistry.id(series: series.id, key: key)
        t.occurrenceOf = series.id
        t.occurrenceKey = key
        t.dueDate = o?.dueDate ?? LocalDate(string: key)
        t.dueTime = o?.dueTime ?? series.dueTime
        if let title = o?.title { t.title = title }
        t.status = o?.status ?? .notStarted
        t.completedAt = o?.completedAt
        t.startDate = nil
        return t
    }

    /// Occurrences of `series` whose date falls in `from…through` (moved ones count where
    /// they were moved to). Skipped occurrences are left out.
    public static func expand(_ series: TaskItem, overrides: [OccurrenceOverride],
                              from: LocalDate, through: LocalDate) -> [TaskItem] {
        guard let rule = rule(of: series), let anchor = anchor(of: series) else { return [] }
        let byKey = Dictionary(overrides.filter { $0.deletedAt == nil }.map { ($0.occurrenceKey, $0) },
                               uniquingKeysWith: { a, b in a.updatedAt > b.updatedAt ? a : b })
        // A wider net so an occurrence moved into the window from outside it is found.
        let dates = rule.dates(anchor: anchor, from: from.adding(days: -60), through: through.adding(days: 60))
        return dates.compactMap { d in
            let key = d.description
            let o = byKey[key]
            if o?.skipped == true { return nil }
            let t = instance(of: series, key: key, override: o)
            guard let due = t.dueDate, due >= from, due <= through else { return nil }
            return t
        }
    }

    /// Replaces each repeating task in `tasks` with its occurrences in the window.
    public static func expandAll(_ tasks: [TaskItem], overrides: [OccurrenceOverride],
                                 from: LocalDate, through: LocalDate) -> [TaskItem] {
        let bySeries = Dictionary(grouping: overrides, by: \.taskId)
        return tasks.flatMap { t -> [TaskItem] in
            guard t.isRecurring, t.deletedAt == nil else { return [t] }
            return expand(t, overrides: bySeries[t.id] ?? [], from: from, through: through)
        }
    }

    /// The occurrence to show for a series in a plain list: the oldest one still open
    /// (an overdue one first), else the next one coming up.
    public static func current(_ series: TaskItem, overrides: [OccurrenceOverride], today: LocalDate) -> TaskItem? {
        let window = expand(series, overrides: overrides, from: today.adding(days: -60), through: today.adding(days: 400))
        return window.first { !$0.status.isClosed } ?? window.last
    }
}

// MARK: - Store

extension WorkspaceStore {
    /// Turns repeating on (or changes the rule), or off with `nil`.
    /// The first occurrence is the task's due date (today if it has none).
    public func setRepeat(_ taskId: UUID, _ rule: RepeatRule?, timeZone: TimeZone = .current) throws {
        try db.write { db in
            guard var t = try TaskItem.live().filter(id: taskId).fetchOne(db) else { throw WorkspaceError.notFound("Task") }
            let today = LocalDate(Date(), in: timeZone)
            if let rule {
                let anchor = t.rruleAnchor ?? t.dueDate ?? today
                t.rrule = rule.rrule
                t.rruleTz = t.rruleTz ?? timeZone.identifier
                t.rruleAnchor = anchor
                t.dueDate = anchor
                t.status = .notStarted
                t.completedAt = nil
            } else if t.isRecurring {
                // Stop repeating: keep it as one task due on the next open occurrence.
                let overrides = try OccurrenceOverride.live().filter(Column("task_id") == taskId).fetchAll(db)
                if let current = Occurrences.current(t, overrides: overrides, today: today) {
                    t.dueDate = current.dueDate
                    t.dueTime = current.dueTime
                }
                t.rrule = nil
                t.rruleTz = nil
                t.rruleAnchor = nil
            }
            try Self.save(&t, in: db)
        }
    }

    /// Writes (or updates) the override for one occurrence.
    public func updateOccurrence(_ seriesId: UUID, key: String, _ change: (inout OccurrenceOverride) -> Void) throws {
        try db.write { db in try Self.updateOccurrence(seriesId, key: key, in: db, change) }
    }

    static func updateOccurrence(_ seriesId: UUID, key: String, in db: Database,
                                 _ change: (inout OccurrenceOverride) -> Void) throws {
        var o = try OccurrenceOverride.live()
            .filter(Column("task_id") == seriesId && Column("occurrence_key") == key)
            .fetchOne(db) ?? OccurrenceOverride(taskId: seriesId, occurrenceKey: key)
        change(&o)
        try save(&o, in: db)
    }

    public func setOccurrenceStatus(_ seriesId: UUID, key: String, _ status: TaskStatus) throws {
        try updateOccurrence(seriesId, key: key) { o in
            o.status = status == .notStarted ? nil : status
            o.completedAt = status == .done ? (o.completedAt ?? Date()) : nil
        }
    }

    public func skipOccurrence(_ seriesId: UUID, key: String, skipped: Bool = true) throws {
        try updateOccurrence(seriesId, key: key) { $0.skipped = skipped }
    }

    /// Loads one occurrence as a task (the inspector, edits).
    public func occurrence(_ seriesId: UUID, key: String) throws -> TaskItem? {
        try db.read { db in
            guard let series = try TaskItem.live().filter(id: seriesId).fetchOne(db) else { return nil }
            let o = try OccurrenceOverride.live()
                .filter(Column("task_id") == seriesId && Column("occurrence_key") == key).fetchOne(db)
            return Occurrences.instance(of: series, key: key, override: o)
        }
    }

    /// Applies an edit made to one occurrence: its date, time and status stay with that
    /// occurrence; anything else (title, tag, notes, list…) changes the whole series.
    func editOccurrence(_ seriesId: UUID, key: String, timeZone: TimeZone, _ change: (inout TaskItem) throws -> Void) throws {
        guard let before = try occurrence(seriesId, key: key) else { throw WorkspaceError.notFound("Task") }
        var after = before
        try change(&after)
        let scheduled = LocalDate(string: key)
        if after.dueDate != before.dueDate || after.dueTime != before.dueTime || after.status != before.status {
            try updateOccurrence(seriesId, key: key) { o in
                if after.dueDate != before.dueDate {
                    // Clearing the date of one occurrence means "skip it".
                    if after.dueDate == nil { o.skipped = true }
                    o.dueDate = after.dueDate == scheduled ? nil : after.dueDate
                }
                if after.dueTime != before.dueTime { o.dueTime = after.dueTime }
                if after.status != before.status {
                    o.status = after.status == .notStarted ? nil : after.status
                    o.completedAt = after.status == .done ? Date() : nil
                }
            }
        }
        // Everything else belongs to the series.
        try editTask(seriesId, timeZone: timeZone) { s in
            let keep = (s.dueDate, s.dueTime, s.status, s.completedAt, s.startDate)
            var copy = after
            copy.id = s.id
            copy.occurrenceOf = nil
            copy.occurrenceKey = nil
            copy.rrule = s.rrule; copy.rruleTz = s.rruleTz; copy.rruleAnchor = s.rruleAnchor
            copy.createdAt = s.createdAt; copy.updatedAt = s.updatedAt; copy.sortRank = s.sortRank
            (copy.dueDate, copy.dueTime, copy.status, copy.completedAt, copy.startDate) = keep
            s = copy
        }
    }

    /// "This and future": ends the series before `key` and starts a new series there
    /// with `change` applied. Earlier occurrences keep the old values. From the first
    /// occurrence it just edits the whole series. Returns the new series' id.
    @discardableResult
    public func editFuture(_ seriesId: UUID, from key: String, timeZone: TimeZone = .current,
                           _ change: (inout TaskItem) throws -> Void) throws -> UUID {
        try db.write { db in
            guard var old = try TaskItem.live().filter(id: seriesId).fetchOne(db),
                  var rule = Occurrences.rule(of: old), let anchor = Occurrences.anchor(of: old),
                  let start = LocalDate(string: key) else { throw WorkspaceError.notFound("Task") }
            if start <= anchor {
                try change(&old)
                if let d = old.dueDate { old.rruleAnchor = d }
                try Self.save(&old, in: db)
                return old.id
            }
            // Occurrences already produced count against COUNT on the new series.
            let used = rule.dates(anchor: anchor, from: anchor, through: start.adding(days: -1)).count
            var newRule = rule
            if case .count(let n) = rule.end { newRule.end = .count(max(1, n - used)) }
            rule.end = .until(start.adding(days: -1))

            var next = old
            next.id = UUID()
            next.createdAt = Date()
            next.dueDate = start
            next.rruleAnchor = start
            next.rrule = newRule.rrule
            try change(&next)
            if let d = next.dueDate { next.rruleAnchor = d }
            old.rrule = rule.rrule
            try Self.save(&old, in: db)
            try Self.createTask(next, in: db)

            // Overrides for later occurrences follow them to the new series.
            for var o in try OccurrenceOverride.live().filter(Column("task_id") == seriesId).fetchAll(db)
                where (LocalDate(string: o.occurrenceKey) ?? start) >= start {
                o.taskId = next.id
                try Self.save(&o, in: db)
            }
            return next.id
        }
    }
}
