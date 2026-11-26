import Foundation
import GRDB
import Testing
@testable import WorkspaceKit

private let la = TimeZone(identifier: "America/Los_Angeles")!

private var laCalendar: Calendar {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = la
    c.firstWeekday = 1
    return c
}

/// Tuesday 2026-11-10, 12:00 in Los Angeles. Sample week: Sun 11/8 … Sat 11/14.
private let tuesdayNoon = LocalDate(year: 2026, month: 11, day: 10).startOfDay(in: la).addingTimeInterval(12 * 3600)
private let weekStart = LocalDate(year: 2026, month: 11, day: 8)

private func seeded() throws -> (WorkspaceStore, SampleData.Handles) {
    let store = try WorkspaceStore.inMemory()
    let h = try SampleData.install(into: store, referenceDate: tuesdayNoon, calendar: laCalendar)
    return (store, h)
}

private func dashboard(_ store: WorkspaceStore, _ scope: UUID?, now: Date = tuesdayNoon) throws -> DashboardData {
    try store.db.read { try Dashboard.fetch($0, scope: scope, weekStart: weekStart, now: now, timeZone: la) }
}

@Suite struct DashboardTests {
    @Test func weekStartIsSunday() {
        #expect(Dashboard.weekStart(containing: LocalDate(year: 2026, month: 11, day: 10)) == weekStart)
        #expect(Dashboard.weekStart(containing: weekStart) == weekStart)
        #expect(Dashboard.weekStart(containing: LocalDate(year: 2026, month: 11, day: 14)) == weekStart)
        // Monday-start option.
        #expect(Dashboard.weekStart(containing: LocalDate(year: 2026, month: 11, day: 8), firstWeekday: 2)
                == LocalDate(year: 2026, month: 11, day: 2))
    }

    @Test func todayListsTheStudyBlockOnce() throws {
        let (store, h) = try seeded()
        let d = try dashboard(store, h.cs61b)
        // Tuesday: "Study for Quiz 4" has its 7–8 PM block today. HW 9 (Fri) and Quiz 4 (Thu) are not today.
        #expect(d.today.map(\.task.title) == ["Study for Quiz 4"])
        #expect(d.today.first?.blocks.count == 1)
        #expect(d.metrics.scheduledToday == 1)
        #expect(d.metrics.dueToday == 0)
    }

    @Test func weekStripSeparatesDeadlinesFromWorkBlocks() throws {
        let (store, h) = try seeded()
        let d = try dashboard(store, h.school)
        #expect(d.week.count == 7)
        #expect(d.week.first?.date == weekStart)

        func titles(_ offset: Int) -> [String] { d.week[offset].chips.map(\.task.title) }
        // Tue: study block. Thu: Quiz 4 (timed deadline). Fri: HW 9 + Lab 5 deadlines.
        #expect(titles(2).contains("Study for Quiz 4"))
        #expect(titles(4).contains("Quiz 4"))
        #expect(Set(titles(5)).isSuperset(of: ["HW 9", "Lab 5"]))

        // Lab 5: two work blocks (Mon, Wed) and one deadline (Fri), yet one task.
        let lab5Chips = d.week.flatMap(\.chips).filter { $0.task.id == h.lab5 }
        #expect(lab5Chips.count == 3)
        #expect(lab5Chips.filter { if case .scheduled = $0.kind { true } else { false } }.count == 2)
        #expect(d.tasks.filter { $0.id == h.lab5 }.count == 1)

        // All-day deadlines sort above timed items within a day.
        if case .due(nil) = d.week[5].chips.first?.kind {} else { Issue.record("Friday should start with all-day deadlines") }
    }

    @Test func overdueAndUpcoming() throws {
        let (store, h) = try seeded()
        let d = try dashboard(store, h.school)
        // Monday's "Lecture 10 reading" (CS61A) is overdue on Tuesday.
        #expect(d.overdue.map(\.title) == ["Lecture 10 reading"])
        #expect(d.metrics.overdue == 1)
        // Upcoming is chronological and starts tomorrow.
        let dates = d.upcoming.map(\.date)
        #expect(dates == dates.sorted())
        #expect(dates.allSatisfy { $0 > LocalDate(year: 2026, month: 11, day: 10) })
        #expect(d.upcoming.contains { $0.task.id == h.hw9 })
        #expect(!d.upcoming.contains { $0.task.status == .done })
        // Due soon: deadlines only (no work blocks), soonest first, reaching past this week.
        #expect(!d.dueSoon.contains { $0.id == h.studyQuiz4 })
        #expect(d.dueSoon.map(\.title).prefix(3) == ["HW 7", "Quiz 4", "HW 9"])
        let all = try dashboard(store, nil)
        #expect(all.dueSoon.contains { $0.title == "Book movers" })   // next week's Friday
    }

    @Test func completingUpdatesMetricsEverywhere() throws {
        let (store, h) = try seeded()
        let before = try dashboard(store, nil)
        try store.setStatus(h.studyQuiz4, .done)
        let cs61b = try dashboard(store, h.cs61b, now: Date())
        let root = try dashboard(store, nil)
        #expect(cs61b.metrics.completedToday >= 1)
        #expect(root.metrics.progress > before.metrics.progress)
        // Done items stay in Today but sort last.
        #expect(root.today.last?.task.id == h.studyQuiz4 || root.today.allSatisfy { $0.task.status == .done })
    }

    @Test func subtasksRollUpIntoParents() throws {
        let (store, h) = try seeded()
        let d = try dashboard(store, h.project3)
        let checkpoint = try #require(d.tasks.first { $0.title == "Checkpoint" })
        #expect(d.subtaskProgress[checkpoint.id] == SubtaskProgress(done: 0, total: 1))
        #expect(!d.tasks.contains { $0.title == "Draft design doc" })   // shown under its parent, not top-level
    }

    @Test func rootIncludesInboxAndEverything() throws {
        let (store, h) = try seeded()
        let root = try dashboard(store, nil)
        let personal = try dashboard(store, h.personal)
        #expect(root.tasks.contains { $0.containerId == nil })
        #expect(root.tasks.count > personal.tasks.count)
        #expect(personal.today.contains { $0.task.id == h.groceries })   // due "today" (Tuesday)
    }
}

@Suite struct WorkSessionTests {
    @Test func checkingOffASessionLeavesTheTaskOpen() throws {
        let store = try WorkspaceStore.inMemory()
        let tuesday = LocalDate(year: 2026, month: 11, day: 10)
        let lab = try store.addTask(title: "Lab 4", containerId: nil, dueDate: tuesday.adding(days: 1))
        let start = tuesday.startOfDay(in: la).addingTimeInterval(14 * 3600)
        let block = try store.addScheduleBlock(taskId: lab.id, start: start, end: start.addingTimeInterval(9000))
        func today() throws -> TodayItem {
            let data = try store.db.read { try Dashboard.fetch($0, scope: nil, weekStart: weekStart, now: tuesdayNoon, timeZone: la) }
            return try #require(data.today.first { $0.task.id == lab.id })
        }

        var item = try today()
        #expect(item.isSessionOnly && !item.isChecked)

        try store.setScheduleBlocksDone([block.id], true)
        item = try today()
        #expect(item.isChecked)
        #expect(item.task.status != .done)   // still due tomorrow

        // On its due day the same task's checkbox is the task's again.
        try store.editTask(lab.id) { $0.dueDate = tuesday }
        item = try today()
        #expect(!item.isSessionOnly && !item.isChecked)
    }
}
