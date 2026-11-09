import Foundation
import GRDB
import Testing
@testable import WorkspaceKit

@Suite struct RecurrenceTests {
    let utc = TimeZone(identifier: "UTC")!
    func d(_ s: String) -> LocalDate { LocalDate(string: s)! }
    func strings(_ ds: [LocalDate]) -> [String] { ds.map(\.description) }

    @Test func weeklyOnChosenDaysAndEveryOtherWeek() {
        let r = RepeatRule(.weekly, weekdays: [2, 4])   // Mon, Wed
        #expect(strings(r.dates(anchor: d("2026-11-09"), from: d("2026-11-01"), through: d("2026-11-19")))
                == ["2026-11-09", "2026-11-11", "2026-11-16", "2026-11-18"])
        let biweekly = RepeatRule(.weekly, interval: 2)
        #expect(strings(biweekly.dates(anchor: d("2026-11-15"), from: d("2026-11-15"), through: d("2026-12-20")))
                == ["2026-11-15", "2026-11-29", "2026-12-13"])
    }

    @Test func monthEndsAndNthWeekdays() {
        let r31 = RepeatRule(.monthly)
        #expect(strings(r31.dates(anchor: d("2027-01-31"), from: d("2027-01-01"), through: d("2027-04-30")))
                == ["2027-01-31", "2027-02-28", "2027-03-31", "2027-04-30"])
        let leap = RepeatRule(.monthly, monthly: .day(-1))
        #expect(strings(leap.dates(anchor: d("2028-01-31"), from: d("2028-02-01"), through: d("2028-02-29"))) == ["2028-02-29"])
        let lastFri = RepeatRule(.monthly, monthly: .weekday(ordinal: -1, weekday: 6))
        #expect(strings(lastFri.dates(anchor: d("2026-11-01"), from: d("2026-11-01"), through: d("2027-01-31")))
                == ["2026-11-27", "2026-12-25", "2027-01-29"])
        // A 5th Monday only exists in some months; the others are skipped.
        let fifthMon = RepeatRule(.monthly, monthly: .weekday(ordinal: 5, weekday: 2))
        #expect(strings(fifthMon.dates(anchor: d("2026-11-01"), from: d("2026-11-01"), through: d("2027-03-31")))
                == ["2026-11-30", "2027-03-29"])
        let yearly = RepeatRule(.yearly)
        #expect(strings(yearly.dates(anchor: d("2028-02-29"), from: d("2029-01-01"), through: d("2029-12-31"))) == ["2029-02-28"])
    }

    @Test func countUntilAndRoundTrip() {
        let r = RepeatRule(.daily, interval: 3, end: .count(3))
        #expect(strings(r.dates(anchor: d("2026-11-01"), from: d("2026-11-05"), through: d("2026-12-01"))) == ["2026-11-07"])
        let u = RepeatRule(.weekly, weekdays: [1], end: .until(d("2026-11-22")))
        #expect(u.dates(anchor: d("2026-11-01"), from: d("2026-11-01"), through: d("2026-12-31")).count == 4)
        for rule in [r, u, RepeatRule(.monthly, monthly: .weekday(ordinal: 2, weekday: 3)), RepeatRule(.yearly, interval: 2)] {
            #expect(RepeatRule(rrule: rule.rrule) == rule)
        }
        #expect(RepeatRule(.weekly, weekdays: [2, 3, 4, 5, 6]).summary(anchor: nil) == "Every weekday")
        #expect(RepeatRule(.monthly, monthly: .weekday(ordinal: -1, weekday: 6)).summary(anchor: nil) == "Monthly on the last Friday")
    }

    @Test func dueTimeHoldsAcrossDaylightSaving() throws {
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let series = TaskItem(containerId: nil, title: "Standup", dueDate: d("2026-10-30"), dueTime: LocalTime(hour: 9, minute: 0),
                              dueTz: la.identifier, rrule: RepeatRule(.daily).rrule, rruleTz: la.identifier, rruleAnchor: d("2026-10-30"))
        let occ = Occurrences.expand(series, overrides: [], from: d("2026-10-31"), through: d("2026-11-02"))
        var cal = Calendar(identifier: .gregorian); cal.timeZone = la
        for o in occ {
            #expect(cal.component(.hour, from: try #require(o.dueInstant(in: la))) == 9)  // DST ends Nov 1
        }
    }

    @Test func completingOneOccurrenceLeavesTheNextOpen() throws {
        let store = try WorkspaceStore.inMemory()
        let t = try store.addTask(title: "Reading", containerId: nil, dueDate: d("2026-11-09"))
        try store.setRepeat(t.id, RepeatRule(.weekly), timeZone: utc)
        let monday = OccurrenceRegistry.id(series: t.id, key: "2026-11-09")
        try store.setStatus(monday, .done)
        let now = d("2026-11-10").startOfDay(in: utc)
        let data = try store.db.read { try Dashboard.fetch($0, scope: nil, weekStart: d("2026-11-08"), now: now, timeZone: utc) }
        #expect(data.week[1].chips.first?.task.status == .done)       // Mon Nov 9 done
        #expect(data.dueSoon.map(\.dueDate) == [d("2026-11-16")])    // next Monday, once
        #expect(data.overdue.isEmpty)
        #expect(data.tasks.count == 1 && data.tasks[0].dueDate == d("2026-11-16"))
    }

    @Test func missedOccurrencesStayOverdueUntilSkipped() throws {
        let store = try WorkspaceStore.inMemory()
        let t = try store.addTask(title: "Laundry", containerId: nil, dueDate: d("2026-11-01"))
        try store.setRepeat(t.id, RepeatRule(.weekly), timeZone: utc)
        let now = d("2026-11-10").startOfDay(in: utc)
        func overdue() throws -> [String] {
            try store.db.read { try Dashboard.fetch($0, scope: nil, weekStart: d("2026-11-08"), now: now, timeZone: utc) }
                .overdue.compactMap(\.occurrenceKey)
        }
        #expect(try overdue() == ["2026-11-01", "2026-11-08"])
        try store.deleteTask(OccurrenceRegistry.id(series: t.id, key: "2026-11-01"))   // = skip
        #expect(try overdue() == ["2026-11-08"])
    }

    @Test func thisAndFutureSplitsTheSeries() throws {
        let store = try WorkspaceStore.inMemory()
        let t = try store.addTask(title: "Gym", containerId: nil, dueDate: d("2026-11-02"), dueTime: LocalTime(hour: 7, minute: 0))
        try store.setRepeat(t.id, RepeatRule(.weekly, end: .count(6)), timeZone: utc)
        let newId = try store.editFuture(t.id, from: "2026-11-16", timeZone: utc) { $0.dueTime = LocalTime(hour: 18, minute: 0) }
        let (old, new) = try store.db.read { db in
            (try TaskItem.fetchOne(db, id: t.id)!, try TaskItem.fetchOne(db, id: newId)!)
        }
        let oldDates = Occurrences.expand(old, overrides: [], from: d("2026-11-01"), through: d("2027-01-31"))
        let newDates = Occurrences.expand(new, overrides: [], from: d("2026-11-01"), through: d("2027-01-31"))
        #expect(oldDates.map(\.dueDate!.description) == ["2026-11-02", "2026-11-09"])
        #expect(oldDates.allSatisfy { $0.dueTime == LocalTime(hour: 7, minute: 0) })
        #expect(newDates.map(\.dueDate!.description) == ["2026-11-16", "2026-11-23", "2026-11-30", "2026-12-07"])  // 6 total
        #expect(newDates.allSatisfy { $0.dueTime == LocalTime(hour: 18, minute: 0) })
    }

    @Test func editingAnOccurrenceKeepsDateLocalAndTagGlobal() throws {
        let store = try WorkspaceStore.inMemory()
        let tag = try store.tag(named: "chores")
        let t = try store.addTask(title: "Laundry", containerId: nil, dueDate: d("2026-11-08"))
        try store.setRepeat(t.id, RepeatRule(.weekly), timeZone: utc)
        let occ = OccurrenceRegistry.id(series: t.id, key: "2026-11-15")
        try store.editTask(occ, timeZone: utc) { $0.dueDate = d("2026-11-16"); $0.categoryId = tag.id }
        let series = try store.db.read { try TaskItem.fetchOne($0, id: t.id)! }
        #expect(series.categoryId == tag.id && series.dueDate == d("2026-11-08"))
        let moved = try #require(try store.occurrence(t.id, key: "2026-11-15"))
        #expect(moved.dueDate == d("2026-11-16"))

        // Undo restores overrides too.
        let snap = try store.snapshot([occ])
        try store.setStatus(occ, .done)
        try store.restore(snap)
        #expect(try store.occurrence(t.id, key: "2026-11-15")?.status == .notStarted)
    }

    @Test func quickAddRepeats() {
        let p = QuickAddParser(containers: [], categories: [], today: d("2026-11-09"))   // Monday
        let laundry = p.parse("Laundry every sunday")
        #expect(laundry.title == "Laundry" && laundry.repeatRule == RepeatRule(.weekly, weekdays: [1]))
        #expect(laundry.dueDate == d("2026-11-15"))
        let gym = p.parse("Gym every mon and wed 7am")
        #expect(gym.title == "Gym" && gym.repeatRule?.weekdays == [2, 4] && gym.dueDate == d("2026-11-09"))
        #expect(p.parse("Rent every month 1st").repeatRule?.frequency == .monthly)
        #expect(p.parse("Review every other week").repeatRule == RepeatRule(.weekly, interval: 2))
        #expect(p.parse("Every one counts").repeatRule == nil)
    }

    @Test func dueFillerWordIsDropped() {
        let p = QuickAddParser(containers: [], categories: [], today: d("2026-11-09"))
        let r = p.parse("hw18 due 8pm")
        #expect(r.title == "hw18" && r.dueTime == LocalTime(hour: 20, minute: 0) && r.dueDate == d("2026-11-09"))
        #expect(p.parse("Essay due fri").title == "Essay")
        #expect(p.parse("Pay what is due").title == "Pay what is due")
    }
}
