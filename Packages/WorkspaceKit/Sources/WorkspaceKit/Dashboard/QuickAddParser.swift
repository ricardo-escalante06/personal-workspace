import Foundation

/// Deterministic quick-add parsing (DESIGN.md §6.4). No AI.
///
///     "HW 5 cs61b fri 11:59pm #hw !2"
///     → title "HW 5", container CS61B, due Friday 23:59, category Homework, priority 2
///
/// Recognized tokens (anything else stays in the title):
///  - `#cat`        category by name prefix or alias (hw, quiz, lab…)
///  - `!0`…`!3`     priority
///  - `@name`       container by name prefix; a bare course-code word (letters + digits)
///                  also matches a task-holding container with that exact name, e.g. `cs61b`
///  - dates         today, tod, tomorrow, tmr, tmrw, mon…sun (next occurrence, today
///                  included), next fri, 11/13, nov 13, in 3 days
///  - times         11:59pm, 5pm, 5p, 17:30, noon, midnight (needs a date; defaults to today)
public struct QuickAddParser: Sendable {
    public struct ContainerOption: Sendable, Hashable {
        public var id: UUID
        public var name: String
        public var holdsTasks: Bool
        public init(id: UUID, name: String, holdsTasks: Bool) {
            self.id = id; self.name = name; self.holdsTasks = holdsTasks
        }
    }

    public struct CategoryOption: Sendable, Hashable {
        public var id: UUID
        public var name: String
        public init(id: UUID, name: String) { self.id = id; self.name = name }
    }

    public struct Token: Sendable, Equatable, Identifiable {
        public enum Kind: Sendable, Equatable { case container, category, priority, date, time }
        public var kind: Kind
        public var text: String
        /// Human label, e.g. "CS61B", "Fri Nov 13", "11:59 PM".
        public var label: String
        public var id: String { "\(kind)-\(text)" }
    }

    public struct Result: Sendable, Equatable {
        public var title: String
        public var containerId: UUID?
        public var categoryId: UUID?
        public var priority: Int?
        public var dueDate: LocalDate?
        public var dueTime: LocalTime?
        public var tokens: [Token]
    }

    public var containers: [ContainerOption]
    public var categories: [CategoryOption]
    public var today: LocalDate

    public init(containers: [ContainerOption], categories: [CategoryOption], today: LocalDate) {
        self.containers = containers
        self.categories = categories
        self.today = today
    }

    static let categoryAliases: [String: String] = [
        "hw": "homework", "pset": "homework", "q": "quiz", "midterm": "exam", "final": "exam",
        "read": "reading", "proj": "project", "ms": "milestone",
    ]
    static let weekdays: [String: Int] = [  // Calendar weekday: 1 = Sunday
        "sun": 1, "sunday": 1, "mon": 2, "monday": 2, "tue": 3, "tues": 3, "tuesday": 3,
        "wed": 4, "weds": 4, "wednesday": 4, "thu": 5, "thur": 5, "thurs": 5, "thursday": 5,
        "fri": 6, "friday": 6, "sat": 7, "saturday": 7,
    ]
    static let months: [String: Int] = [
        "jan": 1, "january": 1, "feb": 2, "february": 2, "mar": 3, "march": 3, "apr": 4, "april": 4,
        "may": 5, "jun": 6, "june": 6, "jul": 7, "july": 7, "aug": 8, "august": 8,
        "sep": 9, "sept": 9, "september": 9, "oct": 10, "october": 10, "nov": 11, "november": 11,
        "dec": 12, "december": 12,
    ]

    public func parse(_ input: String) -> Result {
        let words = input.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        var keep = Array(repeating: true, count: words.count)
        var result = Result(title: "", tokens: [])

        var i = 0
        while i < words.count {
            let word = words[i]
            let lower = word.lowercased()
            let next = i + 1 < words.count ? words[i + 1].lowercased() : nil

            // #category
            if lower.hasPrefix("#"), lower.count > 1, result.categoryId == nil,
               let cat = matchCategory(String(lower.dropFirst())) {
                result.categoryId = cat.id
                result.tokens.append(Token(kind: .category, text: word, label: cat.name))
                keep[i] = false; i += 1; continue
            }
            // !priority
            if lower.count == 2, lower.hasPrefix("!"), let p = Int(lower.dropFirst()), (0...3).contains(p) {
                result.priority = p
                result.tokens.append(Token(kind: .priority, text: word, label: "P\(p)"))
                keep[i] = false; i += 1; continue
            }
            // @container
            if lower.hasPrefix("@"), lower.count > 1, result.containerId == nil,
               let c = matchContainer(String(lower.dropFirst()), prefix: true) {
                result.containerId = c.id
                result.tokens.append(Token(kind: .container, text: word, label: c.name))
                keep[i] = false; i += 1; continue
            }
            // Dates (some take two or three words)
            if result.dueDate == nil, let (date, used) = parseDate(at: i, words.map { $0.lowercased() }) {
                result.dueDate = date
                let text = words[i..<(i + used)].joined(separator: " ")
                result.tokens.append(Token(kind: .date, text: text, label: label(for: date)))
                for k in i..<(i + used) { keep[k] = false }
                i += used; continue
            }
            // Times
            if result.dueTime == nil, let time = parseTime(lower) {
                result.dueTime = time
                result.tokens.append(Token(kind: .time, text: word, label: label(for: time)))
                keep[i] = false; i += 1; continue
            }
            // "at 5pm"
            if lower == "at", result.dueTime == nil, let n = next, let time = parseTime(n) {
                result.dueTime = time
                result.tokens.append(Token(kind: .time, text: "\(word) \(words[i + 1])", label: label(for: time)))
                keep[i] = false; keep[i + 1] = false; i += 2; continue
            }
            // Bare container code: "cs61b", "ee66"
            // Only code-like words (letters + digits) so ordinary words like "general" stay in the title.
            if result.containerId == nil, lower.count >= 3, lower.contains(where: \.isNumber),
               lower.contains(where: \.isLetter), let c = matchContainer(lower, prefix: false) {
                result.containerId = c.id
                result.tokens.append(Token(kind: .container, text: word, label: c.name))
                keep[i] = false; i += 1; continue
            }
            i += 1
        }

        // A time with no date means today.
        if result.dueTime != nil, result.dueDate == nil {
            result.dueDate = today
        }
        result.title = zip(words, keep).filter(\.1).map(\.0).joined(separator: " ")
        return result
    }

