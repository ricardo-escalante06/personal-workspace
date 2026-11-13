import Foundation
import GRDB
import Testing
@testable import WorkspaceKit

private let base = Date(timeIntervalSince1970: 1_794_000_000)
private func at(_ hours: Double) -> Date { base.addingTimeInterval(hours * 3600) }

private func block(_ id: String, _ s: Double, _ e: Double) -> CalendarItem {
    CalendarItem(source: .event(ExternalEvent(key: id, localId: id, calendarId: "c", calendarTitle: "C",
                                              calendarColor: 0, title: id, start: at(s), end: at(e),
                                              isAllDay: false, isWritable: false)),
                 title: id, start: at(s), end: at(e), isAllDay: false, containerId: nil,
                 isDone: false, isTentative: false, isEditable: false, dueTime: nil)
}

private func event(_ title: String, calendar: String = "Google", start: Date = base) -> ExternalEvent {
    ExternalEvent(key: title, localId: title, calendarId: calendar, calendarTitle: calendar, calendarColor: 0,
                  title: title, start: start, end: start.addingTimeInterval(3600), isAllDay: false, isWritable: true)
}

@Suite struct TimeGridLayoutTests {
    @Test func separateItemsUseFullWidth() {
        let placed = TimeGridLayout.layout([block("a", 9, 10), block("b", 10, 11)], dayStart: at(0), dayEnd: at(24))
        #expect(placed.map(\.columnCount) == [1, 1])
        #expect(placed.map(\.column) == [0, 0])
    }

    @Test func overlapsShareWidthAndNeverHideEachOther() {
        // Like Mon 6:30 PM in the screenshot: three overlapping events.
        let placed = TimeGridLayout.layout(
            [block("a", 18.5, 20), block("b", 18.5, 20), block("c", 18.5, 19.5), block("d", 21, 22)],
            dayStart: at(0), dayEnd: at(24)
        )
        let cluster = placed.filter { ["a", "b", "c"].contains($0.item.title) }
        #expect(Set(cluster.map(\.column)) == [0, 1, 2])
        #expect(cluster.allSatisfy { $0.columnCount == 3 })
        #expect(placed.first { $0.item.title == "d" }?.columnCount == 1)
    }

    @Test func freedColumnsAreReused() {
        // a 9–12, b 9–10, c 10–11: c reuses b's column; cluster is 2 wide.
        let placed = TimeGridLayout.layout([block("a", 9, 12), block("b", 9, 10), block("c", 10, 11)],
                                           dayStart: at(0), dayEnd: at(24))
        #expect(placed.first { $0.item.title == "c" }?.column == 1)
        #expect(placed.allSatisfy { $0.columnCount == 2 })
    }

    @Test func clipsToTheDayAndEnforcesMinimumHeight() {
        let placed = TimeGridLayout.layout([block("overnight", 22, 26), block("blip", 5, 5.01)],
                                           dayStart: at(0), dayEnd: at(24))
        let overnight = placed.first { $0.item.title == "overnight" }!
        #expect(overnight.end == at(24))
        let blip = placed.first { $0.item.title == "blip" }!
        #expect(blip.end.timeIntervalSince(blip.start) == 15 * 60)
    }
}

@Suite struct EventMappingTests {
    @Test func classTitlePatternsMatchOnWordBoundaries() {
        let cs61a = UUID(), ee66 = UUID()
        let mapper = EventMapper(links: [], rules: [], classTerms: [
            ClassTerm(containerId: cs61a, eventTitlePattern: "COMPSCI 61A"),
            ClassTerm(containerId: ee66, eventTitlePattern: "ELENG 66"),
        ])
        #expect(mapper.containerId(for: event("COMPSCI 61A LEC")) == cs61a)
        #expect(mapper.containerId(for: event("compsci  61a dis")) == cs61a)
        #expect(mapper.containerId(for: event("ELENG 66 DIS")) == ee66)
        #expect(mapper.containerId(for: event("COMPSCI 61AB LEC")) == nil)
        #expect(mapper.containerId(for: event("ELENG 666 LEC")) == nil)
        #expect(mapper.containerId(for: event("Climbing")) == nil)
    }

    @Test func manualLinksBeatRulesBeatPatterns() {
        let a = UUID(), b = UUID(), c = UUID()
        let mapper = EventMapper(
            links: [EventLink(externalEventKey: "COMPSCI 61A LEC", containerId: c)],
            rules: [EventMappingRule(matchType: .calendar, matchValue: "Work", containerId: b)],
            classTerms: [ClassTerm(containerId: a, eventTitlePattern: "COMPSCI 61A")]
        )
        #expect(mapper.containerId(for: event("COMPSCI 61A LEC")) == c)
        #expect(mapper.containerId(for: event("COMPSCI 61A DIS", calendar: "Work")) == b)
        #expect(mapper.containerId(for: event("COMPSCI 61A DIS")) == a)
    }
}

