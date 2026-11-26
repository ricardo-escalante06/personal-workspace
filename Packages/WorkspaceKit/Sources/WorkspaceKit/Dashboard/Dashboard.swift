import Foundation
import GRDB

/// Everything a scoped dashboard shows (DESIGN.md §4.2), computed from one
/// fetch of the scope's tasks and schedule blocks. Pure and testable: the UI
/// only renders this.
public struct DashboardData: Sendable, Equatable {
    public var metrics: Metrics
    /// One row per task: scheduled today or due today (done ones stay, struck through).
    public var today: [TodayItem]
    /// Open tasks whose deadline has passed.
    public var overdue: [TaskItem]
    /// Deadlines and work blocks from tomorrow through the next 7 days (drives metrics).
    public var upcoming: [UpcomingItem]
    /// Open tasks with a deadline from tomorrow through the next 14 days, soonest first.
    /// Deadlines only: work blocks are already visible in the week strip.
    public var dueSoon: [TaskItem]
    /// Starred open tasks (by hand, or tagged with an auto-star tag like Exam), soonest first.
    public var starred: [TaskItem]
    /// Seven days starting at the requested week start.
    public var week: [WeekDay]
    /// Top-level tasks in scope (subtasks are shown under their parent).
    public var tasks: [TaskItem]
    /// Subtask counts per parent: (done, total).
    public var subtaskProgress: [UUID: SubtaskProgress]

    public static let empty = DashboardData(
        metrics: Metrics(), today: [], overdue: [], upcoming: [], dueSoon: [], starred: [], week: [], tasks: [], subtaskProgress: [:]
    )
}

public struct SubtaskProgress: Sendable, Equatable {
    public var done: Int
    public var total: Int
}

public struct Metrics: Sendable, Equatable {
    public var dueToday = 0
    public var scheduledToday = 0
    public var overdue = 0
    public var next7Days = 0
    public var completedToday = 0
    /// Done / (all non-cancelled) top-level tasks in scope.
    public var progress: Double = 0
    public init() {}
}

public struct TodayItem: Identifiable, Sendable, Equatable {
    public var task: TaskItem
    /// Today's work blocks for this task (may be empty if it's only due today).
    public var blocks: [ScheduleBlock]
    public var isDueToday: Bool
    public var id: UUID { task.id }

    /// Here only for a work session (not due today): its checkbox is the session's.
    public var isSessionOnly: Bool { !isDueToday && !blocks.isEmpty }
    public var sessionDone: Bool { !blocks.isEmpty && blocks.allSatisfy { $0.completedAt != nil } }
    /// Checked in Today: the task is done, or (session-only) today's sessions are.
    public var isChecked: Bool { task.status == .done || (isSessionOnly && sessionDone) }

    /// Earliest block start, or the due time, for ordering.
    public var sortTime: Date?
}

public struct UpcomingItem: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case deadline
        case block(ScheduleBlock)
    }
    public var task: TaskItem
    public var kind: Kind
    public var date: LocalDate
    /// Exact time when known (timed deadline or block start).
    public var time: Date?

    public var id: String {
        switch kind {
        case .deadline: "due-\(task.id)"
        case .block(let b): "block-\(b.id)"
        }
    }
}

public struct WeekDay: Identifiable, Sendable, Equatable {
    public var date: LocalDate
    public var chips: [WeekChip]
    public var id: LocalDate { date }
}

public struct WeekChip: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// Deadline on this day (flag). `time` set for timed deadlines.
        case due(time: LocalTime?)
        /// A planned work block starting on this day.
        case scheduled(ScheduleBlock)
    }
    public var task: TaskItem
    public var kind: Kind
    public var id: String {
        switch kind {
        case .due: "due-\(task.id)"
        case .scheduled(let b): "block-\(b.id)"
        }
    }
    public var isDone: Bool {
        if task.status == .done { return true }
        if case .scheduled(let b) = kind { return b.completedAt != nil }
        return false
    }
}

public enum Dashboard {
    /// Loads and computes dashboard data for `scope` (nil = All Workspace).
    public static func fetch(
        _ db: Database,
        scope: UUID?,
        weekStart: LocalDate,
        now: Date = Date(),
        timeZone: TimeZone = .current
    ) throws -> DashboardData {
        let today = LocalDate(now, in: timeZone)
        let tasks = try ScopeQuery.tasks(in: scope).fetchAll(db)
        let rangeStart = min(weekStart, today).startOfDay(in: timeZone)
        let rangeEnd = max(weekStart.adding(days: 7), today.adding(days: 8)).startOfDay(in: timeZone)
        let blocks = try ScopeQuery.scheduleBlocks(in: scope, from: rangeStart, to: rangeEnd).fetchAll(db)
        let autoStar = Set(try TaskCategory.live().filter(Column("auto_star") == true).fetchAll(db).map(\.id))
        let seriesIds = tasks.filter(\.isRecurring).map(\.id)
        let overrides = seriesIds.isEmpty ? [] :
            try OccurrenceOverride.live().filter(seriesIds.contains(Column("task_id"))).fetchAll(db)
        return build(tasks: tasks, blocks: blocks, weekStart: weekStart, now: now, timeZone: timeZone,
                     autoStarCategories: autoStar, overrides: overrides)
    }

