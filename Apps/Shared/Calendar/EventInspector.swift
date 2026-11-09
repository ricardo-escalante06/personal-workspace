import GRDB
import SwiftUI
import WorkspaceKit
import WorkspaceUI

/// Event details in the right-hand panel, modeled on Notion Calendar's event view:
/// time + duration, guests and their replies, your RSVP, video link, location,
/// description, calendar, busy/free, reminders, and "Belongs to" (class/project).
struct EventInspector: View {
    @Environment(AppModel.self) private var model
    let event: ExternalEvent

    @State private var mappedContainer: UUID?
    @State private var start = Date()
    @State private var end = Date()
    @State private var showAllGuests = false
    @State private var myResponse: EventAttendee.Response?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                titleSection
                divider
                timeSection
                if !event.attendees.isEmpty || event.organizer != nil {
                    divider
                    guestsSection
                }
                if event.conferenceURL != nil || (event.location?.isEmpty == false) {
                    divider
                    whereSection
                }
                if let notes = event.notes, !notes.isEmpty {
                    divider
                    section {
                        Text(Self.plainText(notes))
                            .font(.system(size: 12.5))
                            .foregroundStyle(WSColor.textSecondary)
                            .textSelection(.enabled)
                    }
                }
                divider
                calendarSection
                divider
                belongsSection
                if event.isWritable || event.provider == .google {
                    divider
                    actionsSection
                }
            }
        }
        .background(WSColor.raised)
        .task(id: event.key) {
            start = event.start
            end = event.end
            myResponse = event.selfResponse
            mappedContainer = try? await model.store.db.read { try EventMapper.load($0).containerId(for: event) }
        }
    }

    // MARK: Sections

    private var titleSection: some View {
        section {
            HStack(alignment: .top, spacing: WSSpace.s) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: event.eventColor ?? model.calendarSource.color(forCalendar: event.calendarId, fallback: event.calendarColor)))
                    .frame(width: 4, height: 22)
                Text(event.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(event.isDeclined ? WSColor.textTertiary : WSColor.textPrimary)
                    .strikethrough(event.isDeclined)
                    .textSelection(.enabled)
            }
        }
    }

    private var timeSection: some View {
        section {
            row(icon: "clock") {
                VStack(alignment: .leading, spacing: 6) {
                    if event.isWritable && !event.isAllDay {
                        HStack(spacing: 6) {
                            DatePicker("", selection: $start, displayedComponents: .hourAndMinute).labelsHidden()
                            Image(systemName: "arrow.right").foregroundStyle(WSColor.textTertiary).imageScale(.small)
                            DatePicker("", selection: $end, in: start..., displayedComponents: .hourAndMinute).labelsHidden()
                            Text(duration).foregroundStyle(WSColor.textTertiary)
                        }
                        DatePicker("", selection: $start, displayedComponents: .date).labelsHidden().fixedSize()
                        if start != event.start || end != event.end {
                            Button("Save change") { model.updateEvent(event, start: start, end: end) }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                        }
                    } else {
                        HStack(spacing: 6) {
                            Text(event.isAllDay ? "All day" : WSFormat.time(event.start))
                            if !event.isAllDay {
                                Image(systemName: "arrow.right").foregroundStyle(WSColor.textTertiary).imageScale(.small)
                                Text(WSFormat.time(event.end))
                                Text(duration).foregroundStyle(WSColor.textTertiary)
                            }
                        }
                        Text(event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                    }
                    if event.isRecurring {
                        Label("Repeats", systemImage: "repeat")
                            .font(.system(size: 11.5)).foregroundStyle(WSColor.textTertiary)
                    }
                }
            }
        }
    }

    private var guestsSection: some View {
        let guests = event.attendees.sorted { a, b in
            if a.isOrganizer != b.isOrganizer { return a.isOrganizer }
            if a.isSelf != b.isSelf { return a.isSelf }
            return a.displayName < b.displayName
        }
        let shown = showAllGuests ? guests : Array(guests.prefix(6))
        return section {
            row(icon: "person.2") {
                VStack(alignment: .leading, spacing: 8) {
                    if !guests.isEmpty {
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(guestCount) guest\(guestCount == 1 ? "" : "s")")
                            Text(replySummary).font(.system(size: 11.5)).foregroundStyle(WSColor.textTertiary)
                        }
                    }
                    if guests.isEmpty, let organizer = event.organizer {
                        guestRow(organizer)
                    }
                    ForEach(shown, id: \.email) { guestRow($0) }
                    if guests.count > shown.count {
                        Button("Show all \(guests.count)") { showAllGuests = true }
                            .buttonStyle(.borderless).font(.system(size: 12))
                    }
                    if event.canRSVP {
                        rsvpControl
                    }
                }
            }
        }
    }

    private func guestRow(_ g: EventAttendee) -> some View {
        HStack(spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Circle().fill(WSColor.hairline).frame(width: 22, height: 22)
                    .overlay(Text(String(g.displayName.prefix(1)).uppercased())
                        .font(.system(size: 10, weight: .semibold)).foregroundStyle(WSColor.textSecondary))
                    .overlay {
                        if g.isGroup { Image(systemName: "person.3.fill").font(.system(size: 8)).foregroundStyle(WSColor.textSecondary) }
                    }
                responseBadge(g.response)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(g.displayName + (g.isSelf ? " (you)" : "")).lineLimit(1)
                if g.isOrganizer {
                    Text("Organizer").font(.system(size: 11)).foregroundStyle(WSColor.textTertiary)
                } else if g.isOptional {
                    Text("Optional").font(.system(size: 11)).foregroundStyle(WSColor.textTertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12.5))
    }

    @ViewBuilder private func responseBadge(_ r: EventAttendee.Response) -> some View {
        switch r {
        case .accepted: badge("checkmark", ContainerColor.green.accent)
        case .declined: badge("xmark", WSColor.now)
        case .tentative: badge("questionmark", ContainerColor.gold.accent)
        case .needsAction: EmptyView()
        }
    }

    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 6, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 10, height: 10)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(WSColor.raised, lineWidth: 1))
            .offset(x: 2, y: 2)
    }

    private var rsvpControl: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Going?").font(.system(size: 11, weight: .semibold)).foregroundStyle(WSColor.textTertiary)
            HStack(spacing: 0) {
                rsvpButton("Yes", .accepted)
                rsvpButton("No", .declined)
                rsvpButton("Maybe", .tentative)
            }
            .background(RoundedRectangle(cornerRadius: 7).fill(WSColor.canvas))
        }
    }

    private func rsvpButton(_ title: String, _ response: EventAttendee.Response) -> some View {
        let on = myResponse == response
        return Button {
            myResponse = response
            model.respond(event, response)
        } label: {
            Text(title)
                .font(.system(size: 12.5, weight: on ? .semibold : .regular))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? WSColor.hairline : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(on ? WSColor.textPrimary : WSColor.textSecondary)
    }

    private var whereSection: some View {
        section {
            VStack(alignment: .leading, spacing: 10) {
                if let url = event.conferenceURL {
                    row(icon: "video") {
                        HStack {
                            Link(destination: url) {
                                Text("Join \(event.conferenceName ?? "call")")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(WSColor.action))
                                    .foregroundStyle(.white)
                            }
                            Text(url.host ?? "").font(.system(size: 11)).foregroundStyle(WSColor.textTertiary).lineLimit(1)
                        }
                    }
                }
                if let location = event.location, !location.isEmpty {
                    row(icon: "mappin.and.ellipse") {
                        if let maps = URL(string: "https://maps.apple.com/?q=\(location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                            Link(location, destination: maps)
                                .font(.system(size: 12.5))
                                .foregroundStyle(WSColor.textPrimary)
                                .underline()
                        }
                    }
                }
            }
        }
    }

    private var calendarSection: some View {
        section {
            VStack(alignment: .leading, spacing: 8) {
                row(icon: "calendar") {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color(hex: model.calendarSource.color(forCalendar: event.calendarId, fallback: event.calendarColor)))
                            .frame(width: 12, height: 12)
                        Text(event.calendarTitle).lineLimit(1)
                        if !event.isWritable { Image(systemName: "lock").imageScale(.small).foregroundStyle(WSColor.textTertiary) }
                    }
                }
                row(icon: "circle.lefthalf.filled") {
                    Text(event.isBusy ? "Busy" : "Free")
                }
                if !event.reminders.isEmpty {
                    row(icon: "bell") {
                        Text(event.reminders.map(Self.reminderText).joined(separator: ", "))
                    }
                }
            }
        }
    }

    private var belongsSection: some View {
        section {
            VStack(alignment: .leading, spacing: 4) {
                Picker("Belongs to", selection: Binding(
                    get: { mappedContainer },
                    set: { id in
                        mappedContainer = id
                        model.assign(event, to: id)
                    }
                )) {
                    Text("Not assigned").tag(UUID?.none)
                    ForEach(model.taskHolders) { c in
                        Text(model.locationLabels[c.id] ?? c.name).tag(UUID?.some(c.id))
                    }
                }
                Text("Assigned events show in that class or project's calendar and take its color.")
                    .font(.system(size: 11)).foregroundStyle(WSColor.textTertiary)
            }
        }
    }

    private var actionsSection: some View {
        section {
            HStack {
                if let link = event.htmlLink {
                    Link(destination: link) { Label("Open in Google Calendar", systemImage: "arrow.up.right.square") }
                        .font(.system(size: 12))
                }
                Spacer()
                if event.isWritable {
                    Button("Delete", role: .destructive) { model.pendingEventDelete = [event] }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                }
            }
        }
    }

    // MARK: Helpers

    private var divider: some View { Rectangle().fill(WSColor.hairline).frame(height: 1) }

    private func section<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, WSSpace.l)
            .padding(.vertical, WSSpace.m)
    }

    private func row<Content: View>(icon: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: WSSpace.m) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(WSColor.textTertiary)
                .frame(width: 18)
                .padding(.top, 1)
            content()
                .font(.system(size: 13))
                .foregroundStyle(WSColor.textPrimary)
        }
    }

    private var duration: String {
        let minutes = Int(end.timeIntervalSince(start) / 60)
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? (m > 0 ? "\(h)h \(m)min" : "\(h)h") : "\(m)min"
    }

    private var guestCount: Int { event.attendees.count }

    private var replySummary: String {
        let yes = event.attendees.filter { $0.response == .accepted }.count
        let no = event.attendees.filter { $0.response == .declined }.count
        let maybe = event.attendees.filter { $0.response == .tentative }.count
        let waiting = event.attendees.filter { $0.response == .needsAction }.count
        return [yes > 0 ? "\(yes) yes" : nil, no > 0 ? "\(no) no" : nil,
                maybe > 0 ? "\(maybe) maybe" : nil, waiting > 0 ? "\(waiting) awaiting" : nil]
            .compactMap { $0 }.joined(separator: ", ")
    }

    static func reminderText(_ minutes: Int) -> String {
        switch minutes {
        case 0: "At start"
        case ..<60: "\(minutes)min before"
        case 60..<1440: minutes % 60 == 0 ? "\(minutes / 60)h before" : "\(minutes)min before"
        default: "\(minutes / 1440)d before"
        }
    }

    /// Google descriptions are often HTML; show readable text.
    static func plainText(_ s: String) -> String {
        guard s.contains("<") else { return s }
        return s.replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "<br/>", with: "\n")
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
