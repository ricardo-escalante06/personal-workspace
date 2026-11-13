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
    @FocusState private var focus: Field?
    private enum Field { case title, location, notes, link }

    private var editable: Bool { event.isWritable }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                titleSection
                divider
                timeSection
                if !event.attendees.isEmpty || event.organizer != nil || (editable && event.provider == .google) {
                    divider
                    guestsSection
                    if editable && event.provider == .google {
                        addGuestRow.padding(.horizontal, WSSpace.l).padding(.bottom, WSSpace.m)
                    }
                }
                if editable || event.conferenceURL != nil || (event.location?.isEmpty == false) {
                    divider
                    whereSection
                }
                if editable {
                    divider
                    section {
                        VStack(alignment: .trailing, spacing: 6) {
                            TextField("Add description", text: $notesDraft, axis: .vertical)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12.5))
                                .lineLimit(3...12)
                                .focused($focus, equals: .notes)
                            if notesDraft != Self.plainText(event.notes ?? "") {
                                Button("Save description") { save { $0.notes = notesDraft } }
                                    .buttonStyle(.borderedProminent).controlSize(.small)
                            }
                        }
                    }
                } else if let notes = event.notes, !notes.isEmpty {
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
            titleDraft = event.title
            locationDraft = event.location ?? ""
            notesDraft = Self.plainText(event.notes ?? "")
            colorId = GoogleEventColors.id(forHex: event.eventColor)
            isBusy = event.isBusy
            reminders = event.reminders
            calendarId = event.calendarId
            removedGuests = []
            newGuest = ""
            mappedContainer = try? await model.store.db.read { try EventMapper.load($0).containerId(for: event) }
        }
    }

    // MARK: Sections

    private var titleSection: some View {
        section {
            HStack(alignment: .top, spacing: WSSpace.s) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(hex: colorId.flatMap(GoogleEventColors.hex) ?? model.calendarSource.color(forCalendar: event.calendarId, fallback: event.calendarColor)))
                    .frame(width: 4, height: 22)
                if editable {
                    TextField("Title", text: $titleDraft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .semibold))
                        .focused($focus, equals: .title)
                        .onSubmit(commitTitle)
                        .onChange(of: focus) { old, _ in
                            if old == .title { commitTitle() }
                            if old == .location { commitLocation() }
                        }
                } else {
                    Text(event.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(event.isDeclined ? WSColor.textTertiary : WSColor.textPrimary)
                        .strikethrough(event.isDeclined)
                        .textSelection(.enabled)
                }
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
                    if editable {
                        Toggle("All-day", isOn: Binding(get: { event.isAllDay }, set: { v in save { $0.isAllDay = v } }))
                            .checkboxToggleStyle()
                            .font(.system(size: 12))
                            .foregroundStyle(WSColor.textSecondary)
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
            if editable && event.provider == .google && !g.isSelf && !g.isOrganizer {
                Button { removedGuests.insert(g.email); save { $0.removeGuests = [g.email] } } label: {
                    Image(systemName: "xmark").imageScale(.small)
                }
                .buttonStyle(.plain)
                .foregroundStyle(WSColor.textTertiary)
                .help("Remove guest")
            }
        }
        .font(.system(size: 12.5))
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
                        HStack(spacing: 8) {
                            Link(destination: url) {
                                Text("Join \(event.conferenceName ?? "call")")
                                    .font(.system(size: 12.5, weight: .semibold))
                                    .padding(.horizontal, 10).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(WSColor.action))
                                    .foregroundStyle(.white)
                            }
                            Text(url.host ?? "").font(.system(size: 11)).foregroundStyle(WSColor.textTertiary).lineLimit(1)
                            Spacer(minLength: 0)
                            Menu {
                                Button("Copy Link") { Platform.copy(url.absoluteString) }
                                if editable {
                                    Button("Remove Link", role: .destructive) { removeLink() }
                                }
                            } label: {
                                Image(systemName: "ellipsis").font(.system(size: 11))
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
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
                            HStack(spacing: 14) {
                                if event.provider == .google {
                                    Button("Add Google Meet") { save { $0.addMeet = true } }
                                }
                                Button("Add link") { addingLink = true; focus = .link }
                            }
                            .buttonStyle(.borderless)
                            .font(.system(size: 12.5))
                        }
                    }
                }
                if editable, event.customLinkSpot != .location {
                    row(icon: "mappin.and.ellipse") {
                        TextField("Add location", text: $locationDraft)
                            .textFieldStyle(.plain)
                            .focused($focus, equals: .location)
                            .onSubmit(commitLocation)
                    }
                } else if let location = event.location, !location.isEmpty, event.customLinkSpot != .location {
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

    private var calendarSection: some View {
        section {
            VStack(alignment: .leading, spacing: 8) {
                row(icon: "calendar") {
                    if editable && !sameAccountCalendars.isEmpty {
                        Picker("", selection: Binding(get: { calendarId }, set: { id in
                            calendarId = id
                            save { $0.calendarId = id }
                        })) {
                            ForEach(sameAccountCalendars) { cal in
                                Label { Text(cal.title) } icon: { ColorSwatchImage.image(hex: cal.color) }.tag(cal.id)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                    } else {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(hex: model.calendarSource.color(forCalendar: event.calendarId, fallback: event.calendarColor)))
                                .frame(width: 12, height: 12)
                            Text(event.calendarTitle).lineLimit(1)
                            if !event.isWritable { Image(systemName: "lock").imageScale(.small).foregroundStyle(WSColor.textTertiary) }
                        }
                    }
                }
                if editable && event.provider == .google {
                    row(icon: "paintpalette") { colorMenu }
                }
                row(icon: "circle.lefthalf.filled") {
                    if editable {
                        Picker("", selection: Binding(get: { isBusy }, set: { v in isBusy = v; save { $0.isBusy = v } })) {
                            Text("Busy").tag(true)
                            Text("Free").tag(false)
                        }
                        .labelsHidden().fixedSize()
                    } else {
                        Text(event.isBusy ? "Busy" : "Free")
                    }
                }
                if editable && event.provider == .google {
                    row(icon: "eye") {
                        Picker("", selection: Binding(get: { visibility }, set: { v in visibility = v; save { $0.visibility = v } })) {
                            Text("Default visibility").tag("default")
                            Text("Public").tag("public")
                            Text("Private").tag("private")
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                if editable {
                    row(icon: "bell") { remindersEditor }
                } else if !event.reminders.isEmpty {
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
                    Button("Delete", role: .destructive) { model.deleteEvents([event]) }
                        .buttonStyle(.borderless)
                        .font(.system(size: 12))
                }
            }
        }
    }

    // MARK: Editing

    /// Calendars an event can move to: same account (Google can't move between accounts).
    private var sameAccountCalendars: [CalendarSource.CalendarInfo] {
        let mine = model.calendarSource.calendars.first { $0.id == event.calendarId }
        return model.calendarSource.writableCalendars.filter { $0.account == mine?.account && $0.provider == event.provider }
    }

    /// "Add guest" field: type an email and press Return (they get an invite).
    private var addGuestRow: some View {
        HStack(spacing: WSSpace.m) {
            Image(systemName: "person.badge.plus").font(.system(size: 13)).foregroundStyle(WSColor.textTertiary).frame(width: 18)
            TextField("Add guest by email", text: $newGuest)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .onSubmit {
                    let email = newGuest.trimmingCharacters(in: .whitespaces)
                    guard email.contains("@") else { return }
                    save { $0.addGuests = [email] }
                    newGuest = ""
                }
        }
    }

    /// A palette of real swatches (menus can't show colors reliably).
    private var colorMenu: some View {
        let calendarHex = model.calendarSource.color(forCalendar: event.calendarId, fallback: event.calendarColor)
        return Button { showColors.toggle() } label: {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color(hex: colorId.flatMap(GoogleEventColors.hex) ?? calendarHex))
                    .frame(width: 12, height: 12)
                Text(colorId.flatMap { id in GoogleEventColors.all.first { $0.id == id }?.name } ?? "Calendar color")
                Image(systemName: "chevron.down").imageScale(.small).foregroundStyle(WSColor.textTertiary)
            }
        }
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

    private var remindersEditor: some View {
        let options = [0, 5, 10, 15, 30, 60, 120, 1440]
        return HStack(spacing: 6) {
            ForEach(reminders, id: \.self) { m in
                HStack(spacing: 3) {
                    Text(Self.reminderText(m))
                    Button { setReminders(reminders.filter { $0 != m }) } label: { Image(systemName: "xmark").imageScale(.small) }
                        .buttonStyle(.plain).foregroundStyle(WSColor.textTertiary)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 7).padding(.vertical, 2)
                .background(Capsule().fill(WSColor.hairline))
            }
            Menu {
                ForEach(options.filter { !reminders.contains($0) }, id: \.self) { m in
                    Button(Self.reminderText(m)) { setReminders((reminders + [m]).sorted()) }
                }
            } label: {
                Text(reminders.isEmpty ? "Add alert" : "+").font(.system(size: 12))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
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
        guard locationDraft != (event.location ?? "") else { return }
        save { $0.location = locationDraft }
    }

    private func save(_ change: (inout EventChanges) -> Void) {
        var c = EventChanges()
        change(&c)
        model.updateEvent(event, c)
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
