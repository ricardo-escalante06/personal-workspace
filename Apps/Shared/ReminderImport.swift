import EventKit
import Foundation
import GRDB
import WorkspaceKit

/// One Apple Reminder, flattened to plain values.
struct ReminderRecord: Codable, Identifiable {
    var id: String
    var list: String
    var account: String
    var title: String
    var notes: String?
    var url: String?
    /// "2026-11-13"
    var dueDate: String?
    /// "23:59" when the reminder has a time.
    var dueTime: String?
    /// EventKit priority: 0 none, 1–4 high, 5 medium, 6–9 low.
    var priority: Int
    var isCompleted: Bool
    var completedAt: Date?
    var createdAt: Date?
    /// "FREQ=WEEKLY;INTERVAL=1" style, when it repeats.
    var recurrence: String?
}

/// Reads Apple Reminders (one-time import). The copy saved to the app's folder is
/// what a setup plan is written from.
enum ReminderReader {
    static var exportURL: URL {
        AppPaths.databaseURL.deletingLastPathComponent().appendingPathComponent("reminders-export.json")
    }

    static func readAll() async throws -> [ReminderRecord] {
        let store = EKEventStore()
        guard try await store.requestFullAccessToReminders() else {
            throw ImportError.noAccess
        }
        let predicate = store.predicateForReminders(in: nil)
        return await withCheckedContinuation { cont in
            store.fetchReminders(matching: predicate) { reminders in
                cont.resume(returning: (reminders ?? []).map(record))
            }
        }
    }

    /// Reads everything and saves it next to the database. Returns (reminders, lists).
    static func export() async throws -> (Int, Int) {
        let records = try await readAll()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try FileManager.default.createDirectory(at: exportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(records).write(to: exportURL)
        return (records.count, Set(records.map(\.list)).count)
    }

    private static func record(_ r: EKReminder) -> ReminderRecord {
        var dueDate: String?, dueTime: String?
        if let c = r.dueDateComponents, let y = c.year, let m = c.month, let d = c.day {
            dueDate = String(format: "%04d-%02d-%02d", y, m, d)
            if let h = c.hour { dueTime = String(format: "%02d:%02d", h, c.minute ?? 0) }
        }
        let rule = r.recurrenceRules?.first.map { rule -> String in
            let freq = switch rule.frequency {
            case .daily: "DAILY"
            case .weekly: "WEEKLY"
            case .monthly: "MONTHLY"
            case .yearly: "YEARLY"
            @unknown default: "UNKNOWN"
            }
            return "FREQ=\(freq);INTERVAL=\(rule.interval)"
        }
        return ReminderRecord(
            id: r.calendarItemIdentifier, list: r.calendar.title, account: r.calendar.source?.title ?? "",
            title: r.title ?? "", notes: r.notes, url: r.url?.absoluteString,
            dueDate: dueDate, dueTime: dueTime, priority: r.priority,
            isCompleted: r.isCompleted, completedAt: r.completionDate, createdAt: r.creationDate,
            recurrence: rule
        )
    }

    enum ImportError: LocalizedError {
        case noAccess
        var errorDescription: String? {
            "Workspace doesn't have access to Reminders. Turn it on in System Settings › Privacy & Security › Reminders."
        }
    }
}

/// A full workspace layout to apply in one go: optionally clear what's there, then
/// create folders/lists/classes/projects and their tasks. Written by hand (or by
/// Claude from the Reminders export) and applied from Debug › Apply Setup Plan.
struct SetupPlan: Codable {
    struct Box: Codable {
        /// Referenced by `parent` and by tasks.
        var key: String
        var name: String
        var kind: ContainerKind
        var parent: String?
        var color: String?
    }
    struct Item: Codable {
        var box: String?          // nil = Inbox
        var title: String
        var notes: String?
        var url: String?
        var due: String?          // "2026-11-13"
        var time: String?         // "23:59"
        var tag: String?          // tag name; created if new
        var priority: Int?        // 1 low, 2 medium, 3 high
        var starred: Bool?
        var done: Bool?
        var subtasks: [String]?
    }
    /// An assignment series ("HW {n}", numbers 11–14, due Sundays).
    struct Series: Codable {
        var box: String
        var pattern: String
        var tag: String?
        var startNumber: Int
        var count: Int
        var firstDue: String
        var time: String?
        var everyWeeks: Int?
    }
    /// Delete every existing container and task (and unused custom tags) first.
    var clearExisting: Bool
    /// Custom tags to remove (built-ins are kept).
    var deleteTags: [String]?
    var boxes: [Box]
    var items: [Item]
    var series: [Series]?

