import Foundation
import GRDB

/// Arbitrary JSON for `jsonb` columns (settings, skip ranges, default subtasks…).
/// Stored locally as JSON text; sent to Supabase as a real JSON value.
public enum JSONValue: Hashable, Sendable, Codable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public static let emptyObject = JSONValue.object([:])
    public static let emptyArray = JSONValue.array([])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .number(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o[key] }
        return nil
    }
}

extension JSONValue: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(self)) ?? Data("null".utf8)
        return String(decoding: data, as: UTF8.self).databaseValue
    }

    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> JSONValue? {
        guard let text = String.fromDatabaseValue(dbValue) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }
}
