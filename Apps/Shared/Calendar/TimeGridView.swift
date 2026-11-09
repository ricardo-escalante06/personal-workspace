import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// Day/week time grid in the style of the Notion Calendar screenshot:
/// hour gutter, all-day row, red now-line, colored blocks with a left accent bar.
///
/// Interactions
///  - drag (or click) on empty time → create a work block or event there
///  - drag an item → move it (15-minute snapping, across days); moves the whole
///    selection when several are selected
///  - drag a block's bottom edge → resize
///  - click → select · ⇧/⌘-click → add to selection · double-click → open details
///  - sideways scroll / swipe → move one day at a time
struct TimeGridView: View {
    @Environment(AppModel.self) private var model

    let days: [LocalDate]
    let items: [CalendarItem]
    let placed: [LocalDate: [PlacedItem]]
    @Binding var selection: Set<String>
    let styleFor: (CalendarItem) -> BlockStyle
    /// Scope for the create popover's suggestions.
    let scope: UUID?
    let onMove: (CalendarItem, Date, Date, _ resized: Bool) -> Void
    let onClick: (CalendarItem, _ additive: Bool) -> Void
    let onOpen: (CalendarItem) -> Void
    let onScrollDays: (Int) -> Void

    static let hourHeight: CGFloat = 52
    static let gutter: CGFloat = 58
    static let snapMinutes = 15.0

    @State private var drag: DragPreview?
    @State private var ghost: Ghost?
    /// A finished drag-to-create, kept visible while its popover is open.
    @State private var pendingCreate: Ghost?
    @State private var dropTargetDay: Int?
    @State private var now = Date()
    @State private var scrollAccumulator: CGFloat = 0
    @State private var isHovering = false

    private struct DragPreview: Equatable {
        var itemId: String
        var dx: CGFloat
        var dy: CGFloat
        var resizeOnly: Bool
        /// Ids moving together (the selection, if the dragged item is in it).
        var group: Set<String>
    }

    private struct Ghost: Equatable {
        var day: Int
        var y0: CGFloat
        var y1: CGFloat
    }

    private var tz: TimeZone { .current }
    private var today: LocalDate { LocalDate(now, in: tz) }

