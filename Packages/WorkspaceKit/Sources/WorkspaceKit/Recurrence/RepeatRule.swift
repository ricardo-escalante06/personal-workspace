import Foundation

/// The supported repeat rules (DESIGN.md §8): daily, weekly on chosen days, monthly by
/// date or by "2nd Tuesday", yearly; every N; ending never, on a date, or after N times.
/// Stored as an RRULE string on the task; the first occurrence is the task's anchor date.
public struct RepeatRule: Equatable, Hashable, Sendable {
    public enum Frequency: String, CaseIterable, Sendable { case daily, weekly, monthly, yearly }

    public enum MonthlyMode: Equatable, Hashable, Sendable {
        /// Day of the month; -1 = last day. Days past the month's end land on its last day
        /// (the 31st repeats as Feb 28/29, Apr 30…).
        case day(Int)
        /// The nth weekday (1…4, or -1 for the last): "2nd Tuesday", "last Friday".
        case weekday(ordinal: Int, weekday: Int)
    }

    public enum End: Equatable, Hashable, Sendable {
        case never
        case until(LocalDate)
        case count(Int)
    }

    public var frequency: Frequency
    public var interval: Int
    /// Weekly only. 1 = Sunday … 7 = Saturday. Empty = the anchor's weekday.
    public var weekdays: Set<Int>
    /// Monthly only. nil = the anchor's day of the month.
    public var monthly: MonthlyMode?
    public var end: End

    public init(_ frequency: Frequency, interval: Int = 1, weekdays: Set<Int> = [],
                monthly: MonthlyMode? = nil, end: End = .never) {
        self.frequency = frequency
        self.interval = max(1, interval)
        self.weekdays = weekdays
        self.monthly = monthly
        self.end = end
    }

    // MARK: RRULE

