import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// "Repeat" in the task panel: quick choices, what it means, and the next few dates.
struct RepeatSection: View {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    /// The repeating task (when `task` is one of its occurrences or the series itself).
    let series: TaskItem?
    @Binding var editing: Bool

    private var rule: RepeatRule? { series.flatMap(Occurrences.rule(of:)) }
    private var anchor: LocalDate { series.flatMap(Occurrences.anchor(of:)) ?? task.dueDate ?? LocalDate(Date()) }

    var body: some View {
        Section("Repeat") {
            Picker("Repeat", selection: Binding(
                get: { Preset.matching(rule, anchor: anchor) },
                set: { preset in
                    if preset == .custom { editing = true } else { model.setRepeat(task, preset.rule(anchor: anchor)) }
                }
            )) {
                ForEach(Preset.allCases, id: \.self) { p in
                    Text(p == .custom && Preset.matching(rule, anchor: anchor) == .custom ? (rule?.summary(anchor: anchor) ?? "Custom…") : p.title(anchor: anchor)).tag(p)
                }
            }
            if let rule {
                let upcoming = rule.dates(anchor: anchor, from: max(anchor, LocalDate(Date())), through: LocalDate(Date()).adding(days: 400)).prefix(4)
                LabeledContent("Next") {
                    Text(upcoming.map { $0.startOfDay(in: .current).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
                        .joined(separator: ", "))
                        .foregroundStyle(WSColor.textSecondary)
                }
                Button("Edit Repeat…") { editing = true }
                    .buttonStyle(.borderless)
            }
        }
    }

    enum Preset: Hashable, CaseIterable {
        case never, daily, weekdays, weekly, biweekly, monthly, yearly, custom

        func title(anchor: LocalDate) -> String {
            let day = anchor.startOfDay(in: .current).formatted(.dateTime.weekday(.wide))
            switch self {
            case .never: return "Never"
            case .daily: return "Every day"
            case .weekdays: return "Every weekday"
            case .weekly: return "Every week (\(day))"
            case .biweekly: return "Every 2 weeks (\(day))"
            case .monthly: return "Every month (the \(anchor.day)\(Self.suffix(anchor.day)))"
            case .yearly: return "Every year"
            case .custom: return "Custom…"
            }
        }

        func rule(anchor: LocalDate) -> RepeatRule? {
            switch self {
            case .never: nil
            case .daily: RepeatRule(.daily)
            case .weekdays: RepeatRule(.weekly, weekdays: [2, 3, 4, 5, 6])
            case .weekly: RepeatRule(.weekly, weekdays: [RepeatRule.weekday(anchor)])
            case .biweekly: RepeatRule(.weekly, interval: 2, weekdays: [RepeatRule.weekday(anchor)])
            case .monthly: RepeatRule(.monthly, monthly: .day(anchor.day))
            case .yearly: RepeatRule(.yearly)
            case .custom: nil
            }
        }

        static func matching(_ rule: RepeatRule?, anchor: LocalDate) -> Preset {
            guard let rule else { return .never }
            var normalized = rule
            if normalized.frequency == .weekly, normalized.weekdays.isEmpty { normalized.weekdays = [RepeatRule.weekday(anchor)] }
            if normalized.frequency == .monthly, normalized.monthly == nil { normalized.monthly = .day(anchor.day) }
            return allCases.first { $0 != .custom && $0 != .never && $0.rule(anchor: anchor) == normalized } ?? .custom
        }

        private static func suffix(_ n: Int) -> String {
            (11...13).contains(n % 100) ? "th" : (["th", "st", "nd", "rd"] + Array(repeating: "th", count: 6))[n % 10]
        }
    }
}

/// Full repeat options: every N days/weeks/months/years, which weekdays, "the 15th" vs
/// "the 3rd Tuesday", and when it ends, with a preview.
struct RepeatEditorSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let task: TaskItem
    @State private var rule: RepeatRule
    @State private var monthlyByWeekday = false
    @State private var endKind = 0      // 0 never, 1 on date, 2 after N
    @State private var endDate = Date()
    @State private var endCount = 10

