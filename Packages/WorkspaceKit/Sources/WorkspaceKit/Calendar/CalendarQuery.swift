import Foundation
import GRDB

/// Assembles what the calendar shows for a scope and date range: task work
/// blocks, task deadlines, and external events (mapped to containers).
public enum CalendarQuery {
    public struct Options: Sendable, Equatable {
        public var showDeadlines = true
        /// Tasks with a start date show a bar from it up to the day they're due.
        public var showSpans = false
        public var showEvents = true
        /// Calendar ids hidden by the user (EventKit calendar identifiers).
        public var hiddenCalendars: Set<String> = []
        /// Drawn height of a timed deadline marker.
        public var timedDeadlineLength: TimeInterval = 30 * 60
        public init() {}
    }

    /// - Parameters:
    ///   - scope: nil = everything. A container scope shows its tasks and only the
    ///     events mapped into its subtree (unmapped events stay global).
    ///   - events: external events already fetched for the range (EventKit).
    public static func items(
        _ db: Database,
        scope: UUID?,
        from start: Date,
        to end: Date,
        events: [ExternalEvent],
        options: Options = Options(),
        timeZone: TimeZone = .current
    ) throws -> [CalendarItem] {
        var items: [CalendarItem] = []

        let stored = try ScopeQuery.tasks(in: scope).fetchAll(db)
            .filter { $0.status != .cancelled }
        let seriesById = Dictionary(uniqueKeysWithValues: stored.filter(\.isRecurring).map { ($0.id, $0) })
        let overrides = seriesById.isEmpty ? [] :
            try OccurrenceOverride.live().filter(Array(seriesById.keys).contains(Column("task_id"))).fetchAll(db)
        // Repeating tasks show each occurrence in the range.
        let firstDay = LocalDate(start, in: timeZone), lastDay = LocalDate(end.addingTimeInterval(-1), in: timeZone)
        let tasks = Occurrences.expandAll(stored, overrides: overrides, from: firstDay, through: lastDay)
        let taskById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        // Work blocks
        let blocks = try ScopeQuery.scheduleBlocks(in: scope, from: start, to: end).fetchAll(db)
        for b in blocks {
            var task = taskById[b.taskId]
            if let series = seriesById[b.taskId] {
                // A repeating task's block shows under its occurrence's title and done state.
                let key = b.occurrenceKey ?? LocalDate(b.startsAt, in: timeZone).description
                task = taskById[OccurrenceRegistry.id(series: series.id, key: key)] ?? series
            }
            guard let t = task else { continue }
            items.append(CalendarItem(
                source: .block(taskId: t.id, blockId: b.id), title: t.title,
                start: b.startsAt, end: b.endsAt, isAllDay: false, containerId: t.containerId,
                isDone: t.status == .done, isTentative: false, isEditable: true, dueTime: nil, categoryId: t.categoryId
            ))
        }

        // Spans: start date → the day before it's due (the due day has its flag).
        if options.showSpans {
            let first = LocalDate(start, in: timeZone), last = LocalDate(end.addingTimeInterval(-1), in: timeZone)
            for t in tasks where !t.status.isClosed {
                guard let s = t.startDate, let due = t.dueDate, s < due, s <= last, due > first else { continue }
                items.append(CalendarItem(
                    source: .span(taskId: t.id), title: t.title,
                    start: s.startOfDay(in: timeZone), end: due.startOfDay(in: timeZone),
                    isAllDay: true, containerId: t.containerId, isDone: false,
                    isTentative: false, isEditable: true, dueTime: nil, categoryId: t.categoryId
                ))
            }
        }

        // Deadlines: date-only → all-day row; timed (e.g. "Quiz 4, 2 PM") → a marker on the
        // grid at that time. Either way it's a deadline, not a work block.
        if options.showDeadlines {
            let first = LocalDate(start, in: timeZone), last = LocalDate(end.addingTimeInterval(-1), in: timeZone)
            for t in tasks {
                guard let due = t.dueDate, due >= first, due <= last else { continue }
                if t.dueTime != nil, let instant = t.dueInstant(in: timeZone) {
                    items.append(CalendarItem(
                        source: .deadline(taskId: t.id), title: t.title,
                        start: instant, end: instant.addingTimeInterval(options.timedDeadlineLength),
                        isAllDay: false, containerId: t.containerId, isDone: t.status == .done,
                        isTentative: false, isEditable: true, dueTime: t.dueTime, categoryId: t.categoryId
                    ))
                } else {
                    items.append(CalendarItem(
                        source: .deadline(taskId: t.id), title: t.title,
                        start: due.startOfDay(in: timeZone), end: due.adding(days: 1).startOfDay(in: timeZone),
                        isAllDay: true, containerId: t.containerId, isDone: t.status == .done,
                        isTentative: false, isEditable: true, dueTime: nil, categoryId: t.categoryId
                    ))
                }
            }
        }

        // External events
        if options.showEvents {
            let mapper = try EventMapper.load(db)
            let scopePath = try scope.flatMap { try Container.fetchOne(db, id: $0)?.path }
            let paths = Dictionary(uniqueKeysWithValues: try Container.live().fetchAll(db).map { ($0.id, $0.path) })
            let hidden = try ScopeQuery.hiddenPaths(db).filter { !(scopePath ?? "").hasPrefix($0) }
            for e in events where !options.hiddenCalendars.contains(e.calendarId) {
                guard e.end > start, e.start < end else { continue }
                let mapped = mapper.containerId(for: e)
                // Events linked to a hidden class/project are hidden with it.
                if let mapped, let p = paths[mapped], hidden.contains(where: { p.hasPrefix($0) }) { continue }
                if let scopePath {
                    // In a scoped calendar, only events mapped into the scope's subtree.
                    guard let mapped, let p = paths[mapped], p.hasPrefix(scopePath) else { continue }
                }
                items.append(CalendarItem(
                    source: .event(e), title: e.title, start: e.start, end: e.end,
                    isAllDay: e.isAllDay, containerId: mapped, isDone: false,
                    isTentative: e.isTentative, isEditable: e.isWritable, dueTime: nil
                ))
            }
        }

        return items.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
    }
}
