import Foundation
import WorkspaceKit

/// Short, human labels for dates and times used across rows, chips and headers.
public enum WSFormat {
    static let utc = TimeZone(identifier: "UTC")!

    /// "Today", "Tomorrow", "Yesterday", "Fri", or "Nov 20" (beyond a week).
    public static func relativeDay(_ date: LocalDate, today: LocalDate) -> String {
        if date == today { return "Today" }
        if date == today.adding(days: 1) { return "Tomorrow" }
        if date == today.adding(days: -1) { return "Yesterday" }
        let instant = date.startOfDay(in: utc)
        if date > today, date <= today.adding(days: 6) {
            return instant.formatted(Date.FormatStyle(timeZone: utc).weekday(.abbreviated))
        }
        if date.year == today.year {
            return instant.formatted(Date.FormatStyle(timeZone: utc).month(.abbreviated).day())
        }
        return instant.formatted(Date.FormatStyle(timeZone: utc).month(.abbreviated).day().year())
    }

    /// "11:59 PM", "9 AM".
    public static func time(_ t: LocalTime) -> String {
        let h12 = t.hour % 12 == 0 ? 12 : t.hour % 12
        let ampm = t.hour < 12 ? "AM" : "PM"
        return t.minute == 0 ? "\(h12) \(ampm)" : String(format: "%d:%02d %@", h12, t.minute, ampm)
    }

    public static func time(_ d: Date, in tz: TimeZone = .current) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        let comps = c.dateComponents([.hour, .minute], from: d)
        return time(LocalTime(hour: comps.hour ?? 0, minute: comps.minute ?? 0))
    }

    /// "7–8 PM", "9:30–10:15 AM", "11 AM–1 PM" (Notion Calendar style).
    public static func range(_ start: Date, _ end: Date, in tz: TimeZone = .current) -> String {
        let s = time(start, in: tz), e = time(end, in: tz)
        let sParts = s.split(separator: " "), eParts = e.split(separator: " ")
        if sParts.last == eParts.last { return "\(sParts.first!)–\(e)" }
        return "\(s)–\(e)"
    }

    /// Due label for a task row: "Fri", "Today 11:59 PM".
    public static func due(_ task: TaskItem, today: LocalDate) -> String? {
        guard let date = task.dueDate else { return nil }
        let day = relativeDay(date, today: today)
        guard let t = task.dueTime else { return day }
        return "\(day) \(time(t))"
    }

    /// "November 2026"
    public static func monthYear(_ date: LocalDate) -> String {
        date.startOfDay(in: utc).formatted(Date.FormatStyle(timeZone: utc).month(.wide).year())
    }

    /// "Sun", "Mon", …
    public static func weekdayShort(_ date: LocalDate) -> String {
        date.startOfDay(in: utc).formatted(Date.FormatStyle(timeZone: utc).weekday(.abbreviated))
    }
}
