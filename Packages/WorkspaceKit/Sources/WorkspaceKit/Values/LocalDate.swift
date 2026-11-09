import Foundation
import GRDB

/// A calendar date with no time zone ("2026-11-13").
/// Date-only deadlines are stored this way so they never shift when you change time zones.
public struct LocalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var year: Int
    public var month: Int
    public var day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The local date of `date` as seen in `timeZone`.
    public init(_ date: Date, in timeZone: TimeZone = .current) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    public init?(string: String) {
        let parts = string.prefix(10).split(separator: "-")
        guard parts.count == 3,
              let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d)
        else { return nil }
        self.init(year: y, month: m, day: d)
    }

    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// Midnight at the start of this date in `timeZone`.
    public func startOfDay(in timeZone: TimeZone = .current) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(year: year, month: month, day: day))!
    }

    public func adding(days: Int) -> LocalDate {
        let utc = TimeZone(identifier: "UTC")!
        return LocalDate(startOfDay(in: utc).addingTimeInterval(TimeInterval(days) * 86_400), in: utc)
    }

    public static func < (a: LocalDate, b: LocalDate) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let value = LocalDate(string: string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid date \(string)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension LocalDate: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { description.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> LocalDate? {
        String.fromDatabaseValue(dbValue).flatMap(LocalDate.init(string:))
    }
}

/// A wall-clock time with no date or time zone ("23:59:00").
public struct LocalTime: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public var hour: Int
    public var minute: Int
    public var second: Int

    public init(hour: Int, minute: Int, second: Int = 0) {
        self.hour = hour
        self.minute = minute
        self.second = second
    }

    public init?(string: String) {
        let parts = string.split(separator: ":")
        guard parts.count >= 2,
              let h = Int(parts[0]), let m = Int(parts[1]),
              (0...23).contains(h), (0...59).contains(m)
        else { return nil }
        let s = parts.count > 2 ? Int(Double(parts[2]) ?? 0) : 0
        self.init(hour: h, minute: m, second: s)
    }

    public var description: String {
        String(format: "%02d:%02d:%02d", hour, minute, second)
    }

    public var secondsSinceMidnight: Int { hour * 3600 + minute * 60 + second }

    public static func < (a: LocalTime, b: LocalTime) -> Bool {
        a.secondsSinceMidnight < b.secondsSinceMidnight
    }

    public init(from decoder: Decoder) throws {
        let string = try decoder.singleValueContainer().decode(String.self)
        guard let value = LocalTime(string: string) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "Invalid time \(string)"))
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}

extension LocalTime: DatabaseValueConvertible {
    public var databaseValue: DatabaseValue { description.databaseValue }
    public static func fromDatabaseValue(_ dbValue: DatabaseValue) -> LocalTime? {
        String.fromDatabaseValue(dbValue).flatMap(LocalTime.init(string:))
    }
}
