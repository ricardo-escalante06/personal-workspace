import AppIntents
import SwiftUI
import WidgetKit
import WorkspaceKit
import WorkspaceUI

@main
struct WorkspaceWidgets: WidgetBundle {
    var body: some Widget {
        TodayWidget()
        CalendarWidget()
        NextUpWidget()
    }
}

// MARK: - Data

struct TodayEntry: TimelineEntry {
    struct Row: Identifiable {
        var task: TaskItem
        var color: Color
        var where_: String
        var time: String?
        var overdue: Bool
        var id: UUID { task.id }
    }
    var date: Date
    var rows: [Row]
    var leftToday: Int
    var overdueCount: Int
    /// The nearest starred thing (exam…) in the next two weeks.
    var starred: (title: String, days: Int, where_: String)?
    var nextUp: Row?
    /// The small widget's ring.
    var progress = TodayProgress(done: 0, total: 0)

    static let placeholder = TodayEntry(date: Date(), rows: [], leftToday: 0, overdueCount: 0, starred: nil, nextUp: nil,
                                        progress: .sample)
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry { .placeholder }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        completion(load())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let entry = load()
        // Refresh at the next hour (times like "in 20 min" and Today change), and at midnight.
        let cal = Calendar.current
        let nextHour = cal.nextDate(after: Date(), matching: DateComponents(minute: 0), matchingPolicy: .nextTime) ?? Date().addingTimeInterval(3600)
        completion(Timeline(entries: [entry], policy: .after(nextHour)))
    }

    private func load() -> TodayEntry {
        guard let store = try? SharedStore.open() else { return .placeholder }
        let now = Date()
        let today = LocalDate(now)
        let result = try? store.db.read { db -> (DashboardData, [UUID: Container]) in
            let data = try Dashboard.fetch(db, scope: nil, weekStart: Dashboard.weekStart(containing: today), now: now)
            let containers = Dictionary(uniqueKeysWithValues: try Container.live().fetchAll(db).map { ($0.id, $0) })
            return (data, containers)
        }
        guard let (data, containers) = result else { return .placeholder }
        func row(_ t: TaskItem, time: String?, overdue: Bool = false) -> TodayEntry.Row {
            let c = t.containerId.flatMap { containers[$0] }
            return .init(task: t, color: ContainerColor(named: c?.color ?? "grey").accent,
                         where_: c?.name ?? "Inbox", time: time, overdue: overdue)
        }
        let todayRows = data.today.filter { !$0.isChecked }.map { item in
            row(item.task, time: item.blocks.first.map { WSFormat.time($0.startsAt) } ?? item.task.dueTime.map(WSFormat.time))
        }
        let overdueRows = data.overdue.map { row($0, time: WSFormat.relativeDay($0.dueDate!, today: today), overdue: true) }
        let star = data.starred.first.map { t in
            (t.title, today.daysUntil(t.dueDate!), t.containerId.flatMap { containers[$0]?.name } ?? "Inbox")
        }
        // Next up: the next timed thing today, else the first open item.
        let next = data.today.filter { !$0.isChecked && ($0.sortTime ?? .distantPast) >= now }.first
            .map { row($0.task, time: $0.sortTime.map { WSFormat.time($0) }) } ?? todayRows.first
        return TodayEntry(date: now, rows: todayRows + overdueRows, leftToday: todayRows.count,
                          overdueCount: overdueRows.count, starred: star, nextUp: next, progress: TodayProgress(data))
    }
}

