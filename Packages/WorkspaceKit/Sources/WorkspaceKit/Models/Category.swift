import Foundation
import GRDB

/// A task label with defaults: Homework, Quiz, Exam, Lab, Milestone… (DESIGN.md §6.3).
public struct TaskCategory: SyncRecord, Hashable {
    public static let databaseTableName = "categories"

    public var id: UUID
    public var ownerId: UUID?
    public var name: String
    /// SF Symbol name.
    public var symbol: String
    public var color: String?
    public var defaultDueTime: LocalTime?
    public var defaultEstimate: Int?
    /// ["Start", "Review", "Submit"]
    public var defaultSubtasks: JSONValue
    /// Global categories are offered everywhere; others only where enabled.
    public var isGlobal: Bool
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), ownerId: UUID? = nil, name: String, symbol: String = "circle",
        color: String? = nil, defaultDueTime: LocalTime? = nil, defaultEstimate: Int? = nil,
        defaultSubtasks: JSONValue = .emptyArray, isGlobal: Bool = true,
        createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id; self.ownerId = ownerId; self.name = name; self.symbol = symbol
        self.color = color; self.defaultDueTime = defaultDueTime; self.defaultEstimate = defaultEstimate
        self.defaultSubtasks = defaultSubtasks; self.isGlobal = isGlobal
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    /// Built-in categories created on first launch.
    public static let builtIns: [(name: String, symbol: String, global: Bool)] = [
        ("Homework", "doc.text", true),
        ("Lab", "flask", true),
        ("Quiz", "questionmark.circle", true),
        ("Exam", "graduationcap", true),
        ("Project", "hammer", true),
        ("Reading", "book", true),
        ("Study", "brain.head.profile", true),
        ("Milestone", "diamond", false),
        ("General", "circle", true),
    ]

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case name, symbol, color
        case defaultDueTime = "default_due_time"
        case defaultEstimate = "default_estimate"
        case defaultSubtasks = "default_subtasks"
        case isGlobal = "is_global"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}

/// Enables a non-global category inside one container.
public struct ContainerCategory: SyncRecord, Hashable {
    public static let databaseTableName = "container_categories"

    public var id: UUID
    public var ownerId: UUID?
    public var containerId: UUID
    public var categoryId: UUID
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(
        id: UUID = UUID(), ownerId: UUID? = nil, containerId: UUID, categoryId: UUID,
        createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil
    ) {
        self.id = id; self.ownerId = ownerId; self.containerId = containerId; self.categoryId = categoryId
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case containerId = "container_id"
        case categoryId = "category_id"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}