    private let anchor: LocalDate
    private static let dayLetters = [(1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")]

    init(task: TaskItem) {
        self.task = task
        let anchor = Occurrences.anchor(of: task) ?? task.dueDate ?? LocalDate(Date())
        self.anchor = anchor
        let existing = Occurrences.rule(of: task) ?? RepeatRule(.weekly, weekdays: [RepeatRule.weekday(anchor)])
        _rule = State(initialValue: existing)
        if case .weekday = existing.monthly { _monthlyByWeekday = State(initialValue: true) }
        switch existing.end {
        case .never: break
        case .until(let d): _endKind = State(initialValue: 1); _endDate = State(initialValue: d.startOfDay(in: .current))
        case .count(let n): _endKind = State(initialValue: 2); _endCount = State(initialValue: n)
        }
    }

    private var effective: RepeatRule {
        var r = rule
        if r.frequency == .monthly {
            let ordinal = (anchor.day - 1) / 7 + 1
            r.monthly = monthlyByWeekday ? .weekday(ordinal: ordinal >= 5 ? -1 : ordinal, weekday: RepeatRule.weekday(anchor)) : .day(anchor.day)
        } else {
            r.monthly = nil
        }
        if r.frequency != .weekly { r.weekdays = [] }
        r.end = switch endKind {
        case 1: .until(LocalDate(endDate))
        case 2: .count(endCount)
        default: .never
        }
        return r
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Repeat “\(task.title)”").font(.system(size: 15, weight: .semibold)).padding(WSSpace.l)
            Form {
                HStack {
                    Stepper("Every \(rule.interval)", value: $rule.interval, in: 1...30)
                    Picker("", selection: $rule.frequency) {
                        Text(rule.interval == 1 ? "day" : "days").tag(RepeatRule.Frequency.daily)
                        Text(rule.interval == 1 ? "week" : "weeks").tag(RepeatRule.Frequency.weekly)
                        Text(rule.interval == 1 ? "month" : "months").tag(RepeatRule.Frequency.monthly)
                        Text(rule.interval == 1 ? "year" : "years").tag(RepeatRule.Frequency.yearly)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                if rule.frequency == .weekly {
                    LabeledContent("On") {
                        HStack(spacing: 3) {
                            ForEach(Self.dayLetters, id: \.0) { day, letter in
                                let on = rule.weekdays.contains(day)
                                Button {
                                    if on { rule.weekdays.remove(day) } else { rule.weekdays.insert(day) }
                                } label: {
                                    Text(letter).font(.system(size: 11, weight: .semibold))
                                        .frame(width: 22, height: 22)
                                        .foregroundStyle(on ? Color.white : WSColor.textSecondary)
                                        .background(Circle().fill(on ? WSColor.action : WSColor.hairline))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                if rule.frequency == .monthly {
                    Picker("On", selection: $monthlyByWeekday) {
                        Text("the \(anchor.day)\(suffix(anchor.day))").tag(false)
                        Text(weekdayOrdinalText).tag(true)
                    }
                }
                Picker("Ends", selection: $endKind) {
                    Text("Never").tag(0)
                    Text("On a date").tag(1)
                    Text("After a number of times").tag(2)
                }
                if endKind == 1 {
                    DatePicker("Last date", selection: $endDate, in: anchor.startOfDay(in: .current)..., displayedComponents: .date)
                }
                if endKind == 2 {
                    Stepper("\(endCount) times", value: $endCount, in: 1...500)
                }
                Section("Preview") {
                    let r = effective
                    Text(r.summary(anchor: anchor)).font(.system(size: 12, weight: .medium))
                    let dates = r.dates(anchor: anchor, from: anchor, through: anchor.adding(days: 800)).prefix(6)
                    Text(dates.map { $0.startOfDay(in: .current).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()) }
                        .joined(separator: " · ") + (dates.count == 6 ? " …" : ""))
                        .font(.system(size: 12)).foregroundStyle(WSColor.textSecondary)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                if task.isRecurring {
                    Button("Stop Repeating") { model.setRepeat(task, nil); dismiss() }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { model.setRepeat(task, effective); dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.frequency == .weekly && rule.weekdays.isEmpty)
            }
            .padding(WSSpace.l)
        }
        .frame(width: 440, height: 480)
    }

    private var weekdayOrdinalText: String {
        let ordinal = (anchor.day - 1) / 7 + 1
        let name = anchor.startOfDay(in: .current).formatted(.dateTime.weekday(.wide))
        return ordinal >= 5 ? "the last \(name)" : "the \(ordinal)\(suffix(ordinal)) \(name)"
    }

    private func suffix(_ n: Int) -> String {
        (11...13).contains(n % 100) ? "th" : (["th", "st", "nd", "rd"] + Array(repeating: "th", count: 6))[n % 10]
    }
}

extension AppModel {
    /// Repeat on/off/change for a task or any of its occurrences (one ⌘Z step).
    func setRepeat(_ task: TaskItem, _ rule: RepeatRule?) {
        let id = task.occurrenceOf ?? task.id
        undoable(rule == nil ? "Stop Repeating" : "Change Repeat", [id]) {
            try store.setRepeat(id, rule)
        }
        if task.isOccurrence { selectedTaskId = nil }
    }

    /// An edit to a repeating task for one occurrence, it and later ones, or all.
    func editRepeating(_ task: TaskItem, scope: EventEditScope, _ change: @escaping (inout TaskItem) -> Void) {
        guard let seriesId = task.occurrenceOf, let key = task.occurrenceKey else {
            editTask(task.id, change)
            return
        }
        undoableCreating("Edit Repeating Task", [seriesId]) {
            switch scope {
            case .one:
                try store.editTask(task.id, change)
                return []
            case .all:
                try store.editTask(seriesId, change)
                return []
            case .following:
                let new = try store.editFuture(seriesId, from: key, change)
                return new == seriesId ? [] : [new]
            }
        }
    }
}
