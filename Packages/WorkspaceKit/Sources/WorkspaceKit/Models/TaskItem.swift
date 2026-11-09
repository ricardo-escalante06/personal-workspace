import Foundation
import GRDB

public enum TaskStatus: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case notStarted = "not_started"
    case inProgress = "in_progress"
    case done
    case cancelled

    public var isClosed: Bool { self == .done || self == .cancelled }
}

/// One canonical task. Homework, quizzes, labs and milestones are categories, not types.
/// Named `TaskItem` to avoid clashing with Swift Concurrency's `Task`.
///
/// Deadline (`dueDate`/`dueTime`) and planned work (`ScheduleBlock`s) are independent:
/// moving a work block never changes the due date. See DESIGN.md §5.
public struct TaskItem: SyncRecord, Hashable {
    public static let databaseTableName = "tasks"

    public var id: UUID
    public var ownerId: UUID?
    /// nil = Inbox. Never a folder.
    public var containerId: UUID?
    public var parentTaskId: UUID?
    public var title: String
    public var notes: String
    public var categoryId: UUID?
    public var priority: Int?
    public var status: TaskStatus
    public var dueDate: LocalDate?
    public var dueTime: LocalTime?
    /// Time zone for `dueTime`; nil for date-only deadlines.
    public var dueTz: String?
    public var estimatedMinutes: Int?
    public var sourceUrl: String?
    public var boardColumnId: UUID?
    public var boardRank: String?
    public var sortRank: String
    /// Present when this task is a recurring series (occurrences are computed).
    public var rrule: String?
    public var rruleTz: String?
    public var rruleAnchor: LocalDate?
    public var generatedByRuleId: UUID?
    public var templateOriginId: UUID?
    /// Field names edited by hand on a generated task; series edits skip them.
    public var detachedFields: [String]
    public var completedAt: Date?
    /// Shows in the dashboard's Starred list (also automatic for tags with `autoStar`).
    public var isStarred: Bool
    /// When work starts; with `dueDate` it gives the task a span on the project timeline.
    public var startDate: LocalDate?
    /// A project milestone (phase). Other tasks join it through `milestoneId`.
    public var isMilestone: Bool
    public var milestoneId: UUID?
    /// Position in its assignment series (`generatedByRuleId`), 0-based.
    public var seriesIndex: Int?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        ownerId: UUID? = nil,
        containerId: UUID?,
        parentTaskId: UUID? = nil,
        title: String,
        notes: String = "",
        categoryId: UUID? = nil,
        priority: Int? = nil,
        status: TaskStatus = .notStarted,
        dueDate: LocalDate? = nil,
        dueTime: LocalTime? = nil,
        dueTz: String? = nil,
        estimatedMinutes: Int? = nil,
        sourceUrl: String? = nil,
        boardColumnId: UUID? = nil,
        boardRank: String? = nil,
        sortRank: String = Rank.initial,
        rrule: String? = nil,
        rruleTz: String? = nil,
        rruleAnchor: LocalDate? = nil,
        generatedByRuleId: UUID? = nil,
        templateOriginId: UUID? = nil,
        detachedFields: [String] = [],
        completedAt: Date? = nil,
        isStarred: Bool = false,
        startDate: LocalDate? = nil,
        isMilestone: Bool = false,
        milestoneId: UUID? = nil,
        seriesIndex: Int? = nil,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.containerId = containerId
        self.parentTaskId = parentTaskId
        self.title = title
        self.notes = notes
        self.categoryId = categoryId
        self.priority = priority
        self.status = status
        self.dueDate = dueDate
        self.dueTime = dueTime
        self.dueTz = dueTz
        self.estimatedMinutes = estimatedMinutes
        self.sourceUrl = sourceUrl
        self.boardColumnId = boardColumnId
        self.boardRank = boardRank
        self.sortRank = sortRank
        self.rrule = rrule
        self.rruleTz = rruleTz
        self.rruleAnchor = rruleAnchor
        self.generatedByRuleId = generatedByRuleId
        self.templateOriginId = templateOriginId
        self.detachedFields = detachedFields
        self.completedAt = completedAt
        self.isStarred = isStarred
        self.startDate = startDate
        self.isMilestone = isMilestone
        self.milestoneId = milestoneId
        self.seriesIndex = seriesIndex
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    public var isRecurring: Bool { rrule != nil }

