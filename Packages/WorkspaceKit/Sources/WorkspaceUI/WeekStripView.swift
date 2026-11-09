import SwiftUI
import WorkspaceKit

/// The dashboard week strip (DESIGN.md §3.4, modeled on the Notion "General Tasks"
/// week view): seven day cells with task chips, ‹ Today › navigation and an
/// "Open in Calendar" button.
public struct WeekStripView: View {
    public struct Actions {
        public var previousWeek: () -> Void
        public var nextWeek: () -> Void
        public var thisWeek: () -> Void
        public var openCalendar: (() -> Void)?
        public var selectTask: (UUID) -> Void
        /// Double-click a chip: open its details.
        public var openTask: (UUID) -> Void
        public var toggleTask: (TaskItem) -> Void
        /// Click on empty space in a day: quick-add due that day.
        public var addOnDay: (LocalDate) -> Void
        /// A chip dropped on another day. Deadlines move their due date; blocks move their day.
        public var moveChip: (_ chipId: String, _ to: LocalDate) -> Void

        public init(previousWeek: @escaping () -> Void, nextWeek: @escaping () -> Void, thisWeek: @escaping () -> Void,
                    openCalendar: (() -> Void)? = nil, selectTask: @escaping (UUID) -> Void,
                    openTask: @escaping (UUID) -> Void,
                    toggleTask: @escaping (TaskItem) -> Void, addOnDay: @escaping (LocalDate) -> Void,
                    moveChip: @escaping (String, LocalDate) -> Void) {
            self.previousWeek = previousWeek; self.nextWeek = nextWeek; self.thisWeek = thisWeek
            self.openCalendar = openCalendar; self.selectTask = selectTask; self.openTask = openTask
            self.toggleTask = toggleTask
            self.addOnDay = addOnDay; self.moveChip = moveChip
        }
    }

    let days: [WeekDay]
    let today: LocalDate
    let selectedTaskIds: Set<UUID>
    let colorFor: (TaskItem) -> ContainerColor
    let tagFor: (TaskItem) -> TagStyle?
    let actions: Actions
    let maxChips: Int

    @State private var dropTarget: LocalDate?

    public init(days: [WeekDay], today: LocalDate, selectedTaskIds: Set<UUID>, maxChips: Int = 5,
                colorFor: @escaping (TaskItem) -> ContainerColor,
                tagFor: @escaping (TaskItem) -> TagStyle? = { _ in nil }, actions: Actions) {
        self.days = days
        self.today = today
        self.selectedTaskIds = selectedTaskIds
        self.maxChips = maxChips
        self.colorFor = colorFor
        self.tagFor = tagFor
        self.actions = actions
    }

    /// Below this width per day, chips become unreadable; the strip scrolls instead.
    static let minDayWidth: CGFloat = 112

    public var body: some View {
        VStack(spacing: WSSpace.s) {
            header
            ViewThatFits(in: .horizontal) {
                grid
                    .frame(minWidth: Self.minDayWidth * 7)
                ScrollView(.horizontal) {
                    grid
                        .frame(width: Self.minDayWidth * 7)
                        .padding(.bottom, WSSpace.s)
                }
            }
        }
    }

