import Foundation
import GRDB

/// A class's assignment series: "HW {n}, 12 of them, due Fridays 11:59 PM" (DESIGN.md §6.2).
/// The tasks it creates are ordinary tasks with `generatedByRuleId` + `seriesIndex`.
public struct AssignmentRule: SyncRecord, Hashable {
    public static let databaseTableName = "assignment_rules"

    public var id: UUID
    public var ownerId: UUID?
    public var containerId: UUID
    public var categoryId: UUID?
    /// "HW {n}". Without `{n}` the number is appended: "Lab" → "Lab 1".
    public var titlePattern: String
    public var startNumber: Int
    public var count: Int?
    public var firstDueDate: LocalDate?
    public var dueTime: LocalTime?
    /// {"every": 1, "unit": "week", "skip": ["2026-11-27"]}
    public var `repeat`: JSONValue
    public var estimatedMinutes: Int?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), ownerId: UUID? = nil, containerId: UUID, categoryId: UUID? = nil,
        titlePattern: String, startNumber: Int = 1, count: Int? = nil, firstDueDate: LocalDate? = nil,
        dueTime: LocalTime? = nil, repeat: JSONValue = .object(["every": .number(1), "unit": .string("week")]),
        estimatedMinutes: Int? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id; self.ownerId = ownerId; self.containerId = containerId; self.categoryId = categoryId
        self.titlePattern = titlePattern; self.startNumber = startNumber; self.count = count
        self.firstDueDate = firstDueDate; self.dueTime = dueTime; self.repeat = `repeat`
        self.estimatedMinutes = estimatedMinutes
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case containerId = "container_id"
        case categoryId = "category_id"
        case titlePattern = "title_pattern"
        case startNumber = "start_number"
        case count
        case firstDueDate = "first_due_date"
        case dueTime = "due_time"
        case `repeat`
        case estimatedMinutes = "estimated_minutes"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }

    // MARK: Repeat settings

    /// Weeks between due dates (1 = weekly, 2 = every other week).
    public var everyWeeks: Int {
        get {
            if case .object(let o) = `repeat`, case .number(let n)? = o["every"] { return max(1, Int(n)) }
            return 1
        }
        set { setRepeat("every", .number(Double(max(1, newValue)))) }
    }

    /// Weeks with no assignment (e.g. Thanksgiving): due dates that land here are skipped.
    public var skippedDates: [LocalDate] {
        get {
            guard case .object(let o) = `repeat`, case .array(let a)? = o["skip"] else { return [] }
            return a.compactMap { if case .string(let s) = $0 { LocalDate(string: s) } else { nil } }
        }
        set { setRepeat("skip", .array(newValue.sorted().map { .string($0.description) })) }
    }

    private mutating func setRepeat(_ key: String, _ value: JSONValue) {
        var o: [String: JSONValue] = [:]
        if case .object(let existing) = `repeat` { o = existing }
        o["unit"] = .string("week")
        o[key] = value
        `repeat` = .object(o)
    }

    /// What the series produces: title and due date for each position.
    public struct Item: Sendable, Equatable {
        public var index: Int
        public var title: String
        public var dueDate: LocalDate
    }

    public func title(number n: Int) -> String {
        let pattern = titlePattern.trimmingCharacters(in: .whitespaces)
        return pattern.contains("{n}") ? pattern.replacingOccurrences(of: "{n}", with: "\(n)") : "\(pattern) \(n)"
    }

    /// Due dates step by `everyWeeks`; a date in `skippedDates` moves the rest of the
    /// series back a week (the numbering continues: HW 5 is due after the break).
    public func items() -> [Item] {
        guard let first = firstDueDate, let count, count > 0 else { return [] }
        let skipped = Set(skippedDates)
        var out: [Item] = []
        var date = first
        var guardrail = 0
        while out.count < count, guardrail < count + 60 {
            guardrail += 1
            if !skipped.contains(date) {
                out.append(Item(index: out.count, title: title(number: startNumber + out.count), dueDate: date))
            }
            date = date.adding(days: 7 * everyWeeks)
        }
        return out
    }
}

extension WorkspaceStore {
    /// Creates or updates a series and brings its tasks in line with it:
    /// new positions get tasks, existing ones get the new title/date/tag unless you
    /// edited that field by hand (`detachedFields`), extra open ones are removed.
    /// Tasks you deleted stay deleted; finished tasks are never removed.
    @discardableResult
    public func saveAssignmentSeries(_ rule: AssignmentRule, timeZone: TimeZone = .current) throws -> AssignmentRule {
        try db.write { db in
            var rule = rule
            rule.titlePattern = rule.titlePattern.trimmingCharacters(in: .whitespaces)
            guard !rule.titlePattern.isEmpty else { throw WorkspaceError.invalidTitle }
            try Self.save(&rule, in: db)
            try Self.applySeries(rule, in: db, timeZone: timeZone)
            return rule
        }
    }

    static func applySeries(_ rule: AssignmentRule, in db: Database, timeZone: TimeZone) throws {
        let items = rule.items()
        let existing = try TaskItem.filter(Column("generated_by_rule_id") == rule.id).fetchAll(db)
        var byIndex: [Int: TaskItem] = [:]
        for t in existing {
            guard let i = t.seriesIndex else { continue }
            // Prefer a live row if there are duplicates.
            if byIndex[i] == nil || byIndex[i]?.deletedAt != nil { byIndex[i] = t }
        }
        var lastRank = try String.fetchOne(
            db, TaskItem.live().filter(Column("container_id") == rule.containerId).select(max(Column("sort_rank")))
        )
        for item in items {
            if var t = byIndex[item.index] {
                guard t.deletedAt == nil else { continue }
                let before = t
                if !t.detachedFields.contains("title") { t.title = item.title }
                if !t.detachedFields.contains("due") {
                    t.dueDate = item.dueDate
                    t.dueTime = rule.dueTime
                    t.dueTz = rule.dueTime == nil ? nil : (t.dueTz ?? timeZone.identifier)
                }
                if !t.detachedFields.contains("category") { t.categoryId = rule.categoryId }
                if t != before { try save(&t, in: db) }
            } else {
                let rank = Rank.between(lastRank, nil)
                lastRank = rank
                try createTask(TaskItem(
                    containerId: rule.containerId, title: item.title, categoryId: rule.categoryId,
                    dueDate: item.dueDate, dueTime: rule.dueTime,
                    dueTz: rule.dueTime == nil ? nil : timeZone.identifier,
                    estimatedMinutes: rule.estimatedMinutes, sortRank: rank,
                    generatedByRuleId: rule.id, seriesIndex: item.index
                ), in: db)
            }
        }
        // Positions past the new end: remove the ones not started or done.
        let now = Date()
        for var t in existing where t.deletedAt == nil && (t.seriesIndex ?? 0) >= items.count && !t.status.isClosed {
            t.deletedAt = now
            try save(&t, in: db)
        }
    }

    /// Deletes the series. With `removeOpenTasks`, its unfinished tasks go too.
    public func deleteAssignmentSeries(_ id: UUID, removeOpenTasks: Bool) throws {
        try db.write { db in
            guard var rule = try AssignmentRule.live().filter(id: id).fetchOne(db) else { return }
            let now = Date()
            rule.deletedAt = now
            try Self.save(&rule, in: db)
            let tasks = try TaskItem.live().filter(Column("generated_by_rule_id") == id).fetchAll(db)
            for var t in tasks {
                if removeOpenTasks && !t.status.isClosed { t.deletedAt = now } else { t.generatedByRuleId = nil }
                try Self.save(&t, in: db)
            }
        }
    }
}
