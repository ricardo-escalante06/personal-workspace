import Foundation

/// A fake server for tests and SwiftUI previews. Behaves like PostgREST upsert:
/// stores whole rows by id and stamps a strictly increasing server `updated_at`.
/// It does not enforce RLS or triggers; those are covered by the SQL tests.
public actor InMemorySyncRemote: SyncRemote {
    private var tables: [String: [String: [String: Any]]] = [:]
    private var clock: Date
    public private(set) var pushCount = 0
    public var failNextPush = false

    public init(start: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.clock = start
    }

    public func setFailNextPush(_ value: Bool) { failNextPush = value }

    public func push(table: String, rows: Data) async throws -> Data {
        if failNextPush {
            failNextPush = false
            throw URLError(.notConnectedToInternet)
        }
        pushCount += 1
        guard let objects = try JSONSerialization.jsonObject(with: rows) as? [[String: Any]] else { return Data("[]".utf8) }
        var stored: [[String: Any]] = []
        for var object in objects {
            guard let id = object["id"] as? String else { continue }
            clock = clock.addingTimeInterval(0.01)
            object["updated_at"] = ISODate.format(clock)
            if let existing = tables[table]?[id.lowercased()], let created = existing["created_at"] {
                object["created_at"] = created  // server keeps the original
            }
            tables[table, default: [:]][id.lowercased()] = object
            stored.append(object)
        }
        return try JSONSerialization.data(withJSONObject: stored)
    }

    public func pull(table: String, after: Date?, limit: Int) async throws -> Data {
        let rows = (tables[table] ?? [:]).values
            .compactMap { row -> (Date, [String: Any])? in
                guard let s = row["updated_at"] as? String, let d = ISODate.parse(s) else { return nil }
                return (d, row)
            }
            .filter { after == nil || $0.0 > after! }
            .sorted { $0.0 < $1.0 }
            .prefix(limit)
            .map(\.1)
        return try JSONSerialization.data(withJSONObject: Array(rows))
    }

    /// Test helper: the stored row as JSON.
    public func rowJSON(_ table: String, _ id: UUID) -> Data? {
        tables[table]?[id.lowercased].flatMap { try? JSONSerialization.data(withJSONObject: $0) }
    }

    public func rowCount(_ table: String) -> Int {
        tables[table]?.count ?? 0
    }
}
