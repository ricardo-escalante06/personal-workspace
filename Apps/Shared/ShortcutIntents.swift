import AppIntents
import Foundation
import GRDB
import WorkspaceKit
import WorkspaceUI

/// A list, class or project, so Siri can hear "add a task to CS61A in Workspace".
struct ListEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "List"
    static let defaultQuery = ListQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ListQuery: EntityStringQuery {
    private func all() async throws -> [ListEntity] {
        let store = try SharedStore.open()
        return try await store.db.read { db in
            try Container.live().filter(Column("archived_at") == nil).fetchAll(db)
                .filter { $0.kind.holdsTasks }
                .map { ListEntity(id: $0.id, name: $0.name) }
        }
    }
    func entities(for identifiers: [UUID]) async throws -> [ListEntity] {
        try await all().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [ListEntity] { try await all() }
    /// "cs61a", "CS 61A", "cs sixty one a"… → CS 61A (spaces and case ignored).
    func entities(matching string: String) async throws -> [ListEntity] {
        func norm(_ s: String) -> String { s.lowercased().filter { $0.isLetter || $0.isNumber } }
        let q = norm(string)
        return try await all().filter { norm($0.name).hasPrefix(q) || q.hasPrefix(norm($0.name)) }
    }
}

/// "Add a task in Workspace": same parsing as quick add ("HW 5 cs61b fri 11:59pm #hw",
/// "Laundry every sunday").
struct AddTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Task"
    static let description = IntentDescription("Adds a task. Include a class or list, a date, a #tag or “every …” like you would in quick add.")

    @Parameter(title: "Task", requestValueDialog: "What's the task?")
    var text: String

    @Parameter(title: "List")
    var list: ListEntity?

    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) to \(\.$list)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try SharedStore.open()
        let (containers, categories) = try await store.db.read { db in
            (try Container.live().fetchAll(db), try TaskCategory.live().fetchAll(db))
        }
        let parser = QuickAddParser(
            containers: containers.map { .init(id: $0.id, name: $0.name, holdsTasks: $0.kind.holdsTasks) },
            categories: categories.map { .init(id: $0.id, name: $0.name) },
            today: LocalDate(Date())
        )
        let parsed = parser.parse(text)
        guard !parsed.title.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .result(dialog: "I didn't catch a task name.")
        }
        var categoryId = parsed.categoryId
        if categoryId == nil, let name = parsed.newTagName { categoryId = try store.tag(named: name).id }
        let containerId = parsed.containerId ?? list?.id
        let task = try store.addTask(title: parsed.title, containerId: containerId, categoryId: categoryId,
                                     priority: parsed.priority, dueDate: parsed.dueDate, dueTime: parsed.dueTime)
        if let rule = parsed.repeatRule { try store.setRepeat(task.id, rule) }
        let place = containers.first { $0.id == containerId }?.name ?? "Inbox"
        let when = parsed.dueDate.map { " · due " + WSFormat.relativeDay($0, today: LocalDate(Date())) } ?? ""
        return .result(dialog: "Added “\(parsed.title)” to \(place)\(when).")
    }
}

/// "What's due today in Workspace"
struct DueTodayIntent: AppIntent {
    static let title: LocalizedStringResource = "What's Due Today"
    static let description = IntentDescription("Reads out what's due or planned today, plus anything overdue.")

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let store = try SharedStore.open()
        let today = LocalDate(Date())
        let data = try await store.db.read { try Dashboard.fetch($0, scope: nil, weekStart: Dashboard.weekStart(containing: today)) }
        let open = data.today.filter { $0.task.status != .done }.map(\.task.title)
        var lines: [String] = []
        lines.append(open.isEmpty ? "Nothing left today." : "Today: " + open.joined(separator: ", ") + ".")
        if !data.overdue.isEmpty { lines.append("Overdue: " + data.overdue.prefix(5).map(\.title).joined(separator: ", ") + ".") }
        if let star = data.starred.first, let due = star.dueDate {
            let days = today.daysUntil(due)
            lines.append("\(star.title) is \(days <= 0 ? "today" : days == 1 ? "tomorrow" : "in \(days) days").")
        }
        return .result(dialog: IntentDialog(stringLiteral: lines.joined(separator: " ")))
    }
}

struct WorkspaceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: AddTaskIntent(), phrases: [
            "Add a task in \(.applicationName)",
            "New \(.applicationName) task",
            "Add a task to \(\.$list) in \(.applicationName)",
            "Add to \(\.$list) in \(.applicationName)",
            "New \(\.$list) task in \(.applicationName)",
        ], shortTitle: "Add Task", systemImageName: "plus.circle")
        AppShortcut(intent: DueTodayIntent(), phrases: [
            "What's due today in \(.applicationName)",
            "What's left in \(.applicationName)",
        ], shortTitle: "Due Today", systemImageName: "checklist")
    }
}
