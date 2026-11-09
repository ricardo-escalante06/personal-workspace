import Foundation
import GRDB

/// "Events whose title starts with COMPSCI 61A belong to CS61A" (DESIGN.md §7.3).
public struct EventMappingRule: SyncRecord, Hashable {
    public static let databaseTableName = "event_mapping_rules"

    public enum MatchType: String, Codable, Sendable, CaseIterable, DatabaseValueConvertible {
        case calendar
        case titlePrefix = "title_prefix"
        case titleRegex = "title_regex"
    }

    public var id: UUID
    public var ownerId: UUID?
    public var matchType: MatchType
    public var matchValue: String
    public var containerId: UUID
    public var priority: Int
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), ownerId: UUID? = nil, matchType: MatchType, matchValue: String,
                containerId: UUID, priority: Int = 0,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.ownerId = ownerId; self.matchType = matchType; self.matchValue = matchValue
        self.containerId = containerId; self.priority = priority
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case matchType = "match_type"
        case matchValue = "match_value"
        case containerId = "container_id"
        case priority
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}

/// A manual "Assign to…" for one external event (or one occurrence of it).
public struct EventLink: SyncRecord, Hashable {
    public static let databaseTableName = "event_links"

    public var id: UUID
    public var ownerId: UUID?
    public var externalEventKey: String
    public var occurrenceStart: Date?
    public var containerId: UUID?
    public var taskId: UUID?
    public var notes: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), ownerId: UUID? = nil, externalEventKey: String, occurrenceStart: Date? = nil,
                containerId: UUID? = nil, taskId: UUID? = nil, notes: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.ownerId = ownerId; self.externalEventKey = externalEventKey
        self.occurrenceStart = occurrenceStart; self.containerId = containerId; self.taskId = taskId
        self.notes = notes; self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case externalEventKey = "external_event_key"
        case occurrenceStart = "occurrence_start"
        case containerId = "container_id"
        case taskId = "task_id"
        case notes
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}

/// Decides which container (if any) an external event belongs to.
/// Precedence: manual link → explicit rules (by priority) → class title patterns.
public struct EventMapper: Sendable {
    struct Pattern: Sendable {
        var prefix: String
        var containerId: UUID
    }

    var links: [String: UUID]           // event key → container
    var rules: [EventMappingRule]
    var classPatterns: [Pattern]

    public init(links: [EventLink], rules: [EventMappingRule], classTerms: [ClassTerm]) {
        var map: [String: UUID] = [:]
        for l in links where l.deletedAt == nil {
            if let c = l.containerId { map[l.externalEventKey] = c }
        }
        self.links = map
        self.rules = rules.filter { $0.deletedAt == nil }.sorted { $0.priority > $1.priority }
        self.classPatterns = classTerms.compactMap { t in
            guard t.deletedAt == nil, let p = t.eventTitlePattern?.trimmingCharacters(in: .whitespaces), !p.isEmpty
            else { return nil }
            return Pattern(prefix: p, containerId: t.containerId)
        }
        // Longest prefix first, so "COMPSCI 61AB" wins over "COMPSCI 61A".
        .sorted { $0.prefix.count > $1.prefix.count }
    }

    public static func load(_ db: Database) throws -> EventMapper {
        try EventMapper(
            links: EventLink.live().fetchAll(db),
            rules: EventMappingRule.live().fetchAll(db),
            classTerms: ClassTerm.live().fetchAll(db)
        )
    }

    public func containerId(for event: ExternalEvent) -> UUID? {
        if let linked = links[event.key] { return linked }
        for rule in rules {
            switch rule.matchType {
            case .calendar:
                if event.calendarId == rule.matchValue || event.calendarTitle == rule.matchValue { return rule.containerId }
            case .titlePrefix:
                if Self.title(event.title, hasPrefix: rule.matchValue) { return rule.containerId }
            case .titleRegex:
                if event.title.range(of: rule.matchValue, options: [.regularExpression, .caseInsensitive]) != nil {
                    return rule.containerId
                }
            }
        }
        for p in classPatterns where Self.title(event.title, hasPrefix: p.prefix) {
            return p.containerId
        }
        return nil
    }

    /// Case-insensitive, whitespace-tolerant prefix match that ends on a word boundary:
    /// "COMPSCI 61A LEC" matches "compsci 61a", but "COMPSCI 61AB" does not.
    static func title(_ title: String, hasPrefix prefix: String) -> Bool {
        // Lowercase and collapse runs of whitespace so "COMPSCI  61A" == "compsci 61a".
        func normalize(_ s: String) -> [Character] {
            Array(s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " "))
        }
        let t = normalize(title), p = normalize(prefix)
        guard !p.isEmpty, t.count >= p.count, Array(t.prefix(p.count)) == p else { return false }
        guard t.count > p.count else { return true }
        let next = t[p.count]
        return !(next.isLetter || next.isNumber)
    }
}
