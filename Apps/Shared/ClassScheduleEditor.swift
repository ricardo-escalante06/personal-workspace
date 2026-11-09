import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// One recurring class meeting, e.g. "LEC · Mon Wed Fri · 10:00–11:00 · Dwinelle 155".
struct MeetingDraft: Codable, Identifiable, Hashable {
    var id = UUID()
    var type = "LEC"
    /// Calendar weekdays: 1 = Sunday … 7 = Saturday.
    var weekdays: Set<Int> = [2, 4, 6]
    var start = LocalTime(hour: 10, minute: 0)
    var end = LocalTime(hour: 11, minute: 0)
    var location = ""
    /// True once its recurring event exists in the calendar (so saving again won't duplicate it).
    var created = false
}

/// Term dates + meetings for a class. Saving creates the meetings as weekly recurring
/// events (until the term ends) titled "<code> <type>", which auto-link to the class.
struct ClassSetup: Equatable {
    var code = ""
    var termStart = Date()
    var termEnd = Calendar.current.date(byAdding: .weekOfYear, value: 15, to: Date()) ?? Date()
    var meetings: [MeetingDraft] = []
    var calendarId: String?

    static func meetings(from settings: JSONValue) -> [MeetingDraft] {
        guard let value = settings["meetings"],
              let data = try? JSONEncoder().encode(value),
              let list = try? JSONDecoder().decode([MeetingDraft].self, from: data)
        else { return [] }
        return list
    }

    static func settings(_ base: JSONValue, with meetings: [MeetingDraft]) -> JSONValue {
        var object: [String: JSONValue] = [:]
        if case .object(let o) = base { object = o }
        if let data = try? JSONEncoder().encode(meetings),
           let value = try? JSONDecoder().decode(JSONValue.self, from: data) {
            object["meetings"] = value
        }
        return .object(object)
    }
}

struct ClassScheduleEditor: View {
    @Environment(AppModel.self) private var model
    @Binding var setup: ClassSetup

    private static let dayLetters = [(1, "S"), (2, "M"), (3, "T"), (4, "W"), (5, "T"), (6, "F"), (7, "S")]

    var body: some View {
        VStack(alignment: .leading, spacing: WSSpace.m) {
            Text("Term & meetings")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(WSColor.textSecondary)

            HStack(spacing: WSSpace.m) {
                TextField("Course code (e.g. CS61A)", text: $setup.code)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 170)
                DatePicker("", selection: $setup.termStart, displayedComponents: .date).labelsHidden()
                Text("to").foregroundStyle(WSColor.textTertiary)
                DatePicker("", selection: $setup.termEnd, in: setup.termStart..., displayedComponents: .date).labelsHidden()
            }
            Text("Calendar events whose titles start with the course code show up in this class.")
                .font(.system(size: 11))
                .foregroundStyle(WSColor.textTertiary)

            ForEach($setup.meetings) { $meeting in
                meetingRow($meeting)
            }

            HStack {
                Button {
                    var next = MeetingDraft()
                    if setup.meetings.contains(where: { $0.type == "LEC" }) { next.type = "DIS"; next.weekdays = [3] }
                    setup.meetings.append(next)
                } label: {
                    Label("Add meeting", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                Spacer()
                if setup.meetings.contains(where: { !$0.created }) {
                    calendarPicker
                }
            }
        }
    }

    private func meetingRow(_ meeting: Binding<MeetingDraft>) -> some View {
        let m = meeting.wrappedValue
        return VStack(alignment: .leading, spacing: WSSpace.xs) {
            HStack(spacing: WSSpace.s) {
                TextField("LEC", text: meeting.type)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 56)
                    .disabled(m.created)
                HStack(spacing: 2) {
                    ForEach(Self.dayLetters, id: \.0) { day, letter in
                        let on = m.weekdays.contains(day)
                        Button {
                            if on { meeting.wrappedValue.weekdays.remove(day) } else { meeting.wrappedValue.weekdays.insert(day) }
                        } label: {
                            Text(letter)
                                .font(.system(size: 11, weight: .semibold))
                                .frame(width: 20, height: 20)
                                .foregroundStyle(on ? Color.white : WSColor.textSecondary)
                                .background(Circle().fill(on ? WSColor.action : WSColor.hairline))
                        }
                        .buttonStyle(.plain)
                        .disabled(m.created)
                    }
                }
                timePicker(meeting.start).disabled(m.created)
                Text("–").foregroundStyle(WSColor.textTertiary)
                timePicker(meeting.end).disabled(m.created)
                Spacer(minLength: 0)
                if m.created {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(ContainerColor.green.accent)
                        .help("Already in your calendar. Edit or delete it there.")
                } else {
                    Button { setup.meetings.removeAll { $0.id == m.id } } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .foregroundStyle(WSColor.textTertiary)
                }
            }
            TextField("Location (optional)", text: meeting.location)
                .textFieldStyle(.roundedBorder)
                .disabled(m.created)
        }
        .padding(WSSpace.s)
        .background(RoundedRectangle(cornerRadius: WSRadius.block).fill(WSColor.canvas))
    }

