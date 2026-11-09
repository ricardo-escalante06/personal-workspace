import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// The popover that opens where you drag on the calendar.
///
/// Task block (default): type to search open tasks (current scope first) and pick
/// one; or type a class/list code ("cs61a read ch 4") to make a new task there.
/// Event: title + calendar.
struct QuickScheduleView: View {
    @Environment(AppModel.self) private var model
    let start: Date
    let end: Date
    let scope: UUID?
    let onDone: () -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case block = "Task block", event = "Event"
        var id: String { rawValue }
    }

    @State private var mode: Mode = .block
    @State private var query = ""
    @State private var tasks: [TaskItem] = []
    @State private var highlighted = 0
    @State private var calendarId: String?
    @FocusState private var focused: Bool

    private enum Option: Identifiable {
        case existing(TaskItem)
        case newTask(title: String, containerId: UUID?)
        var id: String {
            switch self {
            case .existing(let t): "t-\(t.id)"
            case .newTask(let title, let c): "n-\(title)-\(c?.uuidString ?? "inbox")"
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: WSSpace.s) {
            HStack {
                Text(timeText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WSColor.textSecondary)
                Spacer()
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            TextField(mode == .block ? "Search tasks, or type a new one…" : "Event title", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: query) { highlighted = 0 }
                .padding(.vertical, 4)

            Divider()

            switch mode {
            case .block: optionList
            case .event: eventFields
            }
        }
        .padding(WSSpace.m)
        .frame(width: 380)
        .onAppear {
            focused = true
            calendarId = model.calendarSource.defaultCalendarId
        }
        .task { await loadTasks() }
        .onKeyPress(.downArrow) { highlighted = min(highlighted + 1, max(options.count - 1, 0)); return .handled }
        .onKeyPress(.upArrow) { highlighted = max(highlighted - 1, 0); return .handled }
        .onEscape(onDone)
    }

    private var timeText: String {
        let day = start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day) · \(WSFormat.range(start, end))"
    }

    // MARK: Task block

    private func loadTasks() async {
        tasks = (try? await model.store.db.read { db in
            try ScopeQuery.tasks(in: nil)
                .filter(![TaskStatus.done.rawValue, TaskStatus.cancelled.rawValue].contains(Column("status")))
                .fetchAll(db)
        }) ?? []
    }

    /// Where a brand-new task goes when no container is typed.
    private var defaultDestination: UUID? {
        guard let scope, let c = model.container(scope) else { return nil }
        return c.kind.holdsTasks ? c.id : c.defaultListId
    }

    private func inScope(_ t: TaskItem) -> Bool {
        guard let scope, let path = model.container(scope)?.path else { return false }
        return model.container(t.containerId)?.path.hasPrefix(path) ?? false
    }

    private var options: [Option] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            // Suggestions: scope first, then soonest due.
            let sorted = tasks.sorted { a, b in
                if inScope(a) != inScope(b) { return inScope(a) }
                switch (a.dueDate, b.dueDate) {
                case let (x?, y?): return x < y
                case (_?, nil): return true
                default: return a.sortRank < b.sortRank
                }
            }
            return sorted.prefix(7).map(Option.existing)
        }
        var scored: [(Int, TaskItem)] = []
        for t in tasks {
            let context = model.container(t.containerId)?.name ?? ""
            if let s = FuzzyMatch.score(q, in: t.title) ?? FuzzyMatch.score(q, in: "\(context) \(t.title)") {
                scored.append((s + (inScope(t) ? 8 : 0), t))
            }
        }
        var result = scored.sorted { $0.0 > $1.0 }.prefix(6).map { Option.existing($0.1) }

        // "cs61a read ch 4" → new task in CS61A.
        let parsed = QuickAddParser(
            containers: model.containers.map { .init(id: $0.id, name: $0.name, holdsTasks: $0.kind.holdsTasks) },
            categories: [], today: LocalDate(Date())
        ).parse(q)
        if let c = parsed.containerId, !parsed.title.isEmpty {
            result.append(.newTask(title: parsed.title, containerId: c))
        } else {
            result.append(.newTask(title: q, containerId: defaultDestination))
        }
        return result
    }

    private var optionList: some View {
        let list = options
        return VStack(alignment: .leading, spacing: 2) {
            if query.isEmpty && !list.isEmpty {
                Text(scope == nil ? "Suggested" : "Suggested · \(model.container(scope)?.name ?? "")")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WSColor.textTertiary)
                    .padding(.horizontal, 6)
            }
            if list.isEmpty {
                Text("Type to create a task for this time.")
                    .font(.system(size: 12))
                    .foregroundStyle(WSColor.textTertiary)
                    .padding(6)
            }
            ForEach(Array(list.enumerated()), id: \.element.id) { index, option in
                optionRow(option, highlighted: index == highlighted)
                    .onTapGesture { highlighted = index; commit() }
            }
        }
    }

    private func optionRow(_ option: Option, highlighted: Bool) -> some View {
        HStack(spacing: WSSpace.s) {
            switch option {
            case .existing(let t):
                let c = model.container(t.containerId)
                Circle().fill(ContainerColor(named: c?.color ?? "grey").accent).frame(width: 7, height: 7)
                Text(t.title).foregroundStyle(WSColor.textPrimary).lineLimit(1)
                Text(c?.name ?? "Inbox").foregroundStyle(WSColor.textTertiary).lineLimit(1)
                Spacer(minLength: 0)
                if let due = WSFormat.due(t, today: LocalDate(Date())) {
                    Label(due, systemImage: "flag").labelStyle(.titleAndIcon)
                        .font(.system(size: 11)).foregroundStyle(WSColor.textSecondary)
                }
            case .newTask(let title, let containerId):
                Image(systemName: "plus.circle").foregroundStyle(WSColor.action)
                Text("New task “\(title)”").foregroundStyle(WSColor.textPrimary).lineLimit(1)
                Text("in \(model.container(containerId)?.name ?? "Inbox")").foregroundStyle(WSColor.textTertiary)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 13))
        .padding(.horizontal, 6).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(highlighted ? WSColor.hairline : .clear))
        .contentShape(Rectangle())
    }

    // MARK: Event

    @ViewBuilder private var eventFields: some View {
        if model.calendarSource.writableCalendars.isEmpty {
            Text("No writable calendars. Connect Google or allow calendar access.")
                .font(.system(size: 12)).foregroundStyle(WSColor.textSecondary)
        } else {
            Picker("Calendar", selection: $calendarId) {
                ForEach(model.calendarSource.writableCalendars) { cal in
                    Text("\(cal.title) · \(cal.account)").tag(String?.some(cal.id))
                }
            }
            HStack {
                Spacer()
                Button("Create Event", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    // MARK: Commit

    private func commit() {
        switch mode {
        case .event:
            let title = query.trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            model.createEvent(title: title, start: start, end: end, calendarId: calendarId)
        case .block:
            let list = options
            guard list.indices.contains(highlighted) else { return }
            switch list[highlighted] {
            case .existing(let t):
                model.addBlock(to: t.id, start: start, end: end)
            case .newTask(let title, let containerId):
                guard !title.isEmpty else { return }
                model.createTaskWithBlock(title: title, containerId: containerId, start: start, end: end)
            }
        }
        onDone()
    }
}