@Suite struct CalendarQueryTests {
    @Test func scopedCalendarsOnlyShowMappedEvents() throws {
        let store = try WorkspaceStore.inMemory()
        let h = try SampleData.install(into: store)
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!
        let mid = week.start.addingTimeInterval(86_400 * 2 + 3600 * 10)
        let events = [event("COMPSCI 61B LEC", start: mid), event("Climbing", start: mid)]

        let all = try store.db.read { try CalendarQuery.items($0, scope: nil, from: week.start, to: week.end, events: events) }
        let cs61b = try store.db.read { try CalendarQuery.items($0, scope: h.cs61b, from: week.start, to: week.end, events: events) }
        let school = try store.db.read { try CalendarQuery.items($0, scope: h.school, from: week.start, to: week.end, events: events) }
        let cs61a = try store.db.read { try CalendarQuery.items($0, scope: h.cs61a, from: week.start, to: week.end, events: events) }

        #expect(all.compactMap(\.event).count == 2)
        #expect(cs61b.compactMap(\.event).map(\.title) == ["COMPSCI 61B LEC"])
        #expect(school.compactMap(\.event).map(\.title) == ["COMPSCI 61B LEC"])
        #expect(cs61a.compactMap(\.event).isEmpty)
        // Unmapped events never leak into a class.
        #expect(!cs61b.contains { $0.title == "Climbing" })
    }

    @Test func deadlinesAreAllDayAndBlocksAreTimed() throws {
        let store = try WorkspaceStore.inMemory()
        let h = try SampleData.install(into: store)
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!
        let items = try store.db.read { try CalendarQuery.items($0, scope: h.ee66, from: week.start, to: week.end, events: []) }
        let lab = items.filter { $0.taskId == h.lab5 }
        #expect(lab.filter(\.isAllDay).count == 1)      // the Friday deadline
        #expect(lab.filter { !$0.isAllDay }.count == 2)  // two work blocks
        let quiz = try store.db.read { try CalendarQuery.items($0, scope: h.cs61b, from: week.start, to: week.end, events: []) }
            .first { $0.taskId == h.quiz4 }
        // Timed deadline: on the grid at 2 PM, not in the all-day row.
        #expect(quiz?.isAllDay == false)
        #expect(quiz?.dueTime == LocalTime(hour: 14, minute: 0))
        #expect(quiz.map { Calendar.current.component(.hour, from: $0.start) } == 14)
    }
}

@Suite struct HiddenContainerTests {
    @Test func hidingRemovesTasksAndEventsEverywhereButTheContainerItself() throws {
        let store = try WorkspaceStore.inMemory()
        let h = try SampleData.install(into: store)
        let week = Calendar.current.dateInterval(of: .weekOfYear, for: Date())!
        let mid = week.start.addingTimeInterval(86_400 * 2 + 3600 * 10)
        let events = [event("COMPSCI 61B LEC", start: mid)]
        let before = try store.tasks(inScope: nil).count
        let cs61bCount = try store.tasks(inScope: h.cs61b).count

        try store.setHidden(h.cs61b, true)
        #expect(try store.tasks(inScope: nil).count == before - cs61bCount)
        #expect(try !store.tasks(inScope: h.school).contains { $0.id == h.hw9 })
        // Opening the hidden class itself still shows its tasks.
        #expect(try store.tasks(inScope: h.cs61b).count == cs61bCount)
        let all = try store.db.read { try CalendarQuery.items($0, scope: nil, from: week.start, to: week.end, events: events) }
        #expect(!all.contains { $0.title == "COMPSCI 61B LEC" })
        #expect(!all.contains { $0.taskId == h.studyQuiz4 })
        // It stays in the tree (shown dimmed).
        #expect(ContainerTree.build(try store.containers()).flatMap { [$0] + $0.children }.contains { $0.id == h.school })

        try store.setHidden(h.cs61b, false)
        #expect(try store.tasks(inScope: nil).count == before)
    }
}

@Suite struct TaskSpanTests {
    @Test func spansRunFromStartUpToTheDueDay() throws {
        let store = try WorkspaceStore.inMemory()
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let monday = LocalDate(year: 2026, month: 11, day: 9)
        let task = try store.addTask(title: "Write report", containerId: nil, dueDate: monday.adding(days: 4))
        try store.editTask(task.id) { $0.startDate = monday.adding(days: 1) }
        let from = monday.startOfDay(in: tz), to = monday.adding(days: 7).startOfDay(in: tz)

        var options = CalendarQuery.Options()
        let off = try store.db.read { try CalendarQuery.items($0, scope: nil, from: from, to: to, events: [], options: options, timeZone: tz) }
        #expect(!off.contains { $0.isSpan })

        options.showSpans = true
        let on = try store.db.read { try CalendarQuery.items($0, scope: nil, from: from, to: to, events: [], options: options, timeZone: tz) }
        let span = try #require(on.first { $0.isSpan })
        #expect(span.isAllDay)
        #expect(span.start == monday.adding(days: 1).startOfDay(in: tz))
        // Ends where the due day begins: the due day shows the deadline flag instead.
        #expect(span.end == monday.adding(days: 4).startOfDay(in: tz))
        #expect(on.contains { if case .deadline = $0.source { return true } else { return false } })

        // Done tasks don't keep a span.
        try store.setStatus(task.id, .done)
        let done = try store.db.read { try CalendarQuery.items($0, scope: nil, from: from, to: to, events: [], options: options, timeZone: tz) }
        #expect(!done.contains { $0.isSpan })
    }
}
