import Foundation
import Testing
@testable import WorkspaceKit

private let cs61b = UUID(), cs61a = UUID(), general = UUID(), school = UUID(), apartment = UUID()
private let hw = UUID(), quiz = UUID(), exam = UUID(), lab = UUID()

/// Tuesday 2026-11-10.
private let parser = QuickAddParser(
    containers: [
        .init(id: school, name: "School", holdsTasks: false),
        .init(id: cs61a, name: "CS61A", holdsTasks: true),
        .init(id: cs61b, name: "CS61B", holdsTasks: true),
        .init(id: general, name: "General", holdsTasks: true),
        .init(id: apartment, name: "Apartment Move", holdsTasks: true),
    ],
    categories: [
        .init(id: hw, name: "Homework"), .init(id: quiz, name: "Quiz"),
        .init(id: exam, name: "Exam"), .init(id: lab, name: "Lab"),
    ],
    today: LocalDate(year: 2026, month: 11, day: 10)
)

private func d(_ m: Int, _ day: Int, _ y: Int = 2026) -> LocalDate { LocalDate(year: y, month: m, day: day) }

@Suite struct QuickAddParserTests {
    @Test func theDesignDocExample() {
        let r = parser.parse("HW 5 cs61b fri 11:59pm #hw !2")
        #expect(r.title == "HW 5")
        #expect(r.containerId == cs61b)
        #expect(r.dueDate == d(11, 13))
        #expect(r.dueTime == LocalTime(hour: 23, minute: 59))
        #expect(r.categoryId == hw)
        #expect(r.priority == 2)
        #expect(r.tokens.map(\.kind) == [.container, .date, .time, .category, .priority])
    }

    @Test func plainTitlesAreLeftAlone() {
        let r = parser.parse("Buy groceries")
        #expect(r.title == "Buy groceries")
        #expect(r.tokens.isEmpty)
        #expect(r.dueDate == nil)
        // A bare number is not a time.
        #expect(parser.parse("Lab 5").title == "Lab 5")
        #expect(parser.parse("Lab 5").dueTime == nil)
    }

    @Test func relativeDates() {
        #expect(parser.parse("x today").dueDate == d(11, 10))
        #expect(parser.parse("x tmr").dueDate == d(11, 11))
        #expect(parser.parse("x tue").dueDate == d(11, 10))       // today counts
        #expect(parser.parse("x mon").dueDate == d(11, 16))       // already passed → next week
        #expect(parser.parse("x next fri").dueDate == d(11, 20))
        #expect(parser.parse("x in 3 days").dueDate == d(11, 13))
        #expect(parser.parse("x in 2 weeks").dueDate == d(11, 24))
    }

    @Test func absoluteDates() {
        #expect(parser.parse("x 11/13").dueDate == d(11, 13))
        #expect(parser.parse("x 1/5").dueDate == d(1, 5, 2027))   // past this year → next year
        #expect(parser.parse("x nov 20").dueDate == d(11, 20))
        #expect(parser.parse("x 12/1/27").dueDate == d(12, 1, 2027))
    }

    @Test func times() {
        #expect(parser.parseTime("5pm") == LocalTime(hour: 17, minute: 0))
        #expect(parser.parseTime("5p") == LocalTime(hour: 17, minute: 0))
        #expect(parser.parseTime("12am") == LocalTime(hour: 0, minute: 0))
        #expect(parser.parseTime("12pm") == LocalTime(hour: 12, minute: 0))
        #expect(parser.parseTime("17:30") == LocalTime(hour: 17, minute: 30))
        #expect(parser.parseTime("noon") == LocalTime(hour: 12, minute: 0))
        #expect(parser.parseTime("13pm") == nil)
        // Time without a date means today.
        let r = parser.parse("Call mom at 6pm")
        #expect(r.title == "Call mom")
        #expect(r.dueDate == d(11, 10))
        #expect(r.dueTime == LocalTime(hour: 18, minute: 0))
    }

    @Test func containers() {
        #expect(parser.parse("Book movers @apart").containerId == apartment)
        #expect(parser.parse("Book movers @apart").title == "Book movers")
        // Folders never match: tasks can't live in them.
        #expect(parser.parse("x @school").containerId == nil)
        #expect(parser.parse("x school").containerId == nil)
        // Bare words only match exact course-code-style names; ordinary words stay in the title.
        #expect(parser.parse("General chemistry").containerId == nil)
        #expect(parser.parse("General chemistry").title == "General chemistry")
        #expect(parser.parse("x @general").containerId == general)
        #expect(parser.parse("review CS61A notes").containerId == cs61a)
    }

    @Test func categoriesByAliasAndPrefix() {
        #expect(parser.parse("x #midterm").categoryId == exam)
        #expect(parser.parse("x #qu").categoryId == quiz)
        #expect(parser.parse("x #nope").categoryId == nil)
        #expect(parser.parse("x #nope").title == "x #nope")   // unmatched tags stay in the title
    }
}