    public static func build(
        tasks allTasks: [TaskItem],
        blocks: [ScheduleBlock],
        weekStart: LocalDate,
        now: Date,
        timeZone: TimeZone,
        autoStarCategories: Set<UUID> = [],
        overrides: [OccurrenceOverride] = []
    ) -> DashboardData {
        let today = LocalDate(now, in: timeZone)
        func day(of date: Date) -> LocalDate { LocalDate(date, in: timeZone) }
        let seriesList = allTasks.filter { $0.isRecurring && $0.deletedAt == nil && $0.status != .cancelled }
        // Repeating tasks become their occurrences: missed ones from the last 30 days
        // (they stay overdue until done or skipped) through the visible week and Due soon.
        let windowStart = min(today.adding(days: -30), weekStart)
        let windowEnd = max(weekStart.adding(days: 6), today.adding(days: 14))
        let expanded = Occurrences.expandAll(allTasks, overrides: overrides, from: windowStart, through: windowEnd)
        let liveTasks = expanded.filter { $0.deletedAt == nil && $0.status != .cancelled }
        var byId = Dictionary(liveTasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for s in seriesList { byId[s.id] = s }
        // Work blocks: a repeating task's block goes with its occurrence (by key, or by day).
        var blocksByTask: [UUID: [ScheduleBlock]] = [:]
        let instancesBySeries = Dictionary(grouping: liveTasks.filter(\.isOccurrence), by: { $0.occurrenceOf! })
        for b in blocks where b.deletedAt == nil && byId[b.taskId] != nil {
            if let instances = instancesBySeries[b.taskId] {
                let match = instances.first { $0.occurrenceKey == b.occurrenceKey }
                    ?? instances.first { b.occurrenceKey == nil && $0.dueDate == day(of: b.startsAt) }
                if let match { blocksByTask[match.id, default: []].append(b) }
            } else if byId[b.taskId]?.isRecurring == false {
                blocksByTask[b.taskId, default: []].append(b)
            }
        }
        let currentBySeries: [UUID: TaskItem] = Dictionary(uniqueKeysWithValues: seriesList.compactMap { s in
            Occurrences.current(s, overrides: overrides.filter { $0.taskId == s.id }, today: today).map { (s.id, $0) }
        })
        /// Lists that show what's next (Due soon, Starred) show one occurrence per series.
        func firstPerSeries(_ list: [TaskItem]) -> [TaskItem] {
            var seen = Set<UUID>()
            return list.filter { t in t.occurrenceOf.map { seen.insert($0).inserted } ?? true }
        }

        // Subtasks roll up into their parent.
        var subtaskProgress: [UUID: SubtaskProgress] = [:]
        for t in liveTasks {
            guard let parent = t.parentTaskId else { continue }
            var p = subtaskProgress[parent] ?? SubtaskProgress(done: 0, total: 0)
            p.total += 1
            if t.status == .done { p.done += 1 }
            subtaskProgress[parent] = p
        }
        for t in liveTasks where t.isOccurrence { subtaskProgress[t.id] = subtaskProgress[t.occurrenceOf!] }
        // Task lists: one row per repeating task (its current occurrence).
        let topLevel = liveTasks.filter { !$0.isOccurrence && ($0.parentTaskId == nil || byId[$0.parentTaskId!] == nil) }
            + seriesList.compactMap { s in s.parentTaskId == nil ? currentBySeries[s.id] : nil }

        // Today: one row per task, however many blocks it has.
        var todayItems: [TodayItem] = []
        for task in liveTasks {
            let todaysBlocks = (blocksByTask[task.id] ?? []).filter { day(of: $0.startsAt) == today }.sorted { $0.startsAt < $1.startsAt }
            let dueToday = task.dueDate == today
            guard dueToday || !todaysBlocks.isEmpty else { continue }
            todayItems.append(TodayItem(
                task: task, blocks: todaysBlocks, isDueToday: dueToday,
                sortTime: todaysBlocks.first?.startsAt ?? (task.dueTime != nil ? task.dueInstant(in: timeZone) : nil)
            ))
        }
        todayItems.sort { a, b in
            // Open before done; then timed (by time) before untimed; then title.
            let ad = a.isChecked, bd = b.isChecked
            if ad != bd { return !ad }
            switch (a.sortTime, b.sortTime) {
            case let (x?, y?) where x != y: return x < y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.task.title.localizedStandardCompare(b.task.title) == .orderedAscending
            }
        }

        let overdue = liveTasks
            .filter { !$0.status.isClosed && ($0.dueDate.map { $0 < today } ?? false) }
            .sorted { ($0.dueDate!, $0.title) < ($1.dueDate!, $1.title) }

        // Upcoming: tomorrow … today+7.
        let upcomingEnd = today.adding(days: 7)
        var upcoming: [UpcomingItem] = []
        for task in liveTasks where !task.status.isClosed {
            if let due = task.dueDate, due > today, due <= upcomingEnd {
                upcoming.append(UpcomingItem(task: task, kind: .deadline, date: due,
                                             time: task.dueTime != nil ? task.dueInstant(in: timeZone) : nil))
            }
            for b in blocksByTask[task.id] ?? [] {
                let d = day(of: b.startsAt)
                if d > today, d <= upcomingEnd {
                    upcoming.append(UpcomingItem(task: task, kind: .block(b), date: d, time: b.startsAt))
                }
            }
        }
        upcoming.sort { a, b in
            if a.date != b.date { return a.date < b.date }
            switch (a.time, b.time) {
            case let (x?, y?) where x != y: return x < y
            case (nil, _?): return true   // all-day deadlines first within a day
            case (_?, nil): return false
            default: return a.task.title.localizedStandardCompare(b.task.title) == .orderedAscending
            }
        }

        let dueSoonEnd = today.adding(days: 14)
        let dueSoon = firstPerSeries(liveTasks
            .filter { t in !t.status.isClosed && (t.dueDate.map { $0 > today && $0 <= dueSoonEnd } ?? false) }
            .sorted { a, b in
                if a.dueDate != b.dueDate { return a.dueDate! < b.dueDate! }
                let at = a.dueTime?.secondsSinceMidnight ?? -1, bt = b.dueTime?.secondsSinceMidnight ?? -1
                if at != bt { return at < bt }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            })

        // Starred (or auto-starred, like Exam) and due in the same two weeks as Due soon.
        let starred = firstPerSeries(liveTasks
            .filter { t in
                !t.status.isClosed && (t.isStarred || t.categoryId.map(autoStarCategories.contains) == true)
                    && (t.dueDate.map { $0 >= today && $0 <= dueSoonEnd } ?? false)
            }
            .sorted { a, b in
                if a.dueDate != b.dueDate { return a.dueDate! < b.dueDate! }
                return a.title.localizedStandardCompare(b.title) == .orderedAscending
            })

        // Week strip.
        var week: [WeekDay] = []
        for offset in 0..<7 {
            let date = weekStart.adding(days: offset)
            var chips: [WeekChip] = []
            for task in liveTasks where task.dueDate == date {
                chips.append(WeekChip(task: task, kind: .due(time: task.dueTime)))
            }
            for task in liveTasks {
                for b in blocksByTask[task.id] ?? [] where day(of: b.startsAt) == date {
                    chips.append(WeekChip(task: task, kind: .scheduled(b)))
                }
            }
            chips.sort { a, b in
                func key(_ c: WeekChip) -> (Int, Int) {
                    switch c.kind {
                    case .due(nil): return (0, 0)                      // all-day deadlines on top
                    case .due(let t?): return (1, t.secondsSinceMidnight)
                    case .scheduled(let blk):
                        let start = blk.startsAt.timeIntervalSince(date.startOfDay(in: timeZone))
                        return (1, Int(start))
                    }
                }
                let ka = key(a), kb = key(b)
                if ka != kb { return ka < kb }
                return a.task.title.localizedStandardCompare(b.task.title) == .orderedAscending
            }
            week.append(WeekDay(date: date, chips: chips))
        }

        // Metrics count unique tasks, never blocks.
        var m = Metrics()
        m.dueToday = liveTasks.filter { $0.dueDate == today && !$0.status.isClosed }.count
        m.scheduledToday = Set(todayItems.filter { !$0.blocks.isEmpty && !$0.isChecked && !$0.task.status.isClosed }.map(\.id)).count
        m.overdue = overdue.count
        m.next7Days = Set(upcoming.map { $0.task.occurrenceOf ?? $0.task.id }).count
        m.completedToday = liveTasks.filter { $0.completedAt.map { day(of: $0) == today } ?? false }.count
        let countable = topLevel
        m.progress = countable.isEmpty ? 0 : Double(countable.filter { $0.status == .done }.count) / Double(countable.count)

        return DashboardData(
            metrics: m, today: todayItems, overdue: overdue, upcoming: upcoming, dueSoon: dueSoon, starred: starred,
            week: week, tasks: topLevel, subtaskProgress: subtaskProgress
        )
    }

    /// The first day of the week containing `date` (Sunday-start by default).
    public static func weekStart(containing date: LocalDate, firstWeekday: Int = 1) -> LocalDate {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let d = date.startOfDay(in: calendar.timeZone)
        let weekday = calendar.component(.weekday, from: d)  // 1 = Sunday
        let back = (weekday - firstWeekday + 7) % 7
        return date.adding(days: -back)
    }
}