    /// The deadline as an instant, or nil for no deadline. Date-only deadlines
    /// resolve to the end of that day in `timeZone`.
    public func dueInstant(in timeZone: TimeZone = .current) -> Date? {
        guard let dueDate else { return nil }
        if let dueTime {
            let tz = dueTz.flatMap(TimeZone.init(identifier:)) ?? timeZone
            return dueDate.startOfDay(in: tz).addingTimeInterval(TimeInterval(dueTime.secondsSinceMidnight))
        }
        return dueDate.adding(days: 1).startOfDay(in: timeZone).addingTimeInterval(-1)
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case containerId = "container_id"
        case parentTaskId = "parent_task_id"
        case title, notes
        case categoryId = "category_id"
        case priority, status
        case dueDate = "due_date"
        case dueTime = "due_time"
        case dueTz = "due_tz"
        case estimatedMinutes = "estimated_minutes"
        case sourceUrl = "source_url"
        case boardColumnId = "board_column_id"
        case boardRank = "board_rank"
        case sortRank = "sort_rank"
        case rrule
        case rruleTz = "rrule_tz"
        case rruleAnchor = "rrule_anchor"
        case generatedByRuleId = "generated_by_rule_id"
        case templateOriginId = "template_origin_id"
        case detachedFields = "detached_fields"
        case completedAt = "completed_at"
        case isStarred = "is_starred"
        case startDate = "start_date"
        case isMilestone = "is_milestone"
        case milestoneId = "milestone_id"
        case seriesIndex = "series_index"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}

/// A planned work session for a task. A task can have any number of these.
public struct ScheduleBlock: SyncRecord, Hashable {
    public static let databaseTableName = "task_schedule_blocks"

    public var id: UUID
    public var ownerId: UUID?
    public var taskId: UUID
    public var startsAt: Date
    public var endsAt: Date
    /// For a block attached to one occurrence of a recurring task.
    public var occurrenceKey: String?
    /// Set when the block is published to a calendar via EventKit (Milestone 2b).
    public var externalEventKey: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), ownerId: UUID? = nil, taskId: UUID, startsAt: Date, endsAt: Date,
        occurrenceKey: String? = nil, externalEventKey: String? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id; self.ownerId = ownerId; self.taskId = taskId
        self.startsAt = startsAt; self.endsAt = endsAt
        self.occurrenceKey = occurrenceKey; self.externalEventKey = externalEventKey
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case taskId = "task_id"
        case startsAt = "starts_at"
        case endsAt = "ends_at"
        case occurrenceKey = "occurrence_key"
        case externalEventKey = "external_event_key"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}

/// An exception for one occurrence of a recurring task (completed, skipped, moved…).
/// Occurrences themselves are computed from the rule and never stored. See DESIGN.md §8.
public struct OccurrenceOverride: SyncRecord, Hashable {
    public static let databaseTableName = "task_occurrence_overrides"

    public var id: UUID
    public var ownerId: UUID?
    public var taskId: UUID
    public var occurrenceKey: String
    public var status: TaskStatus?
    public var completedAt: Date?
    public var dueDate: LocalDate?
    public var dueTime: LocalTime?
    public var skipped: Bool
    public var title: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), ownerId: UUID? = nil, taskId: UUID, occurrenceKey: String,
        status: TaskStatus? = nil, completedAt: Date? = nil, dueDate: LocalDate? = nil,
        dueTime: LocalTime? = nil, skipped: Bool = false, title: String? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id; self.ownerId = ownerId; self.taskId = taskId; self.occurrenceKey = occurrenceKey
        self.status = status; self.completedAt = completedAt; self.dueDate = dueDate
        self.dueTime = dueTime; self.skipped = skipped; self.title = title
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case taskId = "task_id"
        case occurrenceKey = "occurrence_key"
        case status
        case completedAt = "completed_at"
        case dueDate = "due_date"
        case dueTime = "due_time"
        case skipped, title
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}