    var body: some View {
        VStack(spacing: 0) {
            dayHeader
            allDayRow
            Rectangle().fill(WSColor.hairline).frame(height: 1)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    HStack(alignment: .top, spacing: 0) {
                        hourGutter
                        GeometryReader { geo in
                            grid(width: geo.size.width)
                        }
                    }
                    .frame(height: Self.hourHeight * 24)
                }
                .onAppear { proxy.scrollTo("hour-7", anchor: .top) }
            }
            .onHover { isHovering = $0 }
            #if os(macOS)
            .background(HorizontalScrollCatcher(isActive: isHovering) { dx in handleSideways(dx) })
            #endif
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                now = Date()
            }
        }
    }

    /// Accumulates horizontal scroll; every column-ish of travel moves one day.
    private func handleSideways(_ dx: CGFloat) {
        scrollAccumulator += dx
        let threshold: CGFloat = 70
        while abs(scrollAccumulator) >= threshold {
            // Natural scrolling: swiping left (negative dx) moves forward in time.
            onScrollDays(scrollAccumulator < 0 ? 1 : -1)
            scrollAccumulator += scrollAccumulator < 0 ? threshold : -threshold
        }
    }

    // MARK: Header + all-day

    private var dayHeader: some View {
        HStack(spacing: 0) {
            Text(tz.abbreviation() ?? "")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WSColor.textTertiary)
                .frame(width: Self.gutter)
            ForEach(days, id: \.self) { day in
                let isToday = day == today
                HStack(spacing: 5) {
                    Text(WSFormat.weekdayShort(day))
                        .foregroundStyle(isToday ? WSColor.textPrimary : WSColor.textSecondary)
                    Text("\(day.day)")
                        .font(.system(size: 13, weight: isToday ? .bold : .regular).monospacedDigit())
                        .foregroundStyle(isToday ? Color.white : WSColor.textSecondary)
                        .padding(.horizontal, isToday ? 5 : 0)
                        .padding(.vertical, 1)
                        .background(RoundedRectangle(cornerRadius: 4).fill(isToday ? WSColor.now : .clear))
                }
                .font(.system(size: 13))
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) {
                    model.calendarAnchor = day
                    model.calendarMode = .day
                }
            }
        }
        .padding(.vertical, WSSpace.s)
    }

    private var allDayRow: some View {
        let allDay = items.filter(\.isAllDay)
        let maxShown = 3
        return HStack(alignment: .top, spacing: 0) {
            Text("All-day")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(WSColor.textTertiary)
                .frame(width: Self.gutter, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 6)
            ForEach(days, id: \.self) { day in
                let dayStart = day.startOfDay(in: tz), dayEnd = day.adding(days: 1).startOfDay(in: tz)
                let chips = allDay.filter { $0.start < dayEnd && $0.end > dayStart }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(chips.prefix(maxShown)) { item in
                        allDayChip(item)
                    }
                    if chips.count > maxShown {
                        Text("+\(chips.count - maxShown) more")
                            .font(.system(size: 10.5))
                            .foregroundStyle(WSColor.textTertiary)
                            .padding(.leading, 4)
                    }
                }
                .padding(3)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
                .overlay(alignment: .leading) { Rectangle().fill(WSColor.hairline).frame(width: 1) }
            }
        }
    }

    private func allDayChip(_ item: CalendarItem) -> some View {
        let style = styleFor(item)
        let isDeadline = item.isDeadline
        let isSelected = selection.contains(item.id)
        return HStack(spacing: 4) {
            if isDeadline {
                Image(systemName: "flag.fill").font(.system(size: 8))
                    .foregroundStyle(style.accent)
            }
            Text(item.title).strikethrough(item.isDone).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(item.isDone ? WSColor.textTertiary : WSColor.textPrimary)
        .padding(.horizontal, 5).padding(.vertical, 2)
        // Deadlines are outlined markers; all-day events are filled. Never color alone.
        .background(RoundedRectangle(cornerRadius: 4).fill(isDeadline ? Color.clear : style.fill))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
            isSelected ? WSColor.textPrimary.opacity(0.8) : (isDeadline ? style.accent.opacity(0.6) : .clear)
        ))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { onOpen(item) }
        .simultaneousGesture(TapGesture().onEnded { onClick(item, Self.additiveClick) })
        .help(isDeadline ? "Due: \(item.title). Drag onto a time to schedule work on it." : item.title)
        .draggable(item.taskId.map { "due-\($0.uuidString)" } ?? "event-\(item.id)")
    }

    // MARK: Hours

    private var hourGutter: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                Text(hour == 0 ? "" : hourLabel(hour))
                    .font(.system(size: 10.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(WSColor.textTertiary)
                    .frame(width: Self.gutter - 8, alignment: .trailing)
                    .offset(y: -7)
                    .frame(width: Self.gutter, height: Self.hourHeight, alignment: .topLeading)
                    .id("hour-\(hour)")
            }
        }
        .overlay(alignment: .topTrailing) { nowPill }
    }

    private func hourLabel(_ hour: Int) -> String {
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h) \(hour < 12 ? "AM" : "PM")"
    }

    @ViewBuilder private var nowPill: some View {
        if days.contains(today) {
            Text(WSFormat.time(now, in: tz))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 4).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(WSColor.now))
                .offset(x: -2, y: y(for: now, on: today) - 9)
        }
    }

    private func y(for date: Date, on day: LocalDate) -> CGFloat {
        CGFloat(date.timeIntervalSince(day.startOfDay(in: tz)) / 3600) * Self.hourHeight
    }

    // MARK: Grid

    private func grid(width: CGFloat) -> some View {
        let columnWidth = width / CGFloat(days.count)
        return ZStack(alignment: .topLeading) {
            GridBackground(dayCount: days.count, weekendOrToday: days.map { isWeekend($0) || $0 == today })
                .frame(width: width, height: Self.hourHeight * 24)
                .contentShape(Rectangle())
                .gesture(createGesture(columnWidth: columnWidth))
                // Drop a task (from the all-day row, dashboard or Inbox) to time-block it.
                // The deadline stays where it is; this adds a 1-hour work block.
                .dropDestination(for: String.self) { payloads, location in
                    guard let payload = payloads.first, payload.hasPrefix("due-"),
                          let taskId = UUID(uuidString: String(payload.dropFirst(4))) else { return false }
                    let dayIndex = min(max(Int(location.x / columnWidth), 0), days.count - 1)
                    let top = snapY(location.y)
                    let start = days[dayIndex].startOfDay(in: tz).addingTimeInterval(TimeInterval(top / Self.hourHeight * 3600))
                    model.addBlock(to: taskId, start: start, end: start.addingTimeInterval(3600))
                    return true
                } isTargeted: { _ in }

            if let ghost {
                let top = min(ghost.y0, ghost.y1), bottom = max(ghost.y0, ghost.y1)
                RoundedRectangle(cornerRadius: WSRadius.block)
                    .fill(WSColor.action.opacity(0.25))
                    .overlay(RoundedRectangle(cornerRadius: WSRadius.block).strokeBorder(WSColor.action, lineWidth: 1))
                    .overlay(alignment: .topLeading) {
                        Text(ghostLabel(ghost))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(WSColor.textPrimary)
                            .padding(4)
                    }
                    .frame(width: columnWidth - 6, height: max(bottom - top, Self.hourHeight / 4))
                    .offset(x: CGFloat(ghost.day) * columnWidth + 3, y: top)
                    .allowsHitTesting(false)
            }

            if let pending = pendingCreate {
                let top = min(pending.y0, pending.y1), bottom = max(pending.y0, pending.y1)
                RoundedRectangle(cornerRadius: WSRadius.block)
                    .fill(WSColor.action.opacity(0.3))
                    .overlay(RoundedRectangle(cornerRadius: WSRadius.block).strokeBorder(WSColor.action, lineWidth: 1))
                    .frame(width: columnWidth - 6, height: bottom - top)
                    .popover(isPresented: Binding(get: { pendingCreate != nil }, set: { if !$0 { pendingCreate = nil } }),
                             arrowEdge: .trailing) {
                        let (start, end) = times(for: pending)
                        QuickScheduleView(start: start, end: end, scope: scope) { pendingCreate = nil }
                    }
                    .offset(x: CGFloat(pending.day) * columnWidth + 3, y: top)
            }

            ForEach(Array(days.enumerated()), id: \.element) { index, day in
                ForEach(placed[day] ?? []) { p in
                    itemView(p, day: day, dayIndex: index, columnWidth: columnWidth)
                }
            }

            if let todayIndex = days.firstIndex(of: today) {
                let nowY = y(for: now, on: today)
                Rectangle()
                    .fill(WSColor.now)
                    .frame(width: width, height: 1)
                    .offset(y: nowY)
                    .allowsHitTesting(false)
                Circle()
                    .fill(WSColor.now)
                    .frame(width: 7, height: 7)
                    .offset(x: CGFloat(todayIndex) * columnWidth - 3, y: nowY - 3)
                    .allowsHitTesting(false)
            }
        }
        .coordinateSpace(name: "grid")
    }

    private func isWeekend(_ day: LocalDate) -> Bool {
        let wd = WSFormat.weekdayShort(day)
        return wd == "Sat" || wd == "Sun"
    }

    // MARK: Items

    private func itemView(_ p: PlacedItem, day: LocalDate, dayIndex: Int, columnWidth: CGFloat) -> some View {
        let style = styleFor(p.item)
        let subWidth = (columnWidth - 4) / CGFloat(p.columnCount)
        let top = y(for: p.start, on: day)
        let height = max(CGFloat(p.end.timeIntervalSince(p.start) / 3600) * Self.hourHeight - 2, 16)
        let moving = drag.map { !$0.resizeOnly && $0.group.contains(p.item.id) } ?? false
        let resizing = drag.map { $0.resizeOnly && $0.itemId == p.item.id } ?? false
        let dx = moving ? drag!.dx : 0
        let dy = moving ? drag!.dy : 0
        let extra = resizing ? drag!.dy : 0
        let shift = snap(dy) + snapDays(dx, columnWidth) * 86_400

        return GridBlockView(
            item: p.item, style: style,
            timeText: p.item.isDeadline
                ? "due \(WSFormat.time(p.item.start.addingTimeInterval(shift), in: tz))"
                : WSFormat.range(p.item.start.addingTimeInterval(shift), p.item.end.addingTimeInterval(shift + snap(extra)), in: tz),
            isPast: p.end < now,
            isSelected: selection.contains(p.item.id),
            compact: height < 34
        )
        .frame(width: max(subWidth - 2, 10), height: max(height + extra, 16))
        .overlay(alignment: .bottom) {
            if p.item.isEditable && !p.item.isDeadline {
                Color.clear
                    .frame(height: 6)
                    .contentShape(Rectangle())
                    .gesture(resizeGesture(p))
                    #if os(macOS)
                    .onHover { inside in if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() } }
                    #endif
            }
        }
        .offset(x: CGFloat(dayIndex) * columnWidth + 2 + CGFloat(p.column) * subWidth + dx, y: top + 1 + dy)
        .zIndex(moving || resizing ? 10 : 1)
        .shadow(color: moving ? .black.opacity(0.35) : .clear, radius: 8, y: 4)
        .onTapGesture(count: 2) { onOpen(p.item) }
        .simultaneousGesture(TapGesture().onEnded { onClick(p.item, Self.additiveClick) })
        .gesture(p.item.isEditable ? moveGesture(p, columnWidth: columnWidth) : nil)
    }

    /// ⇧ or ⌘ held during a click.
    static var additiveClick: Bool {
        #if os(macOS)
        let flags = NSEvent.modifierFlags
        return flags.contains(.shift) || flags.contains(.command)
        #else
        return false
        #endif
    }

    private func snap(_ dy: CGFloat) -> TimeInterval {
        let minutes = Double(dy / Self.hourHeight) * 60
        return (minutes / Self.snapMinutes).rounded() * Self.snapMinutes * 60
    }

    private func snapDays(_ dx: CGFloat, _ columnWidth: CGFloat) -> Double {
        (dx / columnWidth).rounded()
    }

    private func moveGesture(_ p: PlacedItem, columnWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .named("grid"))
            .onChanged { v in
                let group: Set<String> = selection.contains(p.item.id) ? selection : [p.item.id]
                drag = DragPreview(itemId: p.item.id, dx: v.translation.width, dy: v.translation.height,
                                   resizeOnly: false, group: group)
            }
            .onEnded { v in
                drag = nil
                let dayShift = Int(snapDays(v.translation.width, columnWidth))
                let delta = snap(v.translation.height)
                guard dayShift != 0 || delta != 0 else { return }
                var calendar = Calendar.current
                calendar.timeZone = tz
                let start = calendar.date(byAdding: .day, value: dayShift, to: p.item.start)!.addingTimeInterval(delta)
                let end = calendar.date(byAdding: .day, value: dayShift, to: p.item.end)!.addingTimeInterval(delta)
                onMove(p.item, start, end, false)
            }
    }

    private func resizeGesture(_ p: PlacedItem) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .named("grid"))
            .onChanged { v in
                drag = DragPreview(itemId: p.item.id, dx: 0, dy: v.translation.height, resizeOnly: true, group: [])
            }
            .onEnded { v in
                drag = nil
                let newEnd = p.item.end.addingTimeInterval(snap(v.translation.height))
                guard newEnd != p.item.end else { return }
                onMove(p.item, p.item.start, max(newEnd, p.item.start.addingTimeInterval(Self.snapMinutes * 60)), true)
            }
    }

    private func createGesture(columnWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .named("grid"))
            .onChanged { v in
                let day = min(max(Int(v.startLocation.x / columnWidth), 0), days.count - 1)
                ghost = Ghost(day: day, y0: snapY(v.startLocation.y), y1: snapY(v.location.y))
            }
            .onEnded { v in
                defer { ghost = nil }
                // A plain click on empty space just clears the selection.
                if abs(v.translation.height) < 4, abs(v.translation.width) < 4, !selection.isEmpty {
                    selection = []
                    return
                }
                let dayIndex = min(max(Int(v.startLocation.x / columnWidth), 0), days.count - 1)
                let y0 = snapY(v.startLocation.y), y1 = snapY(v.location.y)
                let top = min(y0, y1)
                var bottom = max(y0, y1)
                if bottom - top < Self.hourHeight / 4 { bottom = top + Self.hourHeight }
                pendingCreate = Ghost(day: dayIndex, y0: top, y1: bottom)
            }
    }

    private func times(for g: Ghost) -> (Date, Date) {
        let day = days[g.day].startOfDay(in: tz)
        let top = min(g.y0, g.y1), bottom = max(g.y0, g.y1)
        return (day.addingTimeInterval(TimeInterval(top / Self.hourHeight * 3600)),
                day.addingTimeInterval(TimeInterval(bottom / Self.hourHeight * 3600)))
    }

    private func snapY(_ y: CGFloat) -> CGFloat {
        let step = Self.hourHeight * CGFloat(Self.snapMinutes / 60)
        return max(0, min(Self.hourHeight * 24, (y / step).rounded() * step))
    }

    private func ghostLabel(_ g: Ghost) -> String {
        let day = days[g.day].startOfDay(in: tz)
        let top = min(g.y0, g.y1), bottom = max(max(g.y0, g.y1), top + Self.hourHeight / 4)
        let s = day.addingTimeInterval(TimeInterval(top / Self.hourHeight * 3600))
        let e = day.addingTimeInterval(TimeInterval(bottom / Self.hourHeight * 3600))
        return WSFormat.range(s, e, in: tz)
    }
}