    private var grid: some View {
        VStack(spacing: WSSpace.s) {
            HStack(spacing: 0) {
                ForEach(days) { day in
                    Text(WSFormat.weekdayShort(day.date))
                        .font(.system(size: 12))
                        .foregroundStyle(WSColor.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            HStack(spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.element.id) { index, day in
                    dayCell(day, isWeekend: index == 0 || index == 6)
                    if index < days.count - 1 {
                        Rectangle().fill(WSColor.hairline).frame(width: 1)
                    }
                }
            }
            .frame(minHeight: 150)
            .overlay(RoundedRectangle(cornerRadius: WSRadius.block).strokeBorder(WSColor.hairline))
            .clipShape(RoundedRectangle(cornerRadius: WSRadius.block))
        }
    }

    private var header: some View {
        HStack(spacing: WSSpace.m) {
            Text(days.first.map { WSFormat.monthYear($0.date) } ?? "")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(WSColor.textPrimary)
            Spacer()
            if let openCalendar = actions.openCalendar {
                Button(action: openCalendar) {
                    Label("Open in Calendar", systemImage: "calendar")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(WSColor.textSecondary)
                .padding(.horizontal, WSSpace.s).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(WSColor.hairline))
            }
            HStack(spacing: WSSpace.xs) {
                navButton("chevron.left", help: "Previous week", action: actions.previousWeek)
                Button("Today", action: actions.thisWeek)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(WSColor.textPrimary)
                navButton("chevron.right", help: "Next week", action: actions.nextWeek)
            }
        }
    }

    private func navButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                .frame(width: 18, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(WSColor.textSecondary)
        .help(help)
    }

    private func dayCell(_ day: WeekDay, isWeekend: Bool) -> some View {
        let isToday = day.date == today
        let visible = day.chips.prefix(maxChips)
        let hidden = day.chips.count - visible.count
        return VStack(alignment: .leading, spacing: 3) {
            HStack {
                Spacer()
                Text("\(day.date.day)")
                    .font(.system(size: 12, weight: isToday ? .semibold : .regular).monospacedDigit())
                    .foregroundStyle(isToday ? Color.white : WSColor.textSecondary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isToday ? WSColor.now : .clear))
            }
            ForEach(visible) { chip in
                WeekChipView(chip: chip, color: colorFor(chip.task), tag: tagFor(chip.task), isSelected: selectedTaskIds.contains(chip.task.id))
                    .onTapGesture(count: 2) { actions.openTask(chip.task.id) }
                    .simultaneousGesture(TapGesture().onEnded { actions.selectTask(chip.task.id) })
                    .contextMenu {
                        Button(chip.isDone ? "Mark Not Done" : "Mark Done") { actions.toggleTask(chip.task) }
                    }
                    .draggable(chip.id)
            }
            if hidden > 0 {
                Text("+\(hidden) more")
                    .font(.system(size: 11))
                    .foregroundStyle(WSColor.textTertiary)
                    .padding(.leading, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(5)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(dropTarget == day.date ? WSColor.hairline : (isWeekend || isToday ? WSColor.weekend : WSColor.canvas))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { actions.addOnDay(day.date) }
        .dropDestination(for: String.self) { ids, _ in
            guard let id = ids.first else { return false }
            actions.moveChip(id, day.date)
            return true
        } isTargeted: { targeted in
            dropTarget = targeted ? day.date : (dropTarget == day.date ? nil : dropTarget)
        }
        .help("Double-click to add a task due this day")
    }
}

/// One chip in a week cell: color bar, title, and a flag (deadline) or time (work block).
public struct WeekChipView: View {
    let chip: WeekChip
    let color: ContainerColor
    let tag: TagStyle?
    let isSelected: Bool

    public init(chip: WeekChip, color: ContainerColor, tag: TagStyle? = nil, isSelected: Bool) {
        self.chip = chip
        self.color = color
        self.tag = tag
        self.isSelected = isSelected
    }

    public var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 1)
                .fill(color.accent)
                .frame(width: 2.5)
            VStack(alignment: .leading, spacing: 0) {
                Text(chip.task.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .strikethrough(chip.isDone)
                    .foregroundStyle(chip.isDone ? WSColor.textTertiary : WSColor.textPrimary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    if let tag { TagPill(tag, compact: true) }
                    meta
                        .font(.system(size: 10.5).monospacedDigit())
                        .foregroundStyle(WSColor.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 3)
        .padding(.trailing, 4)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(isScheduled ? color.fill : (isSelected ? WSColor.hairline : .clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? color.accent : .clear, lineWidth: 1)
        )
        .contentShape(Rectangle())
        // The accent bar is a flexible shape; without this, chips stretch to fill the day.
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var isScheduled: Bool {
        if case .scheduled = chip.kind { return true }
        return false
    }

    @ViewBuilder private var meta: some View {
        switch chip.kind {
        case .due(let time):
            Label(time.map(WSFormat.time) ?? "Due", systemImage: chip.task.isMilestone ? "diamond.fill" : "flag.fill")
                .labelStyle(.titleAndIcon)
                .imageScale(.small)
        case .scheduled(let block):
            Text(WSFormat.range(block.startsAt, block.endsAt))
        }
    }
}
