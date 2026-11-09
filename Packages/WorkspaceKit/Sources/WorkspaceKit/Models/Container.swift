import Foundation
import GRDB

/// What a node in the workspace tree is. See DESIGN.md §2.
///
/// - `folder` organizes (Personal, School, Clubs) and never holds tasks.
/// - `list`, `class`, `project` hold tasks; class and project are lists with extras.
public enum ContainerKind: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
    case folder
    case list
    case `class`
    case project

    /// Whether tasks may be stored directly in a container of this kind.
    public var holdsTasks: Bool { self != .folder }

    /// Folders can contain anything; task-holding containers only contain projects.
    public func canContain(_ child: ContainerKind) -> Bool {
        holdsTasks ? child == .project : true
    }

    public var displayName: String {
        switch self {
        case .folder: "Folder"
        case .list: "List"
        case .class: "Class"
        case .project: "Project"
        }
    }

    /// SF Symbol used in the sidebar and headers.
    public var symbol: String {
        switch self {
        case .folder: "folder"
        case .list: "checklist"
        case .class: "graduationcap"
        case .project: "square.grid.3x1.below.line.grid.1x2"
        }
    }
}

public struct Container: SyncRecord, Hashable {
    public static let databaseTableName = "containers"

    public var id: UUID
    public var ownerId: UUID?
    public var parentId: UUID?
    public var kind: ContainerKind
    public var name: String
    /// A `ContainerColor` raw value ("plum", "steel", …).
    public var color: String
    public var icon: String?
    /// Materialized path of lowercase ids: "/<root>/<child>/". Kept current by the store.
    public var path: String
    /// Folders only: the list that quick-add from this folder writes to.
    public var defaultListId: UUID?
    public var sortRank: String
    public var archivedAt: Date?
    public var settings: JSONValue
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(),
        ownerId: UUID? = nil,
        parentId: UUID? = nil,
        kind: ContainerKind,
        name: String,
        color: String = "grey",
        icon: String? = nil,
        path: String = "",
        defaultListId: UUID? = nil,
        sortRank: String = Rank.initial,
        archivedAt: Date? = nil,
        settings: JSONValue = .emptyObject,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        deletedAt: Date? = nil
    ) {
        self.id = id
        self.ownerId = ownerId
        self.parentId = parentId
        self.kind = kind
        self.name = name
        self.color = color
        self.icon = icon
        self.path = path
        self.defaultListId = defaultListId
        self.sortRank = sortRank
        self.archivedAt = archivedAt
        self.settings = settings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }

    /// Depth in the tree (root-level containers are 1).
    public var depth: Int { path.split(separator: "/").count }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case parentId = "parent_id"
        case kind, name, color, icon, path
        case defaultListId = "default_list_id"
        case sortRank = "sort_rank"
        case archivedAt = "archived_at"
        case settings
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}

extension UUID {
    /// The form used in container paths and in Postgres text output.
    public var lowercased: String { uuidString.lowercased() }
}

/// Class extras: term dates, skip weeks, how to match its Google Calendar events.
public struct ClassTerm: SyncRecord, Hashable {
    public static let databaseTableName = "class_terms"

    public var id: UUID
    public var ownerId: UUID?
    public var containerId: UUID
    public var termStart: LocalDate?
    public var termEnd: LocalDate?
    /// [{"start": "2026-11-23", "end": "2026-11-27", "label": "Thanksgiving"}]
    public var skipRanges: JSONValue
    public var courseCode: String?
    /// Prefix that identifies this class's calendar events, e.g. "COMPSCI 61A".
    public var eventTitlePattern: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), ownerId: UUID? = nil, containerId: UUID,
        termStart: LocalDate? = nil, termEnd: LocalDate? = nil, skipRanges: JSONValue = .emptyArray,
        courseCode: String? = nil, eventTitlePattern: String? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id; self.ownerId = ownerId; self.containerId = containerId
        self.termStart = termStart; self.termEnd = termEnd; self.skipRanges = skipRanges
        self.courseCode = courseCode; self.eventTitlePattern = eventTitlePattern
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case containerId = "container_id"
        case termStart = "term_start"
        case termEnd = "term_end"
        case skipRanges = "skip_ranges"
        case courseCode = "course_code"
        case eventTitlePattern = "event_title_pattern"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}

/// Project extras: status, target date, description.
public struct ProjectMeta: SyncRecord, Hashable {
    public static let databaseTableName = "project_meta"

    public enum Status: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
        case planning, active, paused, done
    }

    public var id: UUID
    public var ownerId: UUID?
    public var containerId: UUID
    public var status: Status
    public var targetDate: LocalDate?
    public var description: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), ownerId: UUID? = nil, containerId: UUID,
        status: Status = .active, targetDate: LocalDate? = nil, description: String = "",
        createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id; self.ownerId = ownerId; self.containerId = containerId
        self.status = status; self.targetDate = targetDate; self.description = description
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case containerId = "container_id"
        case status
        case targetDate = "target_date"
        case description
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}

/// A Kanban column on a project board. Each column maps to a task status.
public struct BoardColumn: SyncRecord, Hashable {
    public static let databaseTableName = "board_columns"

    public var id: UUID
    public var ownerId: UUID?
    public var containerId: UUID
    public var name: String
    public var mapsToStatus: TaskStatus
    public var sortRank: String
    public var wipLimit: Int?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), ownerId: UUID? = nil, containerId: UUID, name: String,
        mapsToStatus: TaskStatus, sortRank: String = Rank.initial, wipLimit: Int? = nil,
        createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id; self.ownerId = ownerId; self.containerId = containerId; self.name = name
        self.mapsToStatus = mapsToStatus; self.sortRank = sortRank; self.wipLimit = wipLimit
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    /// Backlog · To do · In progress · Review · Done (DESIGN.md §4.4).
    public static let defaultColumns: [(String, TaskStatus)] = [
        ("Backlog", .notStarted),
        ("To do", .notStarted),
        ("In progress", .inProgress),
        ("Review", .inProgress),
        ("Done", .done),
    ]

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case containerId = "container_id"
        case name
        case mapsToStatus = "maps_to_status"
        case sortRank = "sort_rank"
        case wipLimit = "wip_limit"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}
