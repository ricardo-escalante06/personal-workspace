import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// Month view: 6×7 grid with compact chips. Click a day to open it in Day view.
struct MonthGridView: View {
    let days: [LocalDate]
    let month: Int
    let items: [CalendarItem]
    let colorFor: (CalendarItem) -> BlockStyle
    var tagFor: (CalendarItem) -> TagStyle? = { _ in nil }
    let onPickDay: (LocalDate) -> Void
    let onSelect: (CalendarItem) -> Void

    private var tz: TimeZone { .current }
    private var today: LocalDate { LocalDate(Date()) }
    private let maxChips = 4

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days.prefix(7), id: \.self) { d in
                    Text(WSFormat.weekdayShort(d))
                        .font(.system(size: 12))
                        .foregroundStyle(WSColor.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, WSSpace.s)
            Rectangle().fill(WSColor.hairline).frame(height: 1)
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { week in
                    HStack(spacing: 0) {
                        ForEach(0..<7, id: \.self) { col in
                            cell(days[week * 7 + col])
                        }
                    }
                    .frame(maxHeight: .infinity)
                    Rectangle().fill(WSColor.hairline).frame(height: 1)
                }
            }
        }
    }

    private func cell(_ day: LocalDate) -> some View {
        let dayStart = day.startOfDay(in: tz), dayEnd = day.adding(days: 1).startOfDay(in: tz)
        let chips = items
            .filter { $0.start < dayEnd && $0.end > dayStart }
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return a.isAllDay }
                return a.start < b.start
            }
        let inMonth = day.month == month
        let isToday = day == today

        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Text("\(day.day)")
                    .font(.system(size: 12, weight: isToday ? .bold : .regular).monospacedDigit())
                    .foregroundStyle(isToday ? .white : (inMonth ? WSColor.textSecondary : WSColor.textTertiary))
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isToday ? WSColor.now : .clear))
            }
            ForEach(chips.prefix(maxChips)) { item in
                chip(item)
            }
            if chips.count > maxChips {
                Text("+\(chips.count - maxChips) more")
                    .font(.system(size: 10.5))
                    .foregroundStyle(WSColor.textTertiary)
                    .padding(.leading, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(inMonth ? Color.clear : WSColor.weekend.opacity(0.5))
        .overlay(alignment: .leading) { Rectangle().fill(WSColor.hairline).frame(width: 1) }
        .contentShape(Rectangle())
        .onTapGesture { onPickDay(day) }
    }

    private func chip(_ item: CalendarItem) -> some View {
        let style = colorFor(item)
        let isDeadline: Bool = { if case .deadline = item.source { return true } else { return false } }()
        return HStack(spacing: 4) {
            if isDeadline {
                Image(systemName: "flag.fill").font(.system(size: 7)).foregroundStyle(style.accent)
            } else if !item.isAllDay {
                Circle().fill(style.accent).frame(width: 5, height: 5)
                Text(WSFormat.time(item.start, in: tz))
                    .foregroundStyle(WSColor.textTertiary)
            }
            Text(item.title).lineLimit(1).strikethrough(item.isDone)
            if let tag = tagFor(item) { TagPill(tag, compact: true) }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10.5, weight: .medium))
        .foregroundStyle(item.isDone ? WSColor.textTertiary : WSColor.textPrimary)
        .padding(.horizontal, 3).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(item.isAllDay && !isDeadline ? style.fill : .clear))
        .contentShape(Rectangle())
        .onTapGesture { onSelect(item) }
    }
}

