import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

struct SeriesEditorRequest: Identifiable {
    let id = UUID()
    var classId: UUID
    /// nil = new series.
    var rule: AssignmentRule?
}

/// "HW 1–12, due Fridays 11:59 PM": one sheet makes (or later re-shapes) a whole
/// run of assignments. Editing keeps anything you changed by hand on a single task.
struct AssignmentSeriesSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SeriesEditorRequest

    @State private var rule: AssignmentRule
    @State private var hasTime = true
    @State private var confirmDelete = false

    init(request: SeriesEditorRequest) {
        self.request = request
        if let existing = request.rule {
            _rule = State(initialValue: existing)
            _hasTime = State(initialValue: existing.dueTime != nil)
        } else {
            // Next Friday, 11:59 PM, weekly, 12 of them.
            let today = LocalDate(Date())
            var next = today
            for i in 1...7 {
                let d = today.adding(days: i)
                if Calendar.current.component(.weekday, from: d.startOfDay(in: .current)) == 6 { next = d; break }
            }
            _rule = State(initialValue: AssignmentRule(
                containerId: request.classId, titlePattern: "HW {n}", count: 12,
                firstDueDate: next, dueTime: LocalTime(hour: 23, minute: 59)
            ))
        }
    }

    private var isNew: Bool { request.rule == nil }
    private var className: String { model.container(request.classId)?.name ?? "class" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(isNew ? "New assignment series" : "Edit series")
                .font(.system(size: 15, weight: .semibold))
                .padding([.horizontal, .top], WSSpace.l)
            Text("in \(className)")
                .font(.system(size: 12)).foregroundStyle(WSColor.textSecondary)
                .padding(.horizontal, WSSpace.l)

            HStack(alignment: .top, spacing: 0) {
                form.frame(width: 300)
                Divider()
                preview.frame(minWidth: 240)
            }
            .frame(height: 380)

            Divider()
            HStack {
                if !isNew {
                    Button("Delete Series…", role: .destructive) { confirmDelete = true }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(isNew ? "Create \(rule.items().count) Tasks" : "Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(rule.titlePattern.trimmingCharacters(in: .whitespaces).isEmpty || rule.items().isEmpty)
            }
            .padding(WSSpace.l)
        }
        .frame(width: 600)
        .confirmationDialog("Delete this series?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Series and Open Tasks", role: .destructive) { delete(removeTasks: true) }
            Button("Keep Tasks, Delete Series") { delete(removeTasks: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Finished tasks are always kept.")
        }
    }

    private var form: some View {
        Form {
            TextField("Name", text: $rule.titlePattern, prompt: Text("HW {n}"))
            Text("{n} becomes the number: “Lab {n}” → Lab 1, Lab 2…")
                .font(.caption).foregroundStyle(WSColor.textTertiary)
            Picker("Tag", selection: $rule.categoryId) {
                Text("None").tag(UUID?.none)
                ForEach(model.categories) { c in Text(c.name).tag(UUID?.some(c.id)) }
            }
            Stepper("How many: \(rule.count ?? 0)", value: Binding(get: { rule.count ?? 0 }, set: { rule.count = $0 }), in: 1...60)
            Stepper("Start at: \(rule.startNumber)", value: $rule.startNumber, in: 0...99)
            DatePicker("First due", selection: Binding(
                get: { (rule.firstDueDate ?? LocalDate(Date())).startOfDay(in: .current) },
                set: { rule.firstDueDate = LocalDate($0) }
            ), displayedComponents: .date)
            Toggle("Due time", isOn: $hasTime)
                .onChange(of: hasTime) { _, on in rule.dueTime = on ? (rule.dueTime ?? LocalTime(hour: 23, minute: 59)) : nil }
            if hasTime, let time = rule.dueTime {
                DatePicker("Time", selection: Binding(
                    get: { LocalDate(Date()).at(time) },
                    set: { d in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        rule.dueTime = LocalTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
                    }
                ), displayedComponents: .hourAndMinute)
            }
            Picker("Repeats", selection: Binding(get: { rule.everyWeeks }, set: { rule.everyWeeks = $0 })) {
                Text("Every week").tag(1)
                Text("Every 2 weeks").tag(2)
                Text("Every 3 weeks").tag(3)
            }
        }
        .formStyle(.grouped)
    }

    private var preview: some View {
        let items = rule.items()
        let skipped = rule.skippedDates
        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel("Preview", trailing: "\(items.count)")
                    .padding(.bottom, WSSpace.xs)
                ForEach(items, id: \.index) { item in
                    HStack {
                        Text(item.title).font(.system(size: 12.5, weight: .medium))
                        Spacer()
                        Text(item.dueDate.startOfDay(in: .current).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                            .font(.system(size: 12).monospacedDigit())
                            .foregroundStyle(WSColor.textSecondary)
                        Button {
                            rule.skippedDates = skipped + [item.dueDate]
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.plain)
                            .foregroundStyle(WSColor.textTertiary)
                            .help("Skip this week (e.g. a break) — the rest shift later")
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
                if !skipped.isEmpty {
                    SectionLabel("Skipped weeks").padding(.top, WSSpace.m).padding(.bottom, WSSpace.xs)
                    ForEach(skipped, id: \.self) { d in
                        HStack {
                            Text(d.startOfDay(in: .current).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                                .font(.system(size: 12)).foregroundStyle(WSColor.textSecondary)
                            Spacer()
                            Button("Restore") { rule.skippedDates = skipped.filter { $0 != d } }
                                .buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(WSColor.action)
                        }
                        .padding(.vertical, 3)
                    }
                }
            }
            .padding(WSSpace.l)
        }
    }

    private func save() {
        if !hasTime { rule.dueTime = nil }
        model.perform { try model.store.saveAssignmentSeries(rule) }
        dismiss()
    }

    private func delete(removeTasks: Bool) {
        model.perform { try model.store.deleteAssignmentSeries(rule.id, removeOpenTasks: removeTasks) }
        dismiss()
    }
}

/// On a class page: its series ("HW 1–12 · Fri 11:59 PM") with Edit, plus "New series".
struct SeriesStrip: View {
    @Environment(AppModel.self) private var model
    let classId: UUID
    @State private var rules: [AssignmentRule] = []

    var body: some View {
        HStack(spacing: WSSpace.xs) {
            ForEach(rules) { r in
                Button { model.seriesEditor = SeriesEditorRequest(classId: classId, rule: r) } label: {
                    HStack(spacing: 5) {
                        if let tag = model.tagStyle(r.categoryId) { Circle().fill(tag.color.accent).frame(width: 7, height: 7) }
                        Text(summary(r))
                        Image(systemName: "pencil").imageScale(.small).foregroundStyle(WSColor.textTertiary)
                    }
                    .font(.system(size: 12))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(WSColor.hairline))
                }
                .buttonStyle(.plain)
                .foregroundStyle(WSColor.textSecondary)
                .help("Edit this series")
            }
            Button { model.seriesEditor = SeriesEditorRequest(classId: classId) } label: {
                Label("Assignment series", systemImage: "plus")
                    .font(.system(size: 12))
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .overlay(Capsule().strokeBorder(WSColor.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
            }
            .buttonStyle(.plain)
            .foregroundStyle(WSColor.textSecondary)
            .help("Create HW 1–12 (or labs, quizzes…) in one go")
        }
        .task(id: classId) {
            let id = classId
            let observation = ValueObservation.tracking { db in
                try AssignmentRule.live().filter(Column("container_id") == id).order(Column("created_at")).fetchAll(db)
            }
            do { for try await value in observation.values(in: model.store.db) { rules = value } } catch {}
        }
    }

    private func summary(_ r: AssignmentRule) -> String {
        let items = r.items()
        guard let first = items.first, let last = items.last else { return r.title(number: r.startNumber) }
        let range = items.count == 1 ? first.title : "\(first.title)–\(last.title.split(separator: " ").last ?? "")"
        let day = first.dueDate.startOfDay(in: .current).formatted(.dateTime.weekday(.abbreviated))
        let every = r.everyWeeks == 1 ? day : "every \(r.everyWeeks) wks \(day)"
        return "\(range) · \(every)" + (r.dueTime.map { " " + WSFormat.time($0) } ?? "")
    }
}
