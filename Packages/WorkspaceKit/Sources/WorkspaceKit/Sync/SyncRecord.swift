import Foundation
import GRDB

/// A row that lives in both the local SQLite store and a Supabase table.
///
/// Rules every conforming type follows:
/// - Coding keys are the snake_case column names, identical locally and in Postgres.
/// - `remoteColumns` lists *every* column, so pushes can send explicit nulls
///   (Swift's synthesized Codable omits nil values, which PostgREST would read
///   as "leave unchanged" on upsert).
/// - Rows are never hard-deleted; `deletedAt` is a tombstone that syncs.
public protocol SyncRecord: Codable, Sendable, Identifiable, FetchableRecord, PersistableRecord where ID == UUID {
    var id: UUID { get }
    var ownerId: UUID? { get set }
    var createdAt: Date { get set }
    var updatedAt: Date { get set }
    var deletedAt: Date? { get set }

    static var remoteColumns: [String] { get }
}

extension SyncRecord {
    public var isDeleted: Bool { deletedAt != nil }

    /// Live (non-tombstoned) rows.
    public static func live() -> QueryInterfaceRequest<Self> {
        filter(Column("deleted_at") == nil)
    }
}

/// JSON coders for talking to PostgREST.
public enum SyncCoding {
    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(ISODate.format(date))
        }
        e.outputFormatting = .sortedKeys
        return e
    }

    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = ISODate.parse(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid timestamp \(s)")
            }
            return date
        }
        return d
    }

    /// Encodes rows as a JSON array with every column present (nil → JSON null).
    public static func encodeRows<R: SyncRecord>(_ rows: [R]) throws -> Data {
        let data = try encoder().encode(rows)
        guard var objects = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return data
        }
        for i in objects.indices {
            for column in R.remoteColumns where objects[i][column] == nil {
                objects[i][column] = NSNull()
            }
        }
        return try JSONSerialization.data(withJSONObject: objects, options: [.sortedKeys])
    }

    public static func decodeRows<R: SyncRecord>(_ type: R.Type, from data: Data) throws -> [R] {
        try decoder().decode([R].self, from: data)
    }
}