// MARK: - Today (home screen, interactive)

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "workspace.today", provider: TodayProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(Color(hex: 0x191919), for: .widget)
        }
        .configurationDisplayName("Today")
        .description("Small: how much of today is left. Larger: your Today list; tap a box to check it off.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

/// The Mac's Today notepad, scaled down: header band, ruled lines, red margin,
/// square checkboxes in the margin (tap to check off).
struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    private enum Paper {
        static let page = Color(hex: 0x23211D)
        static let header = Color(hex: 0x2D2A25)
        static let rule = Color(hex: 0x33363B)
        static let margin = Color(hex: 0x6E3236)
        static let ink = Color(hex: 0xEDEDED)
        static let faint = Color(hex: 0x9B9B9B)
    }

    private var lineHeight: CGFloat { family == .systemSmall ? 24 : 26 }
    private var marginX: CGFloat { family == .systemSmall ? 26 : 30 }
    private var limit: Int {
        switch family {
        case .systemSmall: 4
        case .systemMedium: 4
        default: 11
        }
    }

    var body: some View {
        if family == .systemSmall {
            TodayRingView(progress: entry.progress)
                .widgetURL(URL(string: "workspace://today"))
        } else {
            notepad
        }
    }

    private var notepad: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("Today").font(.system(size: 13, weight: .semibold, design: .rounded))
                    .fixedSize()
                if family != .systemSmall {
                    Text(entry.date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(Paper.faint)
                }
                Spacer()
                if let star = entry.starred, family != .systemSmall {
                    Label("\(star.title) \(star.days <= 0 ? "today" : "\(star.days)d")", systemImage: "star.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                        .foregroundStyle(star.days <= 3 ? WSColor.now : Paper.faint)
                        .lineLimit(1)
                } else {
                    Text(entry.leftToday == 0 && entry.overdueCount == 0 ? (family == .systemSmall ? "✓" : "All clear")
                         : family == .systemSmall ? "\(entry.leftToday)" : "\(entry.leftToday) left")
                        .font(.system(size: 10.5, design: .rounded)).foregroundStyle(Paper.faint)
                        .fixedSize()
                }
            }
            .padding(.leading, marginX + 6).padding(.trailing, 12)
            .frame(height: 30)
            .background(Paper.header)

            VStack(spacing: 0) {
                ForEach(entry.rows.prefix(limit)) { row in line(row) }
                if entry.rows.isEmpty {
                    blank("Nothing left today.")
                } else if entry.rows.count > limit {
                    blank("+\(entry.rows.count - limit) more")
                }
                Spacer(minLength: 0)
                    .frame(maxWidth: .infinity)
                    .background(RuledLines(spacing: lineHeight, color: Paper.rule))
            }
            .background(alignment: .leading) {
                Rectangle().fill(Paper.margin).frame(width: 1).padding(.leading, marginX)
            }
        }
        .foregroundStyle(Paper.ink)
        .widgetURL(URL(string: "workspace://today"))
    }

    private func line(_ row: TodayEntry.Row) -> some View {
        HStack(spacing: 0) {
            Button(intent: ToggleTaskIntent(task: row.task, done: true)) {
                RoundedRectangle(cornerRadius: 2.5)
                    .strokeBorder(row.color, lineWidth: 1.5)
                    .frame(width: 13, height: 13)
                    .frame(width: marginX, height: lineHeight)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(row.task.title).font(.system(size: 12.5, design: .rounded)).lineLimit(1)
                if family == .systemLarge {
                    Text(row.where_).font(.system(size: 10, design: .rounded)).foregroundStyle(Paper.faint).lineLimit(1)
                }
                Spacer(minLength: 2)
                if let time = row.time, family != .systemSmall {
                    Text(time).font(.system(size: 10.5, design: .rounded).monospacedDigit())
                        .foregroundStyle(row.overdue ? WSColor.now : Paper.faint).lineLimit(1)
                }
            }
            .padding(.leading, 6).padding(.trailing, 10)
        }
        .frame(height: lineHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.rule).frame(height: 1) }
    }

    private func blank(_ text: String) -> some View {
        HStack {
            Text(text).font(.system(size: 11, design: .rounded)).foregroundStyle(Paper.faint)
            Spacer()
        }
        .padding(.leading, marginX + 6)
        .frame(height: lineHeight)
        .overlay(alignment: .bottom) { Rectangle().fill(Paper.rule).frame(height: 1) }
    }
}

