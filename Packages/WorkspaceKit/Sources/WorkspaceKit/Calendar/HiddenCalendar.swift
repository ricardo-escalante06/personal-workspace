import Foundation
import GRDB

/// A calendar (or a whole account) the user switched off. Synced, so hiding a
/// calendar on one device hides it on the others. Showing it again soft-deletes the row.
public struct HiddenCalendar: SyncRecord, Hashable {
    public static let databaseTableName = "hidden_calendars"

    public enum Kind: String, Codable, Sendable, DatabaseValueConvertible {
        /// `key` is a calendar id.
        case calendar
        /// `key` is an account: a Google email, or a system source title like "iCloud".
        case account
    }

    public var id: UUID
    public var ownerId: UUID?
    public var kind: Kind
    public var key: String
    public var createdAt: Date
    public var updatedAt: Date
    public var deletedAt: Date?

    public init(id: UUID = UUID(), ownerId: UUID? = nil, kind: Kind, key: String,
                createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id; self.ownerId = ownerId; self.kind = kind; self.key = key
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deletedAt = deletedAt
    }

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case id
        case ownerId = "owner_id"
        case kind
        case key
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case deletedAt = "deleted_at"
    }
    public static var remoteColumns: [String] { CodingKeys.allCases.map(\.rawValue) }
}

extension WorkspaceStore {
    /// The synced hidden sets (live rows only).
    public static func hiddenCalendars(_ db: Database) throws -> (calendars: Set<String>, accounts: Set<String>) {
        let rows = try HiddenCalendar.filter(Column("deleted_at") == nil).fetchAll(db)
        return (Set(rows.filter { $0.kind == .calendar }.map(\.key)),
                Set(rows.filter { $0.kind == .account }.map(\.key)))
    }

    /// True once any device has ever saved a hidden calendar (rows include shown-again ones).
    public func hasHiddenCalendarHistory() throws -> Bool {
        try db.read { try HiddenCalendar.fetchCount($0) > 0 }
    }

    /// Make the synced rows match these sets: add rows for newly hidden keys, retire
    /// rows for keys shown again. Duplicate rows from two devices are harmless.
    public func setHiddenCalendars(calendars: Set<String>, accounts: Set<String>) throws {
        try db.write { db in
            let live = try HiddenCalendar.filter(Column("deleted_at") == nil).fetchAll(db)
            for kind in [HiddenCalendar.Kind.calendar, .account] {
                let wanted = kind == .calendar ? calendars : accounts
                let rows = live.filter { $0.kind == kind }
                for var row in rows where !wanted.contains(row.key) {
                    row.deletedAt = Date()
                    try Self.save(&row, in: db)
                }
                let have = Set(rows.map(\.key))
                for key in wanted.subtracting(have) {
                    var row = HiddenCalendar(kind: kind, key: key)
                    try Self.save(&row, in: db)
                }
            }
        }
    }
}
