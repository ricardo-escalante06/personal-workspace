import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// The full Calendar page (DESIGN.md §4.3): Day / Week / Month, modeled on the
/// readability of Notion Calendar. Shows task work blocks, task deadlines and
/// system-calendar events (Google included) together.
///
/// Keys: ⌃⌘1 / ⌃⌘2 / ⌃⌘3 switch views, ⌘T today, ⌘[ / ⌘] (or ← →) move, Esc clears
/// the selection, Delete removes the selection. Sideways scroll moves one day at a time.
struct CalendarView: View {
    @Environment(AppModel.self) private var model

    @State private var items: [CalendarItem] = []
    /// Timed items laid out per day: computed once per data change, not per frame.
    @State private var placed: [LocalDate: [PlacedItem]] = [:]
    @State private var selection: Set<String> = []
    @State private var createRequest: CalendarCreateRequest?
    @FocusState private var focused: Bool

    private var tz: TimeZone { .current }
    private var source: CalendarSource { model.calendarSource }

    /// The visible days for the current mode. Week = 7 days starting at the anchor
    /// (the anchor sits on a Sunday unless you scroll sideways).
    private var days: [LocalDate] {
        switch model.calendarMode {
        case .day:
            return [model.calendarAnchor]
        case .week:
            return (0..<7).map { model.calendarAnchor.adding(days: $0) }
        case .month:
            let first = LocalDate(year: model.calendarAnchor.year, month: model.calendarAnchor.month, day: 1)
            let gridStart = Dashboard.weekStart(containing: first)
            return (0..<42).map { gridStart.adding(days: $0) }
        }
    }

