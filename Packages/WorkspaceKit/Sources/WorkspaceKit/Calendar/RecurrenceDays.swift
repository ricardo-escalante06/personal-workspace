import Foundation

/// Moving a repeating event to another weekday moves its repeat days with it.
public enum RecurrenceDays {
    /// Weekday 1 = Sunday … 7 = Saturday, shifted by `days` (wraps around).
    public static func shift(_ weekday: Int, by days: Int) -> Int {
        ((weekday - 1 + days) % 7 + 7) % 7 + 1
    }

    /// The rule cut off so its last occurrence is before `date` (for "this and following").
    public static func ending(_ rule: String, before date: Date) -> String {
        guard rule.hasPrefix("RRULE:") else { return rule }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC")!
        let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date.addingTimeInterval(-1))
        let until = String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        let parts = rule.dropFirst(6).split(separator: ";")
            .filter { !$0.hasPrefix("UNTIL=") && !$0.hasPrefix("COUNT=") }.map(String.init)
        return "RRULE:" + (parts + ["UNTIL=\(until)"]).joined(separator: ";")
    }

    /// "RRULE:FREQ=WEEKLY;BYDAY=MO,WE;UNTIL=…" with BYDAY shifted by `days`.
    /// Other lines (EXDATE…) and rules without BYDAY come back unchanged.
    public static func shiftByDay(in rule: String, by days: Int) -> String {
        let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        guard rule.hasPrefix("RRULE:"), days % 7 != 0 else { return rule }
        let parts = rule.dropFirst(6).split(separator: ";").map { part -> String in
            guard part.hasPrefix("BYDAY=") else { return String(part) }
            let shifted = part.dropFirst(6).split(separator: ",").map { token -> String in
                let code = String(token.suffix(2))
                let prefix = token.dropLast(2)  // e.g. "1" in "1MO"
                guard let i = codes.firstIndex(of: code) else { return String(token) }
                return prefix + codes[shift(i + 1, by: days) - 1]
            }
            return "BYDAY=" + shifted.joined(separator: ",")
        }
        return "RRULE:" + parts.joined(separator: ";")
    }
}
