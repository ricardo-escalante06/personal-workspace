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
    @State private var popoverItemId: String?
    /// Tasks with a start date show as a bar up to their due date.
    @AppStorage("showTaskSpans") private var showTaskSpans = true
    @FocusState private var focused: Bool

    private var tz: TimeZone { .current }
    private var source: CalendarSource { model.calendarSource }

    /// The visible days for the current mode. Week = 7 days starting at the anchor
    /// (today by default, or a Sunday; see `AppModel.weekAnchor`).
    private var days: [LocalDate] {
        switch model.calendarMode {
        case .day:
            return [model.calendarAnchor]
        case .week:
            return (0..<CalendarMode.weekLength).map { model.calendarAnchor.adding(days: $0) }
        case .month:
            let first = LocalDate(year: model.calendarAnchor.year, month: model.calendarAnchor.month, day: 1)
            let gridStart = Dashboard.weekStart(containing: first)
            return (0..<42).map { gridStart.adding(days: $0) }
        }
    }

    /// What the grid draws and loads: the visible days plus one more on each side, just
    /// off screen, so sideways scrolling slides into real days instead of blank space.
    private var gridDays: [LocalDate] {
        guard model.calendarMode != .month else { return days }
        let d = days
        return [d.first!.adding(days: -1)] + d + [d.last!.adding(days: 1)]
    }

    private var range: (Date, Date) {
        let d = gridDays
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
                    days: gridDays,
                    lead: 1,
                    visibleCount: days.count,
                    items: items,
                    placed: placed,
                    selection: $selection,
                    styleFor: style(for:),
                    scope: model.calendarScope,
                    onMove: move,
                    onClick: click,
                    onOpen: open,
                    onScrollDays: { scrollDays($0) },
                    popoverItemId: $popoverItemId
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
        #if os(iOS)
        .overlay(alignment: .bottomTrailing) {
            FloatingAddButton {
                let start = Calendar.current.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date()
                createRequest = CalendarCreateRequest(start: start, end: start.addingTimeInterval(3600))
            }
        }
        #endif
        .task(id: LoadKey(days: gridDays, scope: model.calendarScope, revision: source.revision,
                          hidden: source.effectiveHiddenCalendarIds, access: source.access,
                          overrides: model.eventOverrides, creates: Set(model.pendingEventCreates.keys),
                          spans: showTaskSpans)) {
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
                model.calendarAnchor = model.weekAnchor(for: model.calendarAnchor)
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
        // When a details popover closes, keys (⌘C, ⌘V, Delete) go back to the calendar.
        .onChange(of: popoverItemId) { _, id in if id == nil { focused = true } }
        #if os(macOS)
        // Edit › Copy / Cut / Paste (⌘C / ⌘X / ⌘V) while the calendar has focus.
        .onCommand(#selector(NSText.copy(_:))) { copySelection() }
        .onCommand(#selector(NSText.cut(_:))) { copySelection(); model.deleteCalendarItems(items.filter { selection.contains($0.id) }) }
        .onCommand(#selector(NSText.paste(_:))) { paste() }
        #endif
    }

    /// ⌘C: work blocks and events (deadlines aren't copied; they belong to their task).
    private func copySelection() {
        let picked = items.filter { selection.contains($0.id) && !$0.isDeadline }
        guard !picked.isEmpty else { return }
        model.calendarClipboard = picked
    }

    /// ⌘V: a copy in the same spot as the original, selected so you can drag it where
    /// it goes. ⌘Z removes it.
    private func paste() {
        let clip = model.calendarClipboard
        guard !clip.isEmpty else { return }
        popoverItemId = nil
        let newIds = model.pasteCalendarItems(clip, shift: 0)
        if !newIds.isEmpty { selection = Set(newIds) }
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
        var overrides: [String: AppModel.EventOverride]
        var creates: Set<String>
        var spans: Bool
    }

    /// Loads events from EventKit for the range, then keeps task data live via GRDB.
    private func load() async {
        let (start, end) = range
        let events = model.applyingOverrides(source.events(from: start, to: end))
        var options = CalendarQuery.Options()
        options.hiddenCalendars = source.effectiveHiddenCalendarIds
        options.showSpans = showTaskSpans
        let scope = model.calendarScope
        let visibleDays = gridDays
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
        case .week: return WSFormat.monthYear(days[days.count / 2])
        case .month: return WSFormat.monthYear(model.calendarAnchor)
        }
    }

    #if os(iOS)
    /// iPhone: title and arrows on one line, view picker and filter below.
    private var header: some View {
        VStack(alignment: .leading, spacing: WSSpace.s) {
            HStack(spacing: WSSpace.m) {
                Text(title)
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1).minimumScaleFactor(0.7)
                Spacer(minLength: 0)
                Button { step(-1) } label: { Image(systemName: "chevron.left") }
                Button("Today", action: goToToday)
                Button { step(1) } label: { Image(systemName: "chevron.right") }
            }
            HStack(spacing: WSSpace.m) {
                Picker("View", selection: Binding(get: { model.calendarMode }, set: { setMode($0) })) {
                    ForEach(CalendarMode.allCases) { mode in Text(mode.title).tag(mode) }
                }
                .pickerStyle(.segmented)
                scopeMenu
            }
        }
        .padding(.horizontal, WSSpace.l)
        .padding(.vertical, WSSpace.s)
    }
    #else
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
    #endif

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
                    Text(mode.title).tag(mode)
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
            Divider()
            Toggle("Show Task Spans", isOn: $showTaskSpans)
            #if os(iOS)
            Button("Show or Hide Calendars…") { model.showCalendarPicker = true }
            #endif
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

    #if os(iOS)
    private var accessBanner: some View {
        VStack(alignment: .leading, spacing: WSSpace.s) {
            Text("Bring in your calendars").font(.system(size: 14, weight: .semibold))
            HStack {
                if source.isGoogleAvailable && !source.isGoogleConnected {
                    Button("Connect Google") { model.connectGoogle() }.buttonStyle(.borderedProminent)
                }
                if source.access == .notDetermined || source.access == .writeOnly {
                    Button("Allow Calendars") { Task { await source.requestAccess() } }.buttonStyle(.bordered)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, WSSpace.l).padding(.vertical, WSSpace.s)
        .background(WSColor.weekend)
    }
    #else
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
    #endif

    // MARK: Navigation

    private func setMode(_ mode: CalendarMode) {
        model.calendarMode = mode
        if mode == .week { model.calendarAnchor = model.weekAnchor(for: model.calendarAnchor) }
    }

    private func goToToday() {
        let today = LocalDate(Date())
        model.calendarAnchor = model.calendarMode == .week ? model.weekAnchor(for: today) : today
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

    /// The edge line is the calendar's color (or the class/project it belongs to);
    /// the fill is the event's own color when it has one.
    private func style(for item: CalendarItem) -> BlockStyle {
        let eventFill = item.event?.eventColor.map { Color(hex: $0).opacity(0.26) }
        if let c = model.container(item.containerId) {
            let cc = ContainerColor(named: c.color)
            return BlockStyle(accent: cc.accent, fill: eventFill ?? cc.fill)
        }
        if let e = item.event {
            let calendar = Color(hex: source.color(forCalendar: e.calendarId, fallback: e.calendarColor))
            return BlockStyle(accent: calendar, fill: eventFill ?? calendar.opacity(0.2))
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
        // One click shows the details (⇧/⌘-click just adds to the selection). On the Mac
        // they pop up beside the block, unless the side panel is already open.
        #if os(macOS)
        let usePopover = !additive && !model.showInspector
        #else
        let usePopover = false
        #endif
        if let taskId = item.taskId {
            if additive || usePopover { model.select(taskId) } else { model.openDetails(taskId) }
        } else if let event = item.event {
            model.inspect(event, open: !additive && !usePopover)
        }
        if usePopover { popoverItemId = item.id }
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
                case .span(let taskId):
                    // The whole span moves: start and due date together.
                    let days = LocalDate(target.start).daysUntil(LocalDate(newStart))
                    try model.store.editTask(taskId) { t in
                        t.startDate = t.startDate?.adding(days: days)
                        t.dueDate = t.dueDate?.adding(days: days)
                    }
                case .event(let event):
                    eventMoves.append(.init(event: event, start: newStart, end: newEnd))
                }
            }
        }
        if !eventMoves.isEmpty {
            model.requestEventMoves(eventMoves)
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
        moves.count == 1 ? "“\(moves[0].event.title)” repeats" : "Some of these events repeat"
    }
    var hasRepeating: Bool { moves.contains { $0.event.isRecurring } }
    var calendars: String {
        Set(moves.map(\.event.calendarTitle)).sorted().joined(separator: ", ")
    }
}

struct CalendarCreateRequest: Identifiable {
    let id = UUID()
    var start: Date
    var end: Date
}