    private static let dayCodes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]

    public init?(rrule: String) {
        var fields: [String: String] = [:]
        let body = rrule.hasPrefix("RRULE:") ? String(rrule.dropFirst(6)) : rrule
        for part in body.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
            if kv.count == 2 { fields[kv[0].uppercased()] = kv[1] }
        }
        guard let freq = fields["FREQ"].flatMap({ Frequency(rawValue: $0.lowercased()) }) else { return nil }
        self.init(freq, interval: Int(fields["INTERVAL"] ?? "1") ?? 1)
        if let byDay = fields["BYDAY"] {
            let tokens = byDay.split(separator: ",").map(String.init)
            if freq == .monthly, let t = tokens.first {
                let code = String(t.suffix(2)), ord = Int(t.dropLast(2)) ?? 1
                if let i = Self.dayCodes.firstIndex(of: code) { monthly = .weekday(ordinal: ord, weekday: i + 1) }
            } else {
                weekdays = Set(tokens.compactMap { Self.dayCodes.firstIndex(of: String($0.suffix(2))).map { $0 + 1 } })
            }
        }
        if freq == .monthly, let d = fields["BYMONTHDAY"].flatMap(Int.init) { monthly = .day(d) }
        if let c = fields["COUNT"].flatMap(Int.init) { end = .count(c) }
        if let u = fields["UNTIL"], u.count >= 8 {
            let s = u.prefix(8)
            if let date = LocalDate(string: "\(s.prefix(4))-\(s.dropFirst(4).prefix(2))-\(s.dropFirst(6).prefix(2))") {
                end = .until(date)
            }
        }
    }

    public var rrule: String {
        var parts = ["FREQ=\(frequency.rawValue.uppercased())"]
        if interval > 1 { parts.append("INTERVAL=\(interval)") }
        if frequency == .weekly, !weekdays.isEmpty {
            parts.append("BYDAY=" + weekdays.sorted().map { Self.dayCodes[$0 - 1] }.joined(separator: ","))
        }
        if frequency == .monthly {
            switch monthly {
            case .day(let d): parts.append("BYMONTHDAY=\(d)")
            case .weekday(let o, let w): parts.append("BYDAY=\(o)\(Self.dayCodes[w - 1])")
            case nil: break
            }
        }
        switch end {
        case .never: break
        case .count(let n): parts.append("COUNT=\(n)")
        case .until(let d): parts.append("UNTIL=" + d.description.replacingOccurrences(of: "-", with: ""))
        }
        return parts.joined(separator: ";")
    }

    // MARK: Occurrences

    /// Occurrence dates on or after `from` and on or before `through`, starting at
    /// `anchor` (the first one). Dates only: due times are applied per day, so DST
    /// changes never shift them.
    public func dates(anchor: LocalDate, from: LocalDate, through: LocalDate) -> [LocalDate] {
        var out: [LocalDate] = []
        var produced = 0
        let limit: Int? = if case .count(let n) = end { n } else { nil }
        let until: LocalDate? = if case .until(let d) = end { d } else { nil }
        let last = min(through, until ?? through)

        func emit(_ d: LocalDate) -> Bool {   // false = stop
            if d < anchor { return true }
            if d > last { return false }
            if let limit, produced >= limit { return false }
            produced += 1
            if d >= from { out.append(d) }
            return true
        }

        switch frequency {
        case .daily:
            var d = anchor
            while emit(d) { d = d.adding(days: interval) }

        case .weekly:
            let days = (weekdays.isEmpty ? [Self.weekday(anchor)] : weekdays).sorted()
            var weekStart = anchor.adding(days: -(Self.weekday(anchor) - 1))  // Sunday
            outer: while true {
                for wd in days where !emit(weekStart.adding(days: wd - 1)) { break outer }
                weekStart = weekStart.adding(days: 7 * interval)
                if weekStart > last { break }
            }

        case .monthly:
            var k = 0
            while true {
                let (y, m) = Self.addMonths(anchor.year, anchor.month, k * interval)
                if LocalDate(year: y, month: m, day: 1) > last { break }
                if let d = monthlyDate(y, m, anchor: anchor), !emit(d) { break }
                k += 1
            }

        case .yearly:
            var y = anchor.year
            while true {
                let d = LocalDate(year: y, month: anchor.month, day: min(anchor.day, Self.daysIn(y, anchor.month)))
                if !emit(d) { break }
                y += interval
            }
        }
        return out
    }

    /// The first occurrence on or after `date` (nil when the series has ended).
    public func next(anchor: LocalDate, onOrAfter date: LocalDate) -> LocalDate? {
        var windowEnd = max(date, anchor).adding(days: 400)
        for _ in 0..<5 {
            if let d = dates(anchor: anchor, from: date, through: windowEnd).first { return d }
            windowEnd = windowEnd.adding(days: 3650)
        }
        return nil
    }

    private func monthlyDate(_ y: Int, _ m: Int, anchor: LocalDate) -> LocalDate? {
        let len = Self.daysIn(y, m)
        switch monthly ?? .day(anchor.day) {
        case .day(let d):
            return LocalDate(year: y, month: m, day: d < 0 ? len : min(d, len))
        case .weekday(let ordinal, let weekday):
            let firstWd = Self.weekday(LocalDate(year: y, month: m, day: 1))
            let firstMatch = 1 + (weekday - firstWd + 7) % 7
            if ordinal < 0 {
                var d = firstMatch
                while d + 7 <= len { d += 7 }
                return LocalDate(year: y, month: m, day: d)
            }
            let d = firstMatch + 7 * (ordinal - 1)
            return d <= len ? LocalDate(year: y, month: m, day: d) : nil
        }
    }

    // MARK: Text

    /// "Every week on Sun", "Every 2 weeks on Mon, Wed", "Monthly on the last Friday".
    public func summary(anchor: LocalDate?) -> String {
        let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let longNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        var text: String
        switch frequency {
        case .daily:
            text = interval == 1 ? "Every day" : "Every \(interval) days"
        case .weekly:
            let days = weekdays.isEmpty ? (anchor.map { [Self.weekday($0)] } ?? []) : weekdays.sorted()
            if Set(days) == [2, 3, 4, 5, 6], interval == 1 {
                text = "Every weekday"
            } else {
                text = (interval == 1 ? "Every week" : "Every \(interval) weeks")
                if !days.isEmpty { text += " on " + days.map { names[$0 - 1] }.joined(separator: ", ") }
            }
        case .monthly:
            text = interval == 1 ? "Monthly" : "Every \(interval) months"
            switch monthly ?? anchor.map({ .day($0.day) }) {
            case .day(let d)?: text += d < 0 ? " on the last day" : " on the \(Self.ordinal(d))"
            case .weekday(let o, let w)?: text += " on the \(o < 0 ? "last" : Self.ordinal(o)) \(longNames[w - 1])"
            case nil: break
            }
        case .yearly:
            text = interval == 1 ? "Every year" : "Every \(interval) years"
        }
        switch end {
        case .never: break
        case .count(let n): text += ", \(n) times"
        case .until(let d): text += ", until \(d.startOfDay(in: .current).formatted(.dateTime.month(.abbreviated).day()))"
        }
        return text
    }

    // MARK: Calendar math (UTC, date-only)

    public static func weekday(_ d: LocalDate) -> Int {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.component(.weekday, from: d.startOfDay(in: c.timeZone))
    }

    static func daysIn(_ y: Int, _ m: Int) -> Int {
        switch m {
        case 2: return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    static func addMonths(_ y: Int, _ m: Int, _ n: Int) -> (Int, Int) {
        let total = y * 12 + (m - 1) + n
        return (total / 12, total % 12 + 1)
    }

    static func ordinal(_ n: Int) -> String {
        let suffix = (11...13).contains(n % 100) ? "th" : (["th", "st", "nd", "rd"] + Array(repeating: "th", count: 6))[n % 10]
        return "\(n)\(suffix)"
    }
}