/// Faint rules to fill the rest of the page.
private struct RuledLines: View {
    let spacing: CGFloat
    let color: Color
    var body: some View {
        Canvas { ctx, size in
            var y = spacing
            while y < size.height {
                ctx.fill(Path(CGRect(x: 0, y: y - 1, width: size.width, height: 1)), with: .color(color))
                y += spacing
            }
        }
    }
}

// MARK: - Calendar

struct CalendarEntry: TimelineEntry {
    var date: Date
    var items: [WidgetCalendarItem]
}

struct CalendarProvider: TimelineProvider {
    func placeholder(in context: Context) -> CalendarEntry { CalendarEntry(date: Date(), items: []) }

    func getSnapshot(in context: Context, completion: @escaping (CalendarEntry) -> Void) {
        completion(CalendarEntry(date: Date(), items: WidgetCalendarFile.read()))
    }

    /// One entry now and one as each item ends, so finished ones drop off on time.
    func getTimeline(in context: Context, completion: @escaping (Timeline<CalendarEntry>) -> Void) {
        let items = WidgetCalendarFile.read()
        let now = Date()
        let changes = Set(items.filter { !$0.isAllDay && $0.end > now }.map(\.end)).sorted().prefix(30)
        let entries = [CalendarEntry(date: now, items: items)] + changes.map { CalendarEntry(date: $0, items: items) }
        let midnight = Calendar.current.startOfDay(for: now.addingTimeInterval(86_400))
        completion(Timeline(entries: entries, policy: .after(min(midnight, changes.last ?? midnight))))
    }
}

struct CalendarWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "workspace.calendar", provider: CalendarProvider()) { entry in
            CalendarWidgetView(entry: entry)
                .containerBackground(Color(hex: 0x191919), for: .widget)
        }
        .configurationDisplayName("Calendar")
        .description("Today's classes, meetings and work blocks, then tomorrow's.")
        .supportedFamilies([.systemMedium, .systemLarge, .accessoryRectangular])
    }
}

