import Foundation

/// ISO-8601 timestamps as exchanged with Supabase/PostgREST.
/// Postgres returns microseconds and "+00:00" offsets, which Foundation's
/// default ISO8601 parsing rejects, so parsing is done by hand.
public enum ISODate {
    /// "2026-11-08T23:24:00.123Z"
    public static func format(_ date: Date) -> String {
        date.formatted(
            Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)
        )
    }

    /// Accepts "2026-11-08T23:24:00Z", "...00.123456+00:00", "2026-11-08 23:24:00+00", etc.
    public static func parse(_ string: String) -> Date? {
        let s = Array(string.utf8)
        func int(_ from: Int, _ len: Int) -> Int? {
            guard from + len <= s.count else { return nil }
            var v = 0
            for i in from..<(from + len) {
                let c = s[i]
                guard c >= 48, c <= 57 else { return nil }
                v = v * 10 + Int(c - 48)
            }
            return v
        }
        guard s.count >= 19,
              let year = int(0, 4), s[4] == 45, let month = int(5, 2), s[7] == 45, let day = int(8, 2),
              s[10] == 84 || s[10] == 32,  // 'T' or ' '
              let hour = int(11, 2), s[13] == 58, let minute = int(14, 2), s[16] == 58, let second = int(17, 2)
        else { return nil }

        var i = 19
        var fraction = 0.0
        if i < s.count, s[i] == 46 {  // '.'
            i += 1
            var scale = 0.1
            while i < s.count, s[i] >= 48, s[i] <= 57 {
                fraction += Double(s[i] - 48) * scale
                scale /= 10
                i += 1
            }
        }

        var offsetSeconds = 0
        if i < s.count {
            let sign = s[i]
            if sign == 90 {  // 'Z'
                i += 1
            } else if sign == 43 || sign == 45 {  // '+' / '-'
                guard let oh = int(i + 1, 2) else { return nil }
                var om = 0
                var j = i + 3
                if j < s.count, s[j] == 58 { j += 1 }
                if let m = int(j, 2) { om = m }
                offsetSeconds = (oh * 3600 + om * 60) * (sign == 45 ? -1 : 1)
            } else {
                return nil
            }
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        guard let base = calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )) else { return nil }
        return base.addingTimeInterval(fraction - TimeInterval(offsetSeconds))
    }
}