extension CalendarItem {
    var isDeadline: Bool {
        if case .deadline = source { return true }
        return false
    }
}

/// Static grid lines and column shading, drawn once with Canvas (cheap to redraw).
private struct GridBackground: View {
    let dayCount: Int
    let weekendOrToday: [Bool]

    var body: some View {
        Canvas { context, size in
            let columnWidth = size.width / CGFloat(dayCount)
            let shade = GraphicsContext.Shading.color(WSColor.weekend.opacity(0.6))
            let line = GraphicsContext.Shading.color(WSColor.hairline)
            for (i, shaded) in weekendOrToday.enumerated() where shaded {
                context.fill(Path(CGRect(x: CGFloat(i) * columnWidth, y: 0, width: columnWidth, height: size.height)), with: shade)
            }
            for hour in 0..<24 {
                let y = CGFloat(hour) * TimeGridView.hourHeight
                context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: line)
            }
            for i in 0..<dayCount {
                context.fill(Path(CGRect(x: CGFloat(i) * columnWidth, y: 0, width: 1, height: size.height)), with: line)
            }
        }
    }
}

/// A block on the grid: fill + 3pt accent bar (work blocks, events), or an outlined
/// flag marker (timed deadlines).
struct GridBlockView: View {
    let item: CalendarItem
    let style: BlockStyle
    let timeText: String
    let isPast: Bool
    let isSelected: Bool
    let compact: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(style.accent)
                .frame(width: WSRadius.accentBar)
                .opacity(item.isTentative || item.isDeadline ? 0 : 1)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 3) {
                    if item.isDeadline {
                        Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(style.accent)
                    } else if item.event == nil {
                        // Work blocks get a small task glyph so they read differently from meetings.
                        Image(systemName: "checklist").font(.system(size: 9)).foregroundStyle(style.accent)
                    }
                    if item.isDone {
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold))
                    }
                    Text(item.title)
                        .font(WSFont.blockTitle)
                        .strikethrough(item.isDone || item.event?.isDeclined == true)
                        .lineLimit(compact ? 1 : 2)
                    if compact && item.isDeadline {
                        Text(timeText).font(WSFont.blockMeta).foregroundStyle(WSColor.textSecondary).lineLimit(1)
                    }
                }
                .foregroundStyle(WSColor.textPrimary)
                if !compact {
                    Text(timeText)
                        .font(WSFont.blockMeta)
                        .foregroundStyle(WSColor.textSecondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, compact ? 1 : 4)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(item.isTentative || item.isDeadline ? WSColor.canvas.opacity(0.85) : style.fill)
        .overlay {
            RoundedRectangle(cornerRadius: WSRadius.block)
                .strokeBorder(
                    isSelected ? WSColor.textPrimary.opacity(0.85)
                        : (item.isTentative || item.isDeadline ? style.accent : .clear),
                    style: StrokeStyle(lineWidth: isSelected ? 1.5 : 1, dash: item.isTentative ? [3, 3] : [])
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: WSRadius.block))
        .opacity(item.event?.isDeclined == true ? 0.45 : (isPast ? 0.6 : 1))
        .contentShape(Rectangle())
        .help("\(item.title) · \(timeText)")
    }
}

#if os(macOS)
/// Listens for horizontal scroll-wheel / trackpad swipes while the pointer is over
/// the grid and reports horizontal deltas (Shift + vertical wheel counts too).
private struct HorizontalScrollCatcher: NSViewRepresentable {
    let isActive: Bool
    let onScroll: (CGFloat) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.isActive = isActive
        context.coordinator.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    func makeCoordinator() -> Coordinator { Coordinator(onScroll: onScroll) }

    @MainActor final class Coordinator {
        var isActive = false
        var onScroll: (CGFloat) -> Void
        private var monitor: Any?

        init(onScroll: @escaping (CGFloat) -> Void) { self.onScroll = onScroll }

        func install() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.isActive else { return event }
                var dx = event.scrollingDeltaX
                if event.modifierFlags.contains(.shift), dx == 0 { dx = event.scrollingDeltaY }
                // Mostly-horizontal gestures move days; vertical ones scroll hours as usual.
                guard abs(dx) > abs(event.scrollingDeltaY) || event.modifierFlags.contains(.shift) else { return event }
                if event.phase == .began { self.onScroll(0) }
                self.onScroll(event.hasPreciseScrollingDeltas ? dx : dx * 12)
                return nil
            }
        }

        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
    }
}
#endif
