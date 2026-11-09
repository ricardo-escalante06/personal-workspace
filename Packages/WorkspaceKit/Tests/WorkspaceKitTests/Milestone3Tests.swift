import Foundation
import GRDB
import Testing
@testable import WorkspaceKit

@Suite struct Milestone3Tests {
    let utc = TimeZone(identifier: "UTC")!

    private func seriesTasks(_ store: WorkspaceStore, _ ruleId: UUID) throws -> [TaskItem] {
        try store.db.read { db in
            try TaskItem.live().filter(Column("generated_by_rule_id") == ruleId)
                .order(Column("series_index")).fetchAll(db)
        }
    }

    @Test func seriesItemsSkipBreaksAndKeepNumbering() {
        var rule = AssignmentRule(containerId: UUID(), titlePattern: "HW {n}", count: 4,
                                  firstDueDate: LocalDate(year: 2026, month: 11, day: 13))
        rule.skippedDates = [LocalDate(year: 2026, month: 11, day: 27)]
        let items = rule.items()
        #expect(items.map(\.title) == ["HW 1", "HW 2", "HW 3", "HW 4"])
        #expect(items.map(\.dueDate.description) == ["2026-11-13", "2026-11-20", "2026-12-04", "2026-12-11"])
        rule.titlePattern = "Lab"
        rule.everyWeeks = 2
        rule.skippedDates = []
        #expect(rule.items().map(\.title).first == "Lab 1")
        #expect(rule.items()[1].dueDate == LocalDate(year: 2026, month: 11, day: 27))
    }

    @Test func editingASeriesRespectsHandEdits() throws {
        let store = try WorkspaceStore.inMemory()
        let cls = try store.createContainer(name: "CS61B", kind: .class)
        var rule = try store.saveAssignmentSeries(AssignmentRule(
            containerId: cls.id, titlePattern: "HW {n}", count: 3,
            firstDueDate: LocalDate(year: 2026, month: 11, day: 13), dueTime: LocalTime(hour: 23, minute: 59)
        ), timeZone: utc)
        var tasks = try seriesTasks(store, rule.id)
        #expect(tasks.map(\.title) == ["HW 1", "HW 2", "HW 3"])

        // Rename HW 2 by hand, delete HW 3.
        try store.editTask(tasks[1].id, timeZone: utc) { $0.title = "HW 2 (with partner)" }
        try store.deleteTask(tasks[2].id)

        // Series moves to Thursdays and grows to 4.
        rule.firstDueDate = LocalDate(year: 2026, month: 11, day: 12)
        rule.count = 4
        rule = try store.saveAssignmentSeries(rule, timeZone: utc)
        tasks = try seriesTasks(store, rule.id)
        #expect(tasks.map(\.title) == ["HW 1", "HW 2 (with partner)", "HW 4"])
        #expect(tasks[1].dueDate == LocalDate(year: 2026, month: 11, day: 19))  // date still follows
        #expect(tasks[2].dueDate == LocalDate(year: 2026, month: 12, day: 3))

        // Shrinking removes open tasks past the end but keeps finished ones.
        try store.setStatus(tasks[0].id, .done)
        rule.count = 0
        _ = try store.saveAssignmentSeries(rule, timeZone: utc)
        #expect(try seriesTasks(store, rule.id).map(\.title) == ["HW 1"])
    }

    @Test func starredShowsOnlyTheNextTwoWeeks() throws {
        let exam = UUID()
        let now = LocalDate(year: 2026, month: 11, day: 9).startOfDay(in: utc).addingTimeInterval(3600 * 12)
        let tasks = [
            TaskItem(containerId: nil, title: "Midterm 2", categoryId: exam, dueDate: LocalDate(year: 2026, month: 11, day: 19)),
            TaskItem(containerId: nil, title: "Old quiz", categoryId: exam, dueDate: LocalDate(year: 2026, month: 11, day: 1)),
            TaskItem(containerId: nil, title: "Visa form", isStarred: true),  // no date: not shown
            TaskItem(containerId: nil, title: "Final", categoryId: exam, dueDate: LocalDate(year: 2026, month: 12, day: 15)),  // > 2 weeks
            TaskItem(containerId: nil, title: "Essay", dueDate: LocalDate(year: 2026, month: 11, day: 9), isStarred: true),
            TaskItem(containerId: nil, title: "HW 4", dueDate: LocalDate(year: 2026, month: 11, day: 10)),
        ]
        let data = Dashboard.build(tasks: tasks, blocks: [], weekStart: LocalDate(year: 2026, month: 11, day: 8),
                                   now: now, timeZone: utc, autoStarCategories: [exam])
        #expect(data.starred.map(\.title) == ["Essay", "Midterm 2"])
    }

    @Test func unknownHashtagBecomesANewTag() throws {
        let hw = UUID()
        let parser = QuickAddParser(containers: [], categories: [.init(id: hw, name: "Homework")],
                                    today: LocalDate(year: 2026, month: 11, day: 9))
        let known = parser.parse("Read ch 4 #hw")
        #expect(known.categoryId == hw && known.newTagName == nil && known.title == "Read ch 4")
        let new = parser.parse("Buy tape #errands")
        #expect(new.categoryId == nil && new.newTagName == "errands" && new.title == "Buy tape")

        let store = try WorkspaceStore.inMemory()
        let a = try store.tag(named: "errands")
        let b = try store.tag(named: "Errands")
        #expect(a.id == b.id && a.name == "Errands" && a.color != nil)
    }

    @Test func startDateNeverPassesDueDate() throws {
        let store = try WorkspaceStore.inMemory()
        let t = try store.addTask(title: "Edit video", containerId: nil, dueDate: LocalDate(year: 2026, month: 11, day: 20))
        try store.editTask(t.id) { $0.startDate = LocalDate(year: 2026, month: 11, day: 25) }
        let saved = try #require(try store.db.read { try TaskItem.fetchOne($0, id: t.id) })
        #expect(saved.startDate == saved.dueDate)
    }
}