    private func timePicker(_ time: Binding<LocalTime>) -> some View {
        DatePicker("", selection: Binding(
            get: { LocalDate(Date()).startOfDay(in: .current).addingTimeInterval(TimeInterval(time.wrappedValue.secondsSinceMidnight)) },
            set: { d in
                let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                time.wrappedValue = LocalTime(hour: c.hour ?? 0, minute: c.minute ?? 0)
            }
        ), displayedComponents: .hourAndMinute)
        .labelsHidden()
        .frame(width: 80)
    }

    @ViewBuilder private var calendarPicker: some View {
        if model.calendarSource.hasAnyCalendars {
            Picker("Add to", selection: $setup.calendarId) {
                ForEach(model.calendarSource.calendars.filter(\.isWritable)) { cal in
                    Text("\(cal.title) (\(cal.account))").tag(String?.some(cal.id))
                }
            }
            .fixedSize()
        } else {
            Text("Allow calendar access to add meetings")
                .font(.system(size: 11))
                .foregroundStyle(WSColor.textTertiary)
        }
    }
}

extension AppModel {
    /// Saves term dates and creates calendar events for any new meetings.
    func applyClassSetup(_ setup: ClassSetup, to containerId: UUID) throws {
        let code = setup.code.trimmingCharacters(in: .whitespaces)
        let tz = TimeZone.current
        // 1. Term (+ the title pattern that links calendar events to this class).
        try store.db.write { db in
            var term = try ClassTerm.live().filter(Column("container_id") == containerId).fetchOne(db)
                ?? ClassTerm(containerId: containerId)
            term.termStart = LocalDate(setup.termStart, in: tz)
            term.termEnd = LocalDate(setup.termEnd, in: tz)
            term.courseCode = code.isEmpty ? nil : code
            term.eventTitlePattern = code.isEmpty ? nil : code
            try WorkspaceStore.save(&term, in: db)
        }

        // 2. Remember the meetings now; mark each as created once its event exists.
        try update(containerId) { c in c.settings = ClassSetup.settings(c.settings, with: setup.meetings) }

        // 3. New meetings → weekly recurring events for the term (async: Google is a network call).
        let pending = setup.meetings.filter { !$0.created && !$0.weekdays.isEmpty }
        guard !code.isEmpty, !pending.isEmpty else { return }
        let termStartDay = LocalDate(setup.termStart, in: tz)
        let until = LocalDate(setup.termEnd, in: tz).adding(days: 1).startOfDay(in: tz)
        let calendarId = setup.calendarId
        runCalendar { [weak self] source in
            var weekdayCalendar = Calendar(identifier: .gregorian)
            weekdayCalendar.timeZone = tz
            for m in pending {
                guard let firstDay = (0..<7).map({ termStartDay.adding(days: $0) }).first(where: {
                    m.weekdays.contains(weekdayCalendar.component(.weekday, from: $0.startOfDay(in: tz)))
                }) else { continue }
                let start = firstDay.startOfDay(in: tz).addingTimeInterval(TimeInterval(m.start.secondsSinceMidnight))
                let duration = TimeInterval(max(m.end.secondsSinceMidnight - m.start.secondsSinceMidnight, 15 * 60))
                let type = m.type.trimmingCharacters(in: .whitespaces)
                try await source.createWeekly(
                    title: type.isEmpty ? code : "\(code) \(type)",
                    firstStart: start, duration: duration, weekdays: Array(m.weekdays),
                    until: until, location: m.location.isEmpty ? nil : m.location, calendarId: calendarId
                )
                try self?.markMeetingCreated(m.id, in: containerId)
            }
        }
    }

    private func markMeetingCreated(_ meetingId: UUID, in containerId: UUID) throws {
        try update(containerId) { c in
            var meetings = ClassSetup.meetings(from: c.settings)
            if let i = meetings.firstIndex(where: { $0.id == meetingId }) { meetings[i].created = true }
            c.settings = ClassSetup.settings(c.settings, with: meetings)
        }
    }

    func loadClassSetup(for container: Container) -> ClassSetup {
        var setup = ClassSetup()
        setup.code = container.name
        setup.calendarId = calendarSource.defaultCalendarId
        if let term = try? store.db.read({ try ClassTerm.live().filter(Column("container_id") == container.id).fetchOne($0) }) {
            if let s = term.termStart { setup.termStart = s.startOfDay(in: .current) }
            if let e = term.termEnd { setup.termEnd = e.startOfDay(in: .current) }
            if let code = term.courseCode { setup.code = code }
        }
        setup.meetings = ClassSetup.meetings(from: container.settings)
        return setup
    }

    private func update(_ containerId: UUID, _ change: (inout Container) -> Void) throws {
        try store.update(Container.self, containerId, change)
    }
}