    static var url: URL {
        AppPaths.databaseURL.deletingLastPathComponent().appendingPathComponent("setup-plan.json")
    }
}

extension AppModel {
    func exportReminders() {
        Task {
            do {
                let (count, lists) = try await ReminderReader.export()
                notice = "Read \(count) reminders from \(lists) lists. Nothing was changed."
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Applies setup-plan.json as one undo step… except clearing, which can't be undone
    /// from here; the old rows stay as tombstones in the database until synced.
    func applySetupPlan() {
        do {
            let data = try Data(contentsOf: SetupPlan.url)
            let plan = try JSONDecoder().decode(SetupPlan.self, from: data)
            try apply(plan)
            try FileManager.default.moveItem(
                at: SetupPlan.url,
                to: SetupPlan.url.deletingPathExtension().appendingPathExtension("applied-\(Int(Date().timeIntervalSince1970)).json"))
            clearSelection()
            selection = .allWorkspace
            notice = "Set up \(plan.boxes.count) folders and lists, \(plan.items.count) tasks and \(plan.series?.count ?? 0) assignment series."
        } catch {
            errorMessage = "Setup plan: \(error.localizedDescription)"
        }
    }

    private func apply(_ plan: SetupPlan) throws {
        try store.ensureBuiltInCategories()
        if plan.clearExisting {
            let roots = try store.db.read { try Container.live().filter(Column("parent_id") == nil).fetchAll($0) }
            for r in roots { try store.deleteContainer(r.id) }
            let loose = try store.db.read { try TaskItem.live().filter(Column("container_id") == nil).fetchAll($0) }
            for t in loose { try store.deleteTask(t.id) }
            let rules = try store.db.read { try AssignmentRule.live().fetchAll($0) }
            for r in rules { try store.deleteAssignmentSeries(r.id, removeOpenTasks: true) }
        }
        let builtIn = Set(TaskCategory.builtIns.map { $0.0 })
        for name in plan.deleteTags ?? [] {
            if let c = try store.categories().first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }),
               !builtIn.contains(c.name) {
                try store.deleteTag(c.id)
            }
        }

        var ids: [String: UUID] = [:]
        for b in plan.boxes {
            let parent = try b.parent.map { key -> UUID in
                guard let id = ids[key] else { throw PlanError.unknownBox(key) }
                return id
            }
            let c = try store.createContainer(name: b.name, kind: b.kind, parentId: parent, color: b.color ?? "grey")
            if b.kind == .project { ensureBoard(c.id) }
            ids[b.key] = c.id
        }

        for item in plan.items {
            let box = try item.box.map { key -> UUID in
                guard let id = ids[key] else { throw PlanError.unknownBox(key) }
                return id
            }
            let tagId = try item.tag.map { try store.tag(named: $0).id }
            let task = try store.addTask(
                title: item.title, containerId: box, categoryId: tagId, priority: item.priority,
                dueDate: item.due.flatMap(LocalDate.init(string:)),
                dueTime: item.time.flatMap(LocalTime.init(string:))
            )
            try store.editTask(task.id) { t in
                if let notes = item.notes { t.notes = notes }
                t.sourceUrl = item.url
                t.isStarred = item.starred ?? false
                if item.done == true { t.status = .done }
            }
            for sub in item.subtasks ?? [] {
                try store.addTask(title: sub, containerId: box, parentTaskId: task.id)
            }
        }
        for sr in plan.series ?? [] {
            guard let box = ids[sr.box] else { throw PlanError.unknownBox(sr.box) }
            var rule = AssignmentRule(
                containerId: box, categoryId: try sr.tag.map { try store.tag(named: $0).id },
                titlePattern: sr.pattern, startNumber: sr.startNumber, count: sr.count,
                firstDueDate: LocalDate(string: sr.firstDue), dueTime: sr.time.flatMap(LocalTime.init(string:))
            )
            rule.everyWeeks = sr.everyWeeks ?? 1
            try store.saveAssignmentSeries(rule)
        }
    }

    enum PlanError: LocalizedError {
        case unknownBox(String)
        var errorDescription: String? {
            switch self { case .unknownBox(let k): "no list with key “\(k)”" }
        }
    }
}

extension AppModel {
    /// Reminders imported before repeating tasks existed carry a note saying they repeat
    /// weekly; turn those into real weekly tasks (once) and drop the note.
    func convertImportedRepeats() {
        let marker = "Repeats weekly (from Reminders) — will become a repeating task in Milestone 4."
        guard let tasks = try? store.db.read({ db in
            try TaskItem.live().filter(Column("notes").like("%will become a repeating task in Milestone 4%")).fetchAll(db)
        }), !tasks.isEmpty else { return }
        perform {
            for t in tasks where !t.isRecurring {
                let day = RepeatRule.weekday(t.dueDate ?? LocalDate(Date()))
                try store.setRepeat(t.id, RepeatRule(.weekly, weekdays: [day]))
                try store.editTask(t.id) { $0.notes = $0.notes.replacingOccurrences(of: marker, with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines) }
            }
        }
    }
}