struct CalendarWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CalendarEntry

    private var upcoming: [WidgetCalendarItem] {
        entry.items.filter { $0.isAllDay ? Calendar.current.isDate($0.start, inSameDayAs: entry.date) || $0.start > entry.date : $0.end > entry.date }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }

    var body: some View {
        if family == .accessoryRectangular {
            let next = upcoming.first { !$0.isAllDay }
            VStack(alignment: .leading, spacing: 1) {
                if let next {
                    Text(next.title).font(.headline).lineLimit(1)
                    Text(timeText(next) + (next.location.map { " · \($0)" } ?? "")).lineLimit(1)
                } else {
                    Text("Nothing else today").font(.headline)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            let limit = family == .systemLarge ? 9 : 3
            let today = upcoming.filter { Calendar.current.isDate($0.start, inSameDayAs: entry.date) || $0.start < entry.date }
            let later = upcoming.filter { !today.contains($0) }
            let list = VStack(alignment: .leading, spacing: 5) {
                if today.isEmpty {
                    Text("Nothing else today").font(.system(size: 12)).foregroundStyle(Color(hex: 0x9B9B9B))
                }
                ForEach(today.prefix(limit)) { row($0) }
                if today.count < limit, !later.isEmpty {
                    Text("Tomorrow").font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Color(hex: 0x9B9B9B))
                        .padding(.top, 2)
                    ForEach(later.prefix(limit - today.count)) { row($0) }
                }
                Spacer(minLength: 0)
            }
            Group {
                if family == .systemMedium {
                    // Apple's layout: the date in a column on the left leaves room for
                    // three events on the right.
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(entry.date.formatted(.dateTime.weekday(.wide)).uppercased())
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(WSColor.now)
                            Text(entry.date.formatted(.dateTime.day()))
                                .font(.system(size: 38, weight: .semibold, design: .rounded).monospacedDigit())
                            Spacer(minLength: 0)
                            Text(entry.date.formatted(.dateTime.month(.wide)))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Color(hex: 0x9B9B9B))
                        }
                        .frame(width: 74, alignment: .leading)
                        list
                    }
                } else {
                    VStack(alignment: .leading, spacing: 5) {
                        // Red weekday over a bold date, like Apple's Calendar widget.
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 0) {
                                Text(entry.date.formatted(.dateTime.weekday(.wide)).uppercased())
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(WSColor.now)
                                Text(entry.date.formatted(.dateTime.month(.wide).day()))
                                    .font(.system(size: 17, weight: .bold))
                            }
                            Spacer()
                            Image(systemName: "calendar").foregroundStyle(Color(hex: 0x9B9B9B))
                        }
                        .padding(.bottom, 2)
                        list
                    }
                }
            }
            .foregroundStyle(Color(hex: 0xEDEDED))
            .widgetURL(URL(string: "workspace://calendar"))
        }
    }

    private func color(_ item: WidgetCalendarItem) -> Color {
        item.colorName.map { ContainerColor(named: $0).accent } ?? Color(hex: item.hex)
    }

    private func timeText(_ item: WidgetCalendarItem) -> String {
        if item.isAllDay { return "All day" }
        if item.kind == .deadline { return "Due " + WSFormat.time(item.start) }
        return WSFormat.range(item.start, item.end)
    }

    private func row(_ item: WidgetCalendarItem) -> some View {
        let isNow = !item.isAllDay && item.start <= entry.date && item.end > entry.date
        return HStack(spacing: 7) {
            RoundedRectangle(cornerRadius: 1.5).fill(color(item)).frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 4) {
                    if item.kind == .deadline { Image(systemName: "flag.fill").font(.system(size: 9)).foregroundStyle(color(item)) }
                    Text(item.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                        .strikethrough(item.isDone)
                }
                Text(timeText(item) + (item.location.map { " · \($0)" } ?? ""))
                    .font(.system(size: 10.5).monospacedDigit())
                    .foregroundStyle(isNow ? WSColor.now : Color(hex: 0x9B9B9B))
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            if isNow {
                Text("Now").font(.system(size: 9.5, weight: .bold)).foregroundStyle(WSColor.now)
            }
        }
    }
}

// MARK: - Lock Screen

struct NextUpWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "workspace.nextup", provider: TodayProvider()) { entry in
            NextUpView(entry: entry).containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Next Up")
        .description("Your next task, tasks left today, or the next exam.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct NextUpView: View {
    @Environment(\.widgetFamily) private var family
    let entry: TodayEntry

    var body: some View {
        switch family {
        case .accessoryCircular:
            Gauge(value: 0) {
                Image(systemName: "checklist")
            } currentValueLabel: {
                Text("\(entry.leftToday)")
            }
            .gaugeStyle(.accessoryCircularCapacity)
        case .accessoryInline:
            if let star = entry.starred, star.days <= 3 {
                Text("\(star.title) \(star.days <= 0 ? "today" : "in \(star.days)d")")
            } else {
                Text(entry.leftToday == 0 ? "All clear today" : "\(entry.leftToday) left today")
            }
        default:
            VStack(alignment: .leading, spacing: 1) {
                if let next = entry.nextUp {
                    Text(next.task.title).font(.headline).lineLimit(1)
                    Text([next.time, next.where_].compactMap { $0 }.joined(separator: " · ")).lineLimit(1)
                } else {
                    Text("All clear").font(.headline)
                }
                if let star = entry.starred {
                    Label("\(star.title) · \(star.days <= 0 ? "today" : "\(star.days)d")", systemImage: "star.fill")
                        .lineLimit(1)
                } else {
                    Text("\(entry.leftToday) left today")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
