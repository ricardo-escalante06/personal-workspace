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
    // Editable fields (writable events).
    @State private var titleDraft = ""
    @State private var locationDraft = ""
    @State private var notesDraft = ""
    @State private var colorId: String?
    @State private var isBusy = true
    @State private var reminders: [Int] = []
    @State private var calendarId = ""
    @State private var visibility = "default"
    @State private var showColors = false
    @State private var newGuest = ""
    @State private var removedGuests: Set<String> = []
    @State private var addingLink = false
    @State private var linkDraft = ""
    @State private var rsvpNote = ""
    @FocusState private var focus: Field?
    private enum Field { case title, location, notes, link, rsvpNote }

    private var editable: Bool { event.isWritable }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                titleSection
                timeSection
                divider
                peopleSection
                whereSection
                divider
                settingsSection
                footer
            }
            .padding(.bottom, WSSpace.m)
        }
        .background(WSColor.raised)
        .onChange(of: focus) { old, _ in
            // Text saves when you click away (Return too), like Notion: no Save buttons.
            if old == .title { commitTitle() }
            if old == .location { commitLocation() }
            if old == .notes { commitNotes() }
            if old == .rsvpNote { commitRSVPNote() }
        }
        .task(id: event.key) {
            start = event.start
            end = event.end
            myResponse = event.selfResponse
            titleDraft = event.title
            locationDraft = event.customLinkSpot == .location ? "" : (event.location ?? "")
            notesDraft = Self.plainText(event.notes ?? "")
            colorId = GoogleEventColors.id(forHex: event.eventColor)
            isBusy = event.isBusy
            reminders = event.reminders
            calendarId = event.calendarId
            removedGuests = []
            newGuest = ""
            rsvpNote = event.attendees.first { $0.isSelf }?.note ?? ""
            mappedContainer = try? await model.store.db.read { try EventMapper.load($0).containerId(for: event) }
        }
    }

    // MARK: Title + time

    private var titleSection: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(hex: shownColorHex))
                .frame(width: 3, height: 16)
            if editable {
                TextField("Title", text: $titleDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 18, weight: .medium))
                    .focused($focus, equals: .title)
                    .onSubmit(commitTitle)
            } else {
                Text(event.title)
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(event.isDeclined ? WSColor.textTertiary : WSColor.textPrimary)
                    .strikethrough(event.isDeclined)
                    .textSelection(.enabled)
            }
        }
        .padding(.horizontal, WSSpace.l)
        .padding(.top, WSSpace.l)
        .padding(.bottom, WSSpace.m)
    }

    private var timeSection: some View {
        row(icon: "clock") {
            VStack(alignment: .leading, spacing: 6) {
                if event.isAllDay {
                    Text("All day").foregroundStyle(WSColor.textPrimary)
                } else {
                    HStack(spacing: 8) {
                        if editable {
                            TimeChoice(time: start, earliest: nil, reference: nil) { setTimes(start: $0, keepLength: true) }
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(WSColor.textTertiary)
                            TimeChoice(time: end, earliest: start, reference: start) { setTimes(end: $0) }
                        } else {
                            Text(WSFormat.time(event.start))
                            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(WSColor.textTertiary)
                            Text(WSFormat.time(event.end))
                        }
                        Text(duration).foregroundStyle(WSColor.textTertiary)
                    }
                }
                if editable {
                    DayChoice(day: LocalDate(start)) { moveToDay($0) }
                } else {
                    Text(event.start.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                }
                HStack(spacing: 14) {
                    if editable {
                        quietToggle("All-day", on: event.isAllDay) { save { $0.isAllDay = !event.isAllDay } }
                    }
                    if event.isRecurring {
                        Label("Repeats", systemImage: "repeat").labelStyle(.titleAndIcon)
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(WSColor.textTertiary)
            }
        }
        .padding(.bottom, WSSpace.s)
    }

    /// Start moves keep the length; end moves change it. Applies at once.
    private func setTimes(start newStart: Date? = nil, end newEnd: Date? = nil, keepLength: Bool = false) {
        var s = start, e = end
        if let newStart {
            let length = end.timeIntervalSince(start)
            s = newStart
            if keepLength { e = newStart.addingTimeInterval(length) }
        }
        if let newEnd { e = max(newEnd, s.addingTimeInterval(15 * 60)) }
        start = s; end = e
        model.updateEvent(event, start: s, end: e)
    }

    private func moveToDay(_ day: LocalDate) {
        let shift = TimeInterval(LocalDate(start).daysUntil(day)) * 86_400
        guard shift != 0 else { return }
        // Same clock time on the new day (DST-safe).
        let cal = Calendar.current
        let t = cal.dateComponents([.hour, .minute], from: start)
        let newStart = cal.date(bySettingHour: t.hour ?? 0, minute: t.minute ?? 0, second: 0,
                                of: day.startOfDay(in: .current)) ?? start.addingTimeInterval(shift)
        setTimes(start: newStart, keepLength: true)
    }

    // MARK: People

    @ViewBuilder private var peopleSection: some View {
        let guests = event.attendees.sorted { a, b in
            if a.isOrganizer != b.isOrganizer { return a.isOrganizer }
            if a.isSelf != b.isSelf { return a.isSelf }
            return a.displayName < b.displayName
        }
        let canInvite = editable && event.provider == .google
        if !guests.isEmpty || event.organizer != nil || canInvite {
            row(icon: "person.2") {
                VStack(alignment: .leading, spacing: 8) {
                    if !guests.isEmpty {
                        HStack(spacing: 6) {
                            Text("\(guestCount) guest\(guestCount == 1 ? "" : "s")")
                            Text(replySummary).foregroundStyle(WSColor.textTertiary)
                        }
                    }
                    if guests.isEmpty, let organizer = event.organizer {
                        guestRow(organizer)
                    }
                    let shown = showAllGuests ? guests : Array(guests.prefix(6))
                    ForEach(shown, id: \.email) { guestRow($0) }
                    if guests.count > shown.count {
                        Button("Show all \(guests.count)") { showAllGuests = true }
                            .buttonStyle(.plain).foregroundStyle(WSColor.textSecondary)
                    }
                    if canInvite {
                        TextField(guests.isEmpty ? "Participants" : "Add participant", text: $newGuest)
                            .textFieldStyle(.plain)
                            .onSubmit {
                                let email = newGuest.trimmingCharacters(in: .whitespaces)
                                guard email.contains("@") else { return }
                                save { $0.addGuests = [email] }
                                newGuest = ""
                            }
                    }
                    if event.canRSVP {
                        rsvpControl
                    }
                }
            }
        }
    }

    private func guestRow(_ g: EventAttendee) -> some View {
        HStack(alignment: .top, spacing: 8) {
            ZStack(alignment: .bottomTrailing) {
                Circle().fill(WSColor.hairline).frame(width: 20, height: 20)
                    .overlay(Text(String(g.displayName.prefix(1)).uppercased())
                        .font(.system(size: 9.5, weight: .medium)).foregroundStyle(WSColor.textSecondary))
                    .overlay {
                        if g.isGroup { Image(systemName: "person.3.fill").font(.system(size: 7)).foregroundStyle(WSColor.textSecondary) }
                    }
                responseBadge(g.response)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(g.displayName + (g.isSelf ? " (you)" : "")).lineLimit(1)
                if g.isOrganizer || g.isOptional {
                    Text(g.isOrganizer ? "Organizer" : "Optional").font(.system(size: 11)).foregroundStyle(WSColor.textTertiary)
                }
                if let note = g.note, !g.isSelf {
                    Text("“\(note)”").font(.system(size: 11.5)).foregroundStyle(WSColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
            if editable && event.provider == .google && !g.isSelf && !g.isOrganizer {
                Button { removedGuests.insert(g.email); save { $0.removeGuests = [g.email] } } label: {
                    Image(systemName: "xmark").font(.system(size: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(WSColor.textTertiary)
                .help("Remove guest")
            }
        }
        .opacity(removedGuests.contains(g.email) ? 0.35 : 1)
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
            .font(.system(size: 5.5, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 9, height: 9)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(WSColor.raised, lineWidth: 1))
            .offset(x: 2, y: 2)
    }

    /// Going? Yes / No / Maybe, plus an optional note that goes to the organizer.
    private var rsvpControl: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                Text("Going?").foregroundStyle(WSColor.textTertiary)
                rsvpButton("Yes", .accepted)
                rsvpButton("No", .declined)
                rsvpButton("Maybe", .tentative)
            }
            TextField("Add a note for the organizer", text: $rsvpNote, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(1...4)
                .focused($focus, equals: .rsvpNote)
                .onSubmit(commitRSVPNote)
        }
        .padding(.top, 2)
    }

    private func rsvpButton(_ title: String, _ response: EventAttendee.Response) -> some View {
        let on = myResponse == response
        return Button {
            myResponse = response
            model.respond(event, response, note: rsvpNote.trimmingCharacters(in: .whitespacesAndNewlines))
        } label: {
            Text(title)
                .fontWeight(on ? .semibold : .regular)
                .foregroundStyle(on ? WSColor.textPrimary : WSColor.textSecondary)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4).fill(on ? WSColor.hairline : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func commitRSVPNote() {
        let note = rsvpNote.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = event.attendees.first { $0.isSelf }?.note ?? ""
        guard note != current else { return }
        // A note on its own counts as "Yes" if you haven't answered yet.
        let response = myResponse.flatMap { $0 == .needsAction ? nil : $0 } ?? .accepted
        myResponse = response
        model.respond(event, response, note: note)
    }

    // MARK: Where

    @ViewBuilder private var whereSection: some View {
        if let url = event.conferenceURL {
            row(icon: "video") {
                HStack(spacing: 8) {
                    Link(destination: url) {
                        Text("Join \(event.conferenceName ?? "call")")
                            .fontWeight(.medium)
                            .foregroundStyle(WSColor.action)
                    }
                    Text(url.host ?? "").font(.system(size: 11.5)).foregroundStyle(WSColor.textTertiary).lineLimit(1)
                    Spacer(minLength: 0)
                    PlainMenu {
                        Button("Copy Link") { Platform.copy(url.absoluteString) }
                        if editable { Button("Remove Link", role: .destructive) { removeLink() } }
                    } label: {
                        Image(systemName: "ellipsis").font(.system(size: 11)).foregroundStyle(WSColor.textTertiary)
                    }
                }
            }
        } else if editable {
            row(icon: "video") {
                if addingLink {
                    TextField("Paste a Zoom, Teams or other link", text: $linkDraft)
                        .textFieldStyle(.plain)
                        .focused($focus, equals: .link)
                        .onSubmit(addLink)
                        .onEscape { addingLink = false; linkDraft = "" }
                } else {
                    PlainMenu {
                        if event.provider == .google { Button("Add Google Meet") { save { $0.addMeet = true } } }
                        Button("Add Link…") { addingLink = true; focus = .link }
                    } label: {
                        Text("Conferencing").foregroundStyle(WSColor.textTertiary)
                    }
                }
            }
        }
        if editable, event.customLinkSpot != .location {
            row(icon: "mappin.and.ellipse") {
                TextField("Location", text: $locationDraft)
                    .textFieldStyle(.plain)
                    .focused($focus, equals: .location)
                    .onSubmit(commitLocation)
            }
        } else if let location = event.location, !location.isEmpty, event.customLinkSpot != .location {
            row(icon: "mappin.and.ellipse") {
                if let maps = URL(string: "https://maps.apple.com/?q=\(location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")") {
                    Link(location, destination: maps).foregroundStyle(WSColor.textPrimary)
                }
            }
        }
        if editable {
            row(icon: "text.alignleft") {
                TextField("Description", text: $notesDraft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...14)
                    .focused($focus, equals: .notes)
            }
        } else if let notes = event.notes, !notes.isEmpty {
            row(icon: "text.alignleft") {
                Text(Self.plainText(notes))
                    .foregroundStyle(WSColor.textSecondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// A custom link goes in the location when it's free (Google shows it as a link
    /// there), otherwise on the description's first line.
    private func addLink() {
        guard let url = ConferenceLink.normalized(linkDraft) else { addingLink = linkDraft.isEmpty ? false : true; return }
        addingLink = false
        linkDraft = ""
        let link = url.absoluteString
        if (event.location ?? "").trimmingCharacters(in: .whitespaces).isEmpty {
            locationDraft = link
            save { $0.location = link }
        } else {
            let notes = event.notes ?? ""
            let combined = notes.isEmpty ? link : link + "\n" + notes
            notesDraft = combined
            save { $0.notes = combined }
        }
    }

    private func removeLink() {
        switch event.customLinkSpot {
        case .location:
            locationDraft = ""
            save { $0.location = "" }
        case .notes:
            let rest = ConferenceLink.droppingFirstLine(of: event.notes)
            notesDraft = rest
            save { $0.notes = rest }
        case nil:
            save { $0.removeMeet = true }
        }
    }

    /// Calendar · color, then busy · visibility, alerts and class/project as one quiet
    /// block of plain text (each opens a menu).
    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(icon: "calendar") {
                HStack(spacing: 8) {
                    if editable && event.provider == .google {
                        colorMenu
                    } else {
                        RoundedRectangle(cornerRadius: 3).fill(Color(hex: shownColorHex)).frame(width: 12, height: 12)
                    }
                    if editable && sameAccountCalendars.count > 1 {
                        PlainMenu {
                            ForEach(sameAccountCalendars) { cal in
                                Button {
                                    calendarId = cal.id
                                    save { $0.calendarId = cal.id }
                                } label: {
                                    Label { Text(cal.title + (cal.id == calendarId ? "  ✓" : "")) } icon: { ColorSwatchImage.image(hex: cal.color) }
                                }
                            }
                        } label: {
                            Text(sameAccountCalendars.first { $0.id == calendarId }?.title ?? event.calendarTitle).lineLimit(1)
                        }
                    } else {
                        Text(event.calendarTitle).lineLimit(1)
                        if !event.isWritable { Image(systemName: "lock").font(.system(size: 10)).foregroundStyle(WSColor.textTertiary) }
                    }
                }
            }
            row(icon: nil) {
                HStack(spacing: 18) {
                    if editable {
                        PlainMenu {
                            Button("Busy") { isBusy = true; save { $0.isBusy = true } }
                            Button("Free") { isBusy = false; save { $0.isBusy = false } }
                        } label: { Text(isBusy ? "Busy" : "Free") }
                        if event.provider == .google {
                            PlainMenu {
                                Button("Default visibility") { visibility = "default"; save { $0.visibility = "default" } }
                                Button("Public") { visibility = "public"; save { $0.visibility = "public" } }
                                Button("Private") { visibility = "private"; save { $0.visibility = "private" } }
                            } label: { Text(visibility == "default" ? "Default visibility" : visibility.capitalized) }
                        }
                    } else {
                        Text(event.isBusy ? "Busy" : "Free")
                    }
                }
                .foregroundStyle(WSColor.textSecondary)
            }
            row(icon: "bell") {
                if editable {
                    PlainMenu {
                        ForEach([0, 5, 10, 15, 30, 60, 120, 1440], id: \.self) { m in
                            Button {
                                setReminders(reminders.contains(m) ? reminders.filter { $0 != m } : (reminders + [m]).sorted())
                            } label: {
                                Text(Self.reminderText(m) + (reminders.contains(m) ? "  ✓" : ""))
                            }
                        }
                    } label: {
                        Text(reminders.isEmpty ? "Reminders" : reminders.map(Self.reminderText).joined(separator: ", "))
                            .foregroundStyle(reminders.isEmpty ? WSColor.textTertiary : WSColor.textPrimary)
                            .lineLimit(2)
                    }
                } else {
                    Text(event.reminders.isEmpty ? "No reminders" : event.reminders.map(Self.reminderText).joined(separator: ", "))
                        .foregroundStyle(event.reminders.isEmpty ? WSColor.textTertiary : WSColor.textPrimary)
                }
            }
            row(icon: "folder") {
                PlainMenu {
                    Button("Not assigned") { mappedContainer = nil; model.assign(event, to: nil) }
                    Divider()
                    ForEach(model.taskHolders) { c in
                        Button(model.locationLabels[c.id] ?? c.name) { mappedContainer = c.id; model.assign(event, to: c.id) }
                    }
                } label: {
                    Text(mappedContainer.flatMap { model.locationLabels[$0] ?? model.container($0)?.name } ?? "Belongs to a class or project")
                        .foregroundStyle(mappedContainer == nil ? WSColor.textTertiary : WSColor.textPrimary)
                        .lineLimit(1)
                }
                .help("Assigned events show in that class or project's calendar and take its color.")
            }
        }
    }

    @ViewBuilder private var footer: some View {
        if event.htmlLink != nil || event.isWritable {
            HStack {
                if let link = event.htmlLink {
                    Link(destination: link) {
                        Label("Open in Google Calendar", systemImage: "arrow.up.right")
                    }
                    .foregroundStyle(WSColor.textTertiary)
                }
                Spacer()
                if event.isWritable {
                    Button("Delete") { model.deleteEvents([event]) }
                        .buttonStyle(.plain)
                        .foregroundStyle(WSColor.now.opacity(0.85))
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, WSSpace.l)
            .padding(.top, WSSpace.m)
        }
    }

    // MARK: Editing

    /// Calendars an event can move to: same account (Google can't move between accounts).
    private var sameAccountCalendars: [CalendarSource.CalendarInfo] {
        let mine = model.calendarSource.calendars.first { $0.id == event.calendarId }
        return model.calendarSource.writableCalendars.filter { $0.account == mine?.account && $0.provider == event.provider }
    }

    /// A palette of real swatches (menus can't show colors reliably).
    private var colorMenu: some View {
        let calendarHex = model.calendarSource.color(forCalendar: event.calendarId, fallback: event.calendarColor)
        return Button { showColors.toggle() } label: {
            RoundedRectangle(cornerRadius: 3)
                .fill(Color(hex: colorId.flatMap(GoogleEventColors.hex) ?? calendarHex))
                .frame(width: 12, height: 12)
                .contentShape(Rectangle())
        }
        .help(colorId.flatMap { id in GoogleEventColors.all.first { $0.id == id }?.name } ?? "Calendar color")
        .buttonStyle(.plain)
        .popover(isPresented: $showColors, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                swatch(name: "Calendar color", hex: calendarHex, selected: colorId == nil) {
                    colorId = nil; save { $0.colorId = .some(nil) }
                }
                Divider()
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(30), spacing: 6), count: 6), spacing: 6) {
                    ForEach(GoogleEventColors.all, id: \.id) { c in
                        Button {
                            colorId = c.id; save { $0.colorId = .some(c.id) }; showColors = false
                        } label: {
                            Circle().fill(Color(hex: GoogleEventColors.hex(c.id) ?? 0))
                                .frame(width: 24, height: 24)
                                .overlay(Circle().strokeBorder(.white, lineWidth: colorId == c.id ? 2 : 0))
                                .overlay { if colorId == c.id { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(.white) } }
                        }
                        .buttonStyle(.plain)
                        .help(c.name)
                    }
                }
            }
            .padding(12)
        }
    }

    private func swatch(name: String, hex: UInt32, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { action(); showColors = false } label: {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: hex)).frame(width: 16, height: 16)
                Text(name).font(.system(size: 12.5))
                if selected { Image(systemName: "checkmark").imageScale(.small) }
            }
        }
        .buttonStyle(.plain)
    }

    private func setReminders(_ value: [Int]) {
        reminders = value
        save { $0.reminders = value }
    }

    private func commitTitle() {
        let t = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t != event.title else { return }
        save { $0.title = t }
    }

    private func commitLocation() {
        guard event.customLinkSpot != .location, locationDraft != (event.location ?? "") else { return }
        save { $0.location = locationDraft }
    }

    private func commitNotes() {
        guard notesDraft != Self.plainText(event.notes ?? "") else { return }
        save { $0.notes = notesDraft }
    }

    private func save(_ change: (inout EventChanges) -> Void) {
        var c = EventChanges()
        change(&c)
        model.updateEvent(event, c)
    }

    // MARK: Helpers

    private var divider: some View {
        Rectangle().fill(WSColor.hairline).frame(height: 1)
            .padding(.horizontal, WSSpace.l)
            .padding(.vertical, WSSpace.s)
    }

    /// The shown color: the event's own, else its calendar's.
    private var shownColorHex: UInt32 {
        colorId.flatMap(GoogleEventColors.hex)
            ?? model.calendarSource.color(forCalendar: event.calendarId, fallback: event.calendarColor)
    }

    /// One line: a quiet icon, then plain text (no boxes).
    private func row<Content: View>(icon: String?, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if let icon { Image(systemName: icon) } else { Color.clear }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(WSColor.textTertiary)
            .frame(width: 16)
            content()
                .font(.system(size: 13))
                .foregroundStyle(WSColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, WSSpace.l)
        .padding(.vertical, 6)
    }

    private func quietToggle(_ title: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .foregroundStyle(on ? WSColor.textPrimary : WSColor.textTertiary)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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

/// A menu that looks like plain text (Notion-style): no button chrome or arrows.
struct PlainMenu<Items: View, Label: View>: View {
    @ViewBuilder let content: () -> Items
    @ViewBuilder let label: () -> Label

    init(@ViewBuilder _ content: @escaping () -> Items, @ViewBuilder label: @escaping () -> Label) {
        self.content = content
        self.label = label
    }

    var body: some View {
        Menu(content: content, label: label)
            #if os(macOS)
            .menuStyle(.borderlessButton)
            .padding(.leading, -3)   // borderless menus inset their label; line up with text
            #else
            .tint(WSColor.textPrimary)
            #endif
            .menuIndicator(.hidden)
            .fixedSize()
    }
}

/// A time shown as plain text; click for a list of times every 15 minutes.
/// With `reference`, each choice also shows its length ("1h 30m") from it.
struct TimeChoice: View {
    let time: Date
    let earliest: Date?
    let reference: Date?
    let pick: (Date) -> Void
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Text(WSFormat.time(time))
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(open ? WSColor.hairline : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -4)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(choices, id: \.self) { t in
                            Button {
                                open = false
                                pick(t)
                            } label: {
                                HStack {
                                    Text(WSFormat.time(t))
                                    if let reference {
                                        Text(Self.length(t.timeIntervalSince(reference))).foregroundStyle(WSColor.textTertiary)
                                    }
                                    Spacer()
                                    if abs(t.timeIntervalSince(time)) < 60 { Image(systemName: "checkmark").font(.system(size: 10)) }
                                }
                                .font(.system(size: 12.5))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .id(t)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(width: reference == nil ? 130 : 170, height: 260)
                .onAppear { proxy.scrollTo(choices.min { abs($0.timeIntervalSince(time)) < abs($1.timeIntervalSince(time)) }, anchor: .center) }
            }
            .presentationCompactAdaptation(.popover)
        }
    }

    private var choices: [Date] {
        if let earliest {
            // End times: from 15 minutes after the start, through the next 24 hours.
            return (1...96).map { earliest.addingTimeInterval(TimeInterval($0) * 15 * 60) }
        }
        let dayStart = Calendar.current.startOfDay(for: time)
        var list = (0..<96).map { dayStart.addingTimeInterval(TimeInterval($0) * 15 * 60) }
        if !list.contains(where: { abs($0.timeIntervalSince(time)) < 60 }) { list.append(time); list.sort() }
        return list
    }

    static func length(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        let h = minutes / 60, m = minutes % 60
        return h > 0 ? (m > 0 ? "\(h)h \(m)m" : "\(h)h") : "\(m)m"
    }
}

/// A day shown as plain text ("Tue, Nov 10"); click for a calendar. With no day, a
/// gray placeholder ("Due date") opens the same calendar.
struct DayChoice: View {
    let day: LocalDate?
    var placeholder = ""
    var prefix = ""
    let pick: (LocalDate) -> Void
    @State private var open = false

    init(day: LocalDate?, placeholder: String = "", prefix: String = "", pick: @escaping (LocalDate) -> Void) {
        self.day = day
        self.placeholder = placeholder
        self.prefix = prefix
        self.pick = pick
    }

    var body: some View {
        Button { open.toggle() } label: {
            Group {
                if let day {
                    Text(prefix + day.startOfDay(in: .current).formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))
                } else {
                    Text(placeholder).foregroundStyle(WSColor.textTertiary)
                }
            }
            .padding(.horizontal, 4).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(open ? WSColor.hairline : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -4)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            DatePicker("", selection: Binding(
                get: { (day ?? LocalDate(Date())).startOfDay(in: .current) },
                set: { d in open = false; pick(LocalDate(d)) }
            ), displayedComponents: .date)
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(WSSpace.s)
            .frame(width: 240)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// One line of a details panel: a quiet icon, then plain text (Notion-style, no boxes).
struct PanelRow<Content: View>: View {
    let icon: String?
    @ViewBuilder let content: () -> Content

    init(icon: String?, @ViewBuilder _ content: @escaping () -> Content) {
        self.icon = icon
        self.content = content
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if let icon { Image(systemName: icon) } else { Color.clear }
            }
            .font(.system(size: 12.5))
            .foregroundStyle(WSColor.textTertiary)
            .frame(width: 16)
            content()
                .font(.system(size: 13))
                .foregroundStyle(WSColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, WSSpace.l)
        .padding(.vertical, 6)
    }
}

struct PanelDivider: View {
    var body: some View {
        Rectangle().fill(WSColor.hairline).frame(height: 1)
            .padding(.horizontal, WSSpace.l)
            .padding(.vertical, WSSpace.s)
    }
}

/// Gray text you can click ("Add time", "Clear").
struct QuietButton: View {
    let title: String
    var help: String? = nil
    let action: () -> Void

    init(_ title: String, help: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).foregroundStyle(WSColor.textTertiary).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help ?? title)
    }
}

/// Text that's gray when off and bright when on ("All-day", "Milestone").
struct QuietToggle: View {
    let title: String
    let on: Bool
    let action: () -> Void

    init(_ title: String, on: Bool, action: @escaping () -> Void) {
        self.title = title
        self.on = on
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title).foregroundStyle(on ? WSColor.textPrimary : WSColor.textTertiary).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