    // MARK: Matching

    private func matchCategory(_ query: String) -> CategoryOption? {
        let q = Self.categoryAliases[query] ?? query
        return categories.first { $0.name.lowercased() == q }
            ?? categories.first { $0.name.lowercased().hasPrefix(q) }
    }

    private func matchContainer(_ query: String, prefix: Bool) -> ContainerOption? {
        func squash(_ s: String) -> String { s.lowercased().filter { !$0.isWhitespace } }
        let holders = containers.filter(\.holdsTasks)
        if let exact = holders.first(where: { squash($0.name) == query }) { return exact }
        guard prefix else { return nil }
        return holders.first { squash($0.name).hasPrefix(query) }
    }

    // MARK: Dates

    private func parseDate(at i: Int, _ w: [String]) -> (LocalDate, Int)? {
        let word = w[i]
        let next = i + 1 < w.count ? w[i + 1] : nil
        let third = i + 2 < w.count ? w[i + 2] : nil

        switch word {
        case "today", "tod": return (today, 1)
        case "tomorrow", "tmr", "tmrw": return (today.adding(days: 1), 1)
        default: break
        }
        if word == "next", let n = next, let wd = Self.weekdays[n] {
            return (nextWeekday(wd, includingToday: false).adding(days: 7 * (isThisWeek(wd) ? 1 : 0)), 2)
        }
        if let wd = Self.weekdays[word] {
            return (nextWeekday(wd, includingToday: true), 1)
        }
        if word == "in", let n = next, let count = Int(n), let unit = third,
           ["day", "days", "week", "weeks"].contains(unit) {
            return (today.adding(days: unit.hasPrefix("week") ? count * 7 : count), 3)
        }
        // 11/13 or 11/13/2026
        let slash = word.split(separator: "/")
        if slash.count >= 2, let m = Int(slash[0]), let d = Int(slash[1]), (1...12).contains(m), (1...31).contains(d) {
            var year = slash.count > 2 ? Int(slash[2]) ?? today.year : today.year
            if year < 100 { year += 2000 }
            var date = LocalDate(year: year, month: m, day: d)
            if slash.count == 2, date < today { date.year += 1 }  // "1/5" in November means next January
            return (date, 1)
        }
        // nov 13
        if let m = Self.months[word], let n = next, let d = Int(n.trimmingCharacters(in: .punctuationCharacters)), (1...31).contains(d) {
            var date = LocalDate(year: today.year, month: m, day: d)
            if date < today { date.year += 1 }
            return (date, 2)
        }
        return nil
    }

    private func weekday(of date: LocalDate) -> Int {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c.component(.weekday, from: date.startOfDay(in: c.timeZone))
    }

    private func nextWeekday(_ target: Int, includingToday: Bool) -> LocalDate {
        var delta = (target - weekday(of: today) + 7) % 7
        if delta == 0, !includingToday { delta = 7 }
        return today.adding(days: delta)
    }

    /// Whether `target` weekday is still ahead in the current (Sunday-start) week.
    private func isThisWeek(_ target: Int) -> Bool {
        target > weekday(of: today)
    }

    // MARK: Times

    func parseTime(_ s: String) -> LocalTime? {
        switch s {
        case "noon": return LocalTime(hour: 12, minute: 0)
        case "midnight": return LocalTime(hour: 23, minute: 59)
        default: break
        }
        var body = s
        var meridiem: String?
        for suffix in ["am", "pm", "a", "p"] where body.hasSuffix(suffix) {
            meridiem = suffix.hasPrefix("a") ? "am" : "pm"
            body = String(body.dropLast(suffix.count))
            break
        }
        let parts = body.split(separator: ":")
        guard (1...2).contains(parts.count), let h = Int(parts[0]) else { return nil }
        let m = parts.count == 2 ? Int(parts[1]) : 0
        guard let minute = m, (0...59).contains(minute) else { return nil }

        if let meridiem {
            guard (1...12).contains(h) else { return nil }
            let hour = meridiem == "am" ? (h == 12 ? 0 : h) : (h == 12 ? 12 : h + 12)
            return LocalTime(hour: hour, minute: minute)
        }
        // Without am/pm, only accept clear 24h times like 17:30 (bare "5" is just a number).
        guard parts.count == 2, (0...23).contains(h) else { return nil }
        return LocalTime(hour: h, minute: minute)
    }

    // MARK: Labels

    private func label(for date: LocalDate) -> String {
        if date == today { return "Today" }
        if date == today.adding(days: 1) { return "Tomorrow" }
        let utc = TimeZone(identifier: "UTC")!
        return date.startOfDay(in: utc).formatted(
            Date.FormatStyle(timeZone: utc).weekday(.abbreviated).month(.abbreviated).day()
        )
    }

    private func label(for time: LocalTime) -> String {
        let h12 = time.hour % 12 == 0 ? 12 : time.hour % 12
        let ampm = time.hour < 12 ? "AM" : "PM"
        return time.minute == 0 ? "\(h12) \(ampm)" : String(format: "%d:%02d %@", h12, time.minute, ampm)
    }
}