    private var range: (Date, Date) {
        let d = days
        return (d.first!.startOfDay(in: tz), d.last!.adding(days: 1).startOfDay(in: tz))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(WSColor.hairline)
            if !source.hasAnyCalendars {
                accessBanner
            }
            switch model.calendarMode {
            case .day, .week:
                TimeGridView(
                    days: days,
                    items: items,
                    placed: placed,
                    selection: $selection,
                    styleFor: style(for:),
                    scope: model.calendarScope,
                    onMove: move,
                    onClick: click,
                    onOpen: open,
                    onScrollDays: { scrollDays($0) }
                )
            case .month:
                MonthGridView(
                    days: days,
                    month: model.calendarAnchor.month,
                    items: items,
                    colorFor: style(for:),
                    tagFor: { model.tagStyle($0.categoryId) },
                    onPickDay: { day in
                        model.calendarAnchor = day
                        model.calendarMode = .day
                    },
                    onSelect: { click($0, additive: false) }
                )
            }
        }
        .background(WSColor.canvas)
        .task(id: LoadKey(days: days, scope: model.calendarScope, revision: source.revision,
                          hidden: source.effectiveHiddenCalendarIds, access: source.access)) {
            await load()
        }
        // While the calendar is open, ask macOS to pull Google/iCloud changes every minute.
        .task {
            while !Task.isCancelled {
                source.refresh()
                try? await Task.sleep(for: .seconds(60))
            }
        }
        .sheet(item: $createRequest) { request in
            QuickScheduleView(start: request.start, end: request.end, scope: model.calendarScope) {
                createRequest = nil
            }
        }
        #if os(macOS)
        .background(KeyDownCatcher { event in handleKey(event) })
        #endif
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onAppear {
            focused = true
            if model.calendarMode == .week, model.calendarAnchor == LocalDate(Date()) {
                model.calendarAnchor = Dashboard.weekStart(containing: model.calendarAnchor)
            }
        }
        .onKeyPress(.leftArrow) { step(-1); return .handled }
        .onKeyPress(.rightArrow) { step(1); return .handled }
        .onKeyPress(keys: [.delete, .deleteForward]) { _ in
            let selected = items.filter { selection.contains($0.id) }
            guard !selected.isEmpty else { return .ignored }
            model.deleteCalendarItems(selected)
            selection = []
            return .handled
        }
        .onKeyPress(.escape) {
            guard !selection.isEmpty else { return .ignored }
            selection = []
            return .handled
        }
    }

    #if os(macOS)
    /// Delete / Esc / ← → while the calendar is on screen (even without keyboard focus).
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 51, 117:   // delete, forward delete
            let selected = items.filter { selection.contains($0.id) }
            guard !selected.isEmpty else { return false }
            model.deleteCalendarItems(selected)
            selection = []
            return true
        case 53:        // escape
            guard !selection.isEmpty else { return false }
            selection = []
            return true
        case 123: step(-1); return true   // ←
        case 124: step(1); return true    // →
        default: return false
        }
    }
    #endif

    private struct LoadKey: Hashable {
        var days: [LocalDate]
        var scope: UUID?
        var revision: Int
        var hidden: Set<String>
        var access: CalendarSource.Access
    }

    /// Loads events from EventKit for the range, then keeps task data live via GRDB.
    private func load() async {
        let (start, end) = range
        let events = source.events(from: start, to: end)
        var options = CalendarQuery.Options()
        options.hiddenCalendars = source.effectiveHiddenCalendarIds
        let scope = model.calendarScope
        let visibleDays = days
        let observation = ValueObservation.tracking { db in
            try CalendarQuery.items(db, scope: scope, from: start, to: end, events: events, options: options)
        }
        do {
            for try await value in observation.values(in: model.store.db) {
                items = value
                var byDay: [LocalDate: [PlacedItem]] = [:]
                for day in visibleDays {
                    byDay[day] = TimeGridLayout.layout(value, dayStart: day.startOfDay(in: tz),
                                                       dayEnd: day.adding(days: 1).startOfDay(in: tz))
                }
                placed = byDay
                selection = selection.filter { id in value.contains { $0.id == id } }
            }
        } catch {}
    }

    // MARK: Header

    private var title: String {
        switch model.calendarMode {
        case .day: return model.calendarAnchor.startOfDay(in: tz).formatted(.dateTime.weekday(.wide).month(.wide).day().year())
        case .week: return WSFormat.monthYear(days[3])
        case .month: return WSFormat.monthYear(model.calendarAnchor)
        }
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: WSSpace.m) {
                titleText
                scopeMenu
                Spacer(minLength: WSSpace.m)
                controls
            }
            VStack(alignment: .leading, spacing: WSSpace.s) {
                HStack(spacing: WSSpace.m) {
                    titleText
                    scopeMenu
                    Spacer(minLength: 0)
                }
                HStack(spacing: WSSpace.m) {
                    Spacer(minLength: 0)
                    controls
                }
            }
        }
        .padding(.horizontal, WSSpace.xl)
        .padding(.vertical, WSSpace.m)
    }

    private var titleText: some View {
        Text(title)
            .font(.system(size: 22, weight: .bold))
            .foregroundStyle(WSColor.textPrimary)
            .lineLimit(1)
            .fixedSize()
    }

    private var controls: some View {
        HStack(spacing: WSSpace.m) {
            if source.isGoogleAvailable && !source.isGoogleConnected {
                Button {
                    model.connectGoogle()
                } label: {
                    Label("Connect Google", systemImage: "person.crop.circle.badge.plus")
                }
                .help("Connect Google Calendar for invites, RSVP and Meet links")
            }
            if selection.count > 1 {
                Text("\(selection.count) selected")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WSColor.textSecondary)
            }
            Picker("View", selection: Binding(get: { model.calendarMode }, set: { setMode($0) })) {
                ForEach(CalendarMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 190)
            .help("⌃⌘1 · ⌃⌘2 · ⌃⌘3")

            HStack(spacing: WSSpace.xs) {
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                    .help("Previous (⌘[)")
                Button("Today", action: goToToday)
                    .help("Today (⌘T)")
                Button { step(1) } label: { Image(systemName: "chevron.right") }
                    .help("Next (⌘])")
            }
            .buttonStyle(.borderless)

            Button {
                let start = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
                createRequest = CalendarCreateRequest(start: start, end: start.addingTimeInterval(3600))
            } label: {
                Image(systemName: "plus")
            }
            .help("New block or event")
        }
        .fixedSize()
    }

    private var scopeMenu: some View {
        Menu {
            Button("All Workspace") { model.calendarScope = nil }
            Divider()
            ForEach(model.containersInSidebarOrder.filter { $0.archivedAt == nil }) { c in
                Button(String(repeating: "   ", count: max(0, c.depth - 1)) + c.name) { model.calendarScope = c.id }
            }
        } label: {
            HStack(spacing: 4) {
                if let c = model.container(model.calendarScope) {
                    Circle().fill(ContainerColor(named: c.color).accent).frame(width: 7, height: 7)
                    Text(c.name)
                } else {
                    Text("All Workspace")
                }
            }
            .font(.system(size: 12, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Filter the calendar to a folder, class or project")
    }

    private var accessBanner: some View {
        HStack(spacing: WSSpace.m) {
            Image(systemName: "calendar.badge.plus")
                .foregroundStyle(WSColor.textSecondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Bring in your calendars")
                    .font(.system(size: 13, weight: .semibold))
                Text(source.isGoogleAvailable
                     ? "Connect Google Calendar for invites, RSVP and Meet links. Other calendars (iCloud…) come from this Mac."
                     : "Workspace reads the calendars on this Mac, including Google accounts added in System Settings › Internet Accounts.")
                    .font(.system(size: 12))
                    .foregroundStyle(WSColor.textSecondary)
            }
            Spacer()
            if source.isGoogleAvailable {
                Button("Connect Google") { model.connectGoogle() }
                    .buttonStyle(.borderedProminent)
            }
            if source.access == .notDetermined || source.access == .writeOnly {
                Button("Allow Mac Calendars") { Task { await source.requestAccess() } }
            }
        }
        .padding(.horizontal, WSSpace.xl).padding(.vertical, WSSpace.m)
        .background(WSColor.weekend)
    }

    // MARK: Navigation

    private func setMode(_ mode: CalendarMode) {
        model.calendarMode = mode
        if mode == .week { model.calendarAnchor = Dashboard.weekStart(containing: model.calendarAnchor) }
    }

    private func goToToday() {
        let today = LocalDate(Date())
        model.calendarAnchor = model.calendarMode == .week ? Dashboard.weekStart(containing: today) : today
    }

    private func step(_ direction: Int) {
        model.stepCalendar(direction)
    }

    /// Sideways scroll: slide the visible days one at a time.
    private func scrollDays(_ delta: Int) {
        guard model.calendarMode != .month else { return }
        model.calendarAnchor = model.calendarAnchor.adding(days: delta)
    }

    // MARK: Styling

    private func style(for item: CalendarItem) -> BlockStyle {
        if let c = model.container(item.containerId) {
            let cc = ContainerColor(named: c.color)
            return BlockStyle(accent: cc.accent, fill: cc.fill)
        }
        if let e = item.event {
            // Unlinked events use their calendar's color (or your override).
            // Google per-event color wins, then your calendar override, then the calendar's color.
            let hex = e.eventColor ?? source.color(forCalendar: e.calendarId, fallback: e.calendarColor)
            return BlockStyle(accent: Color(hex: hex), fill: Color(hex: hex).opacity(0.28))
        }
        return BlockStyle(accent: ContainerColor.grey.accent, fill: ContainerColor.grey.fill)
    }

    // MARK: Selection + editing

    /// Click: select only this. ⇧/⌘-click: add or remove from the selection.
    private func click(_ item: CalendarItem, additive: Bool) {
        if additive {
            if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
        } else {
            selection = [item.id]
        }
        if let taskId = item.taskId {
            model.select(taskId)
        } else if let event = item.event {
            model.inspect(event, open: false)
        }
    }

    private func open(_ item: CalendarItem) {
        selection = [item.id]
        if let taskId = item.taskId {
            model.openDetails(taskId)
        } else if let event = item.event {
            model.inspect(event, open: true)
        }
    }

    /// A drag/resize ended on `item`. If it's part of a multi-selection, the same
    /// time shift applies to every selected item. Work blocks and deadlines move
    /// right away; calendar events ask first.
    private func move(_ item: CalendarItem, _ start: Date, _ end: Date, resized: Bool) {
        let group: [CalendarItem] = (!resized && selection.contains(item.id) && selection.count > 1)
            ? items.filter { selection.contains($0.id) && $0.isEditable }
            : [item]
        let shift = start.timeIntervalSince(item.start)
        var eventMoves: [PendingEventMove.Move] = []
        let taskIds = group.compactMap(\.taskId)
        let name = resized ? "Resize" : (group.count > 1 ? "Move \(group.count) Items" : "Move")

        model.undoable(name, taskIds) {
            for target in group {
                let newStart = target.id == item.id ? start : target.start.addingTimeInterval(shift)
                let newEnd = target.id == item.id ? end : target.end.addingTimeInterval(shift)
                switch target.source {
                case .block(_, let blockId):
                    try model.store.updateScheduleBlock(blockId, start: newStart, end: newEnd)
                case .deadline(let taskId):
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: newStart)
                    try model.store.editTask(taskId) { t in
                        t.dueDate = LocalDate(newStart)
                        if t.dueTime != nil { t.dueTime = LocalTime(hour: comps.hour ?? 0, minute: comps.minute ?? 0) }
                    }
                case .event(let event):
                    eventMoves.append(.init(event: event, start: newStart, end: newEnd))
                }
            }
        }
        if !eventMoves.isEmpty {
            model.pendingEventMove = PendingEventMove(moves: eventMoves)
        }
    }
}

/// Fill + accent for a block.
struct BlockStyle {
    var accent: Color
    var fill: Color
}

/// One or more calendar-event moves awaiting confirmation.
struct PendingEventMove: Identifiable {
    struct Move {
        var event: ExternalEvent
        var start: Date
        var end: Date
    }
    let id = UUID()
    var moves: [Move]

    var title: String {
        moves.count == 1 ? "Move “\(moves[0].event.title)”?" : "Move \(moves.count) events?"
    }
    var calendars: String {
        Set(moves.map(\.event.calendarTitle)).sorted().joined(separator: ", ")
    }
}

struct CalendarCreateRequest: Identifiable {
    let id = UUID()
    var start: Date
    var end: Date
}
