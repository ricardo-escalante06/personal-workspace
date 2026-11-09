import Foundation
import Testing
@testable import WorkspaceKit

@Suite struct ReminderPlannerTests {
    let tz = TimeZone(identifier: "America/Los_Angeles")!
    func d(_ s: String) -> LocalDate { LocalDate(string: s)! }

    @Test func plansDeadlinesStarredAndRepeats() {
        let exam = UUID()
        let now = d("2026-11-09").at(LocalTime(hour: 8, minute: 0), in: tz)
        let tasks = [
            TaskItem(containerId: nil, title: "Quiz 6", dueDate: d("2026-11-10"), dueTime: LocalTime(hour: 12, minute: 0), dueTz: tz.identifier),
            TaskItem(containerId: nil, title: "Midterm", categoryId: exam, dueDate: d("2026-11-12")),
            TaskItem(containerId: nil, title: "Done thing", status: .done, dueDate: d("2026-11-10")),
            TaskItem(containerId: nil, title: "Laundry", dueDate: d("2026-11-08"),
                     rrule: RepeatRule(.weekly).rrule, rruleTz: tz.identifier, rruleAnchor: d("2026-11-08")),
        ]
        let r = ReminderPlanner.plan(tasks: tasks, overrides: [], blocks: [], autoStarCategories: [exam],
                                     containerNames: [:], now: now, timeZone: tz)
        let summary = r.map { "\($0.title)|\($0.body.components(separatedBy: " ·").first!)|\(LocalDate($0.date, in: tz))" }
        #expect(summary == [
            "Quiz 6|Due at 12 PM|2026-11-10",
            "Midterm|Tomorrow|2026-11-11",
            "Midterm|Due today|2026-11-12",
            "Laundry|Due today|2026-11-15",
        ])
        #expect(r.first?.date == d("2026-11-10").at(LocalTime(hour: 11, minute: 0), in: tz))
        #expect(r.last?.seriesId != nil && r.last?.occurrenceKey == "2026-11-15")
    }
}
