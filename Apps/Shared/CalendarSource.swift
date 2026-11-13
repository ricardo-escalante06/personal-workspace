import EventKit
import Foundation
import Observation
import WorkspaceKit

/// Every calendar the app shows, from two providers:
///  - **Google**, through Google's API (`GoogleCalendarService`): RSVP, guests,
///    Meet links, and changes in seconds.
///  - **System** calendars through EventKit: iCloud, Exchange, subscriptions…
///    When a Google account is connected here, EventKit's copy of Google calendars
///    is skipped so nothing shows twice.
@MainActor
@Observable
final class CalendarSource {
    enum Access: Equatable {
        case notDetermined, granted, denied, writeOnly
    }

    struct CalendarInfo: Identifiable, Hashable {
        var id: String
        var title: String
        /// Account name, e.g. "you@gmail.com" or "iCloud".
        var account: String
        var color: UInt32
        var isWritable: Bool
        var provider: EventProvider
    }

    private let store = EKEventStore()
    /// Present when the app was built with a Google OAuth client id.
    let google: GoogleCalendarService?

    /// EventKit (system calendar) permission.
    private(set) var access: Access = .notDetermined
    private(set) var systemCalendars: [CalendarInfo] = []
    /// Bumped whenever any calendar data changes, so views refetch.
    private(set) var revision = 0

    /// Calendars the user switched off (per device).
    var hiddenCalendarIds: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenCalendarIds), forKey: "hiddenCalendarIds") }
    }
    /// Whole accounts switched off (Google email or system source title like "iCloud").
    var hiddenAccounts: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenAccounts), forKey: "hiddenCalendarAccounts") }
    }

    /// Calendars hidden directly or because their whole account is hidden.
    var effectiveHiddenCalendarIds: Set<String> {
        hiddenCalendarIds.union(calendars.filter { hiddenAccounts.contains($0.account) }.map(\.id))
    }

    /// Per-calendar color overrides (0xRRGGBB), per device.
    var colorOverrides: [String: UInt32] {
        didSet {
            UserDefaults.standard.set(colorOverrides.mapValues { Int($0) }, forKey: "calendarColorOverrides")
            revision += 1
        }
    }
    /// Where new events go unless chosen otherwise.
    var preferredDefaultCalendarId: String? {
        didSet { UserDefaults.standard.set(preferredDefaultCalendarId, forKey: "defaultCalendarId") }
    }

    @ObservationIgnored private var changeObserver: NSObjectProtocol?

    init() {
        hiddenCalendarIds = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendarIds") ?? [])
        hiddenAccounts = Set(UserDefaults.standard.stringArray(forKey: "hiddenCalendarAccounts") ?? [])
        colorOverrides = ((UserDefaults.standard.dictionary(forKey: "calendarColorOverrides") as? [String: Int]) ?? [:])
            .mapValues { UInt32($0) }
        preferredDefaultCalendarId = UserDefaults.standard.string(forKey: "defaultCalendarId")

        let clientId = (Bundle.main.object(forInfoDictionaryKey: "GoogleClientID") as? String)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        google = (clientId.isEmpty || clientId.hasPrefix("$(")) ? nil : GoogleCalendarService(clientId: clientId)

        refreshAccess()
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.reloadSystemCalendars()
                self?.revision += 1
            }
        }
        if access == .granted { reloadSystemCalendars() }

        google?.onChange = { [weak self] in
            self?.reloadSystemCalendars()   // Google connect/disconnect changes which system calendars are duplicates
            self?.revision += 1
        }
        google?.startPolling()
    }

    // MARK: Calendars

    var isGoogleAvailable: Bool { google != nil }
    var isGoogleConnected: Bool { google?.isConnected ?? false }
    var hasAnyCalendars: Bool { access == .granted || isGoogleConnected }

    var calendars: [CalendarInfo] {
        let googleCals = (google?.calendars ?? []).map { ref in
            CalendarInfo(id: ref.key, title: ref.entry.title, account: ref.email,
                         color: GoogleCalendarAPI.hex(ref.entry.backgroundColor) ?? 0x5AA9E6,
                         isWritable: ref.entry.isWritable, provider: .google)
        }
        return googleCals + systemCalendars
    }

    var writableCalendars: [CalendarInfo] { calendars.filter(\.isWritable) }

    private func reloadSystemCalendars() {
        guard access == .granted else { systemCalendars = []; return }
        let skipGoogle = isGoogleConnected
        systemCalendars = store.calendars(for: .event)
            .filter { !(skipGoogle && Self.isGoogleBacked($0)) }
            .map { c in
                CalendarInfo(id: c.calendarIdentifier, title: c.title, account: c.source?.title ?? "",
                             color: Self.hex(c.cgColor), isWritable: c.allowsContentModifications, provider: .system)
            }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    /// Google accounts added in System Settings show up in EventKit as CalDAV sources.
    private static func isGoogleBacked(_ c: EKCalendar) -> Bool {
        let title = c.source?.title.lowercased() ?? ""
        return title.contains("google") || title.contains("gmail")
    }

    /// The user's chosen default (if it still exists and is writable), else the first
    /// writable Google calendar, else the system default.
    var defaultCalendarId: String? {
        if let id = preferredDefaultCalendarId, writableCalendars.contains(where: { $0.id == id }) { return id }
        if let g = calendars.first(where: { $0.provider == .google && $0.isWritable }) { return g.id }
        return store.defaultCalendarForNewEvents?.calendarIdentifier
    }

    /// Display color: user override, else the calendar's own color.
    func color(forCalendar id: String, fallback: UInt32) -> UInt32 {
        colorOverrides[id] ?? fallback
    }

    // MARK: Access + refresh

    private func refreshAccess() {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized: access = .granted
        case .writeOnly: access = .writeOnly
        case .denied, .restricted: access = .denied
        case .notDetermined: access = .notDetermined
        @unknown default: access = .denied
        }
    }

    func requestAccess() async {
        _ = try? await store.requestFullAccessToEvents()
        refreshAccess()
        if access == .granted {
            store.reset()
            reloadSystemCalendars()
            revision += 1
        }
    }

    func connectGoogle() async throws {
        try await google?.connect()
        reloadSystemCalendars()
        revision += 1
    }

    /// Pull changes now: Google incrementally, system calendars via their accounts.
    func refresh() {
        if access == .granted { store.refreshSourcesIfNecessary() }
        Task { await google?.syncAll() }
    }

    // MARK: Reading

    /// Events overlapping [start, end) from every provider (filtering happens in CalendarQuery).
    func events(from start: Date, to end: Date) -> [ExternalEvent] {
        var out = google?.events(from: start, to: end) ?? []
        if access == .granted {
            let systemIds = Set(systemCalendars.map(\.id))
            let cals = store.calendars(for: .event).filter { systemIds.contains($0.calendarIdentifier) }
            if !cals.isEmpty {
                let predicate = store.predicateForEvents(withStart: start, end: end, calendars: cals)
                out += store.events(matching: predicate).map(Self.convert)
            }
        }
        return out
    }

    private static func convert(_ e: EKEvent) -> ExternalEvent {
        let base = e.calendarItemExternalIdentifier ?? e.eventIdentifier ?? UUID().uuidString
        let key = e.hasRecurrenceRules ? "\(base)@\(ISODate.format(e.occurrenceDate ?? e.startDate))" : base
        var event = ExternalEvent(
            key: key,
            localId: e.eventIdentifier ?? base,
            calendarId: e.calendar.calendarIdentifier,
            calendarTitle: e.calendar.title,
            calendarColor: hex(e.calendar.cgColor),
            title: e.title ?? "(No title)",
            start: e.startDate,
            end: e.endDate,
            isAllDay: e.isAllDay,
            isWritable: e.calendar.allowsContentModifications,
            isTentative: e.status == .tentative || e.status == .canceled,
            location: e.location,
            notes: e.notes
        )
        event.provider = .system
        event.providerEventId = e.eventIdentifier
        let attendees: [EventAttendee] = (e.attendees ?? []).map(Self.attendee)
        event.attendees = attendees
        event.organizer = e.organizer.map { o in
            EventAttendee(email: o.url.absoluteString.replacingOccurrences(of: "mailto:", with: ""), name: o.name,
                          response: .accepted, isSelf: o.isCurrentUser, isOrganizer: true)
        }
        if let me = attendees.first(where: { $0.isSelf }), event.organizer?.isSelf != true {
            event.selfResponse = me.response
            event.isTentative = event.isTentative || event.isAwaitingResponse
        }
        event.conferenceURL = e.url
        event.isBusy = e.availability != .free
        event.reminders = (e.alarms ?? []).compactMap { a in a.relativeOffset < 0 ? Int(-a.relativeOffset / 60) : nil }
        event.isRecurring = e.hasRecurrenceRules
        return event
    }

    private static func attendee(_ p: EKParticipant) -> EventAttendee {
        let response: EventAttendee.Response
        switch p.participantStatus {
        case .accepted: response = .accepted
        case .declined: response = .declined
        case .tentative: response = .tentative
        default: response = .needsAction
        }
        let email = p.url.absoluteString.replacingOccurrences(of: "mailto:", with: "")
        return EventAttendee(
            email: email, name: p.name, response: response,
            isSelf: p.isCurrentUser,
            isOrganizer: p.participantRole == .chair,
            isOptional: p.participantRole == .optional,
            isGroup: p.participantType == .group
        )
    }

    // MARK: Writing

    enum WriteError: LocalizedError {
        case notFound, readOnly, noGoogle
        var errorDescription: String? {
            switch self {
            case .notFound: "That event couldn't be found. It may have been changed elsewhere."
            case .readOnly: "That calendar is read-only."
            case .noGoogle: "Google Calendar isn't connected."
            }
        }
    }

    /// Moves `event` (one occurrence, it and the ones after, or the whole series).
    func move(_ event: ExternalEvent, start: Date, end: Date, scope: EventEditScope, notify: Bool = true) async throws {
        guard event.isRecurring, scope != .one else { return try await move(event, start: start, end: end, notify: notify) }
        if scope == .all { return try await moveSeries(event, start: start, end: end, notify: notify) }
        let cal = Calendar.current
        let dayShift = cal.dateComponents([.day], from: cal.startOfDay(for: event.start), to: cal.startOfDay(for: start)).day ?? 0
        if event.provider == .google {
            guard let google else { throw WriteError.noGoogle }
            try await google.editFollowing(of: event, newStart: start, newEnd: end, dayShift: dayShift, notify: notify)
            return
        }
        guard let e = findEvent(event) else { throw WriteError.notFound }
        guard e.calendar.allowsContentModifications else { throw WriteError.readOnly }
        e.startDate = start
        e.endDate = end
        Self.shiftRepeatDays(e, by: dayShift)
        try store.save(e, span: .futureEvents, commit: true)
    }

    /// Saves edits from the event panel (title, place, notes, color, busy, alerts, calendar).
    func update(_ event: ExternalEvent, _ changes: EventChanges, wholeSeries: Bool, notify: Bool = true) async throws {
        if event.provider == .google {
            guard let google else { throw WriteError.noGoogle }
            try await google.update(event, changes, wholeSeries: wholeSeries, notify: notify)
            return
        }
        let target = wholeSeries && event.isRecurring ? (store.event(withIdentifier: event.localId) ?? findEvent(event)) : findEvent(event)
        guard let e = target else { throw WriteError.notFound }
        guard e.calendar.allowsContentModifications else { throw WriteError.readOnly }
        if let t = changes.title { e.title = t }
        if let l = changes.location { e.location = l.isEmpty ? nil : l }
        if let n = changes.notes { e.notes = n.isEmpty ? nil : n }
        if let busy = changes.isBusy { e.availability = busy ? .busy : .free }
        if let r = changes.reminders { e.alarms = r.map { EKAlarm(relativeOffset: -Double($0) * 60) } }
        if let allDay = changes.isAllDay, allDay != e.isAllDay {
            let day = LocalDate(e.startDate)
            e.isAllDay = allDay
            if allDay {
                e.startDate = day.startOfDay(in: .current)
                e.endDate = day.adding(days: 1).startOfDay(in: .current)
            } else {
                e.startDate = day.at(LocalTime(hour: 9, minute: 0))
                e.endDate = e.startDate.addingTimeInterval(3600)
            }
        }
        if let id = changes.calendarId, let cal = store.calendar(withIdentifier: id), cal.allowsContentModifications {
            e.calendar = cal
        }
        try store.save(e, span: wholeSeries && event.isRecurring ? .futureEvents : .thisEvent, commit: true)
    }

    /// Deletes one occurrence, it and the ones after, or the whole series.
    func delete(_ event: ExternalEvent, scope: EventEditScope, notify: Bool = true) async throws {
        guard event.isRecurring, scope != .one else { return try await delete(event, notify: notify) }
        if event.provider == .google {
            guard let google else { throw WriteError.noGoogle }
            if scope == .all { try await google.deleteSeries(of: event, notify: notify) }
            else { try await google.editFollowing(of: event, newStart: nil, newEnd: nil, dayShift: 0, notify: notify) }
            return
        }
        let target = scope == .all ? (store.event(withIdentifier: event.localId) ?? findEvent(event)) : findEvent(event)
        guard let e = target else { throw WriteError.notFound }
        guard e.calendar.allowsContentModifications else { throw WriteError.readOnly }
        try store.remove(e, span: .futureEvents, commit: true)
    }

    private static func shiftRepeatDays(_ e: EKEvent, by dayShift: Int) {
        guard dayShift != 0, let rule = e.recurrenceRules?.first, let days = rule.daysOfTheWeek, !days.isEmpty else { return }
        let shifted = days.map { d in
            EKRecurrenceDayOfWeek(EKWeekday(rawValue: RecurrenceDays.shift(d.dayOfTheWeek.rawValue, by: dayShift))!)
        }
        e.removeRecurrenceRule(rule)
        e.addRecurrenceRule(EKRecurrenceRule(
            recurrenceWith: rule.frequency, interval: rule.interval, daysOfTheWeek: shifted,
            daysOfTheMonth: rule.daysOfTheMonth, monthsOfTheYear: rule.monthsOfTheYear,
            weeksOfTheYear: rule.weeksOfTheYear, daysOfTheYear: rule.daysOfTheYear,
            setPositions: rule.setPositions, end: rule.recurrenceEnd))
    }

    /// Moves a repeating event's whole series by the same amount `event` moved.
    func moveSeries(_ event: ExternalEvent, start: Date, end: Date, notify: Bool = true) async throws {
        let delta = start.timeIntervalSince(event.start)
        let duration = end.timeIntervalSince(start)
        let cal = Calendar.current
        let dayShift = cal.dateComponents([.day], from: cal.startOfDay(for: event.start), to: cal.startOfDay(for: start)).day ?? 0
        if event.provider == .google {
            guard let google else { throw WriteError.noGoogle }
            try await google.moveSeries(of: event, delta: delta, duration: duration, dayShift: dayShift, notify: notify)
            return
        }
        // EventKit hands back the first occurrence for the series' identifier.
        guard let first = store.event(withIdentifier: event.localId) ?? findEvent(event) else { throw WriteError.notFound }
        guard first.calendar.allowsContentModifications else { throw WriteError.readOnly }
        let newStart = first.startDate.addingTimeInterval(delta)
        first.startDate = newStart
        first.endDate = newStart.addingTimeInterval(duration)
        Self.shiftRepeatDays(first, by: dayShift)
        try store.save(first, span: .futureEvents, commit: true)
    }

    func move(_ event: ExternalEvent, start: Date, end: Date, notify: Bool = true) async throws {
        if event.provider == .google {
            guard let google else { throw WriteError.noGoogle }
            try await google.move(event, start: start, end: end, notify: notify)
            return
        }
        guard let e = findEvent(event) else { throw WriteError.notFound }
        guard e.calendar.allowsContentModifications else { throw WriteError.readOnly }
        e.startDate = start
        e.endDate = end
        try store.save(e, span: .thisEvent, commit: true)
    }

    func delete(_ event: ExternalEvent, notify: Bool = true) async throws {
        if event.provider == .google {
            guard let google else { throw WriteError.noGoogle }
            try await google.delete(event, notify: notify)
            return
        }
        guard let e = findEvent(event) else { throw WriteError.notFound }
        guard e.calendar.allowsContentModifications else { throw WriteError.readOnly }
        try store.remove(e, span: .thisEvent, commit: true)
    }

    /// Deletes a class meeting's weekly series: recurring events titled `title` that
    /// start at `minute` past midnight on one of `weekdays` between `from` and `to`.
    /// Returns how many series were removed.
    @discardableResult
    func deleteMeetingSeries(title: String, minute: Int, weekdays: Set<Int>, from: Date, to: Date) async throws -> Int {
        let cal = Calendar.current
        let matches = events(from: from, to: to).filter { e in
            let c = cal.dateComponents([.hour, .minute, .weekday], from: e.start)
            return e.isRecurring && e.title == title
                && (c.hour ?? 0) * 60 + (c.minute ?? 0) == minute
                && weekdays.contains(c.weekday ?? 0)
        }
        var removed = 0
        // Google: one DELETE per series (instances share a master event).
        var seen = Set<String>()
        for e in matches where e.provider == .google {
            guard let google else { throw WriteError.noGoogle }
            let key = e.calendarId + "|" + e.title
            guard seen.insert(key).inserted else { continue }
            try await google.deleteSeries(of: e)
            removed += 1
        }
        // System calendars: remove the earliest occurrence with "this and future".
        let system = Dictionary(grouping: matches.filter { $0.provider != .google }, by: \.localId)
        for (_, occurrences) in system {
            guard let first = occurrences.min(by: { $0.start < $1.start }), let e = findEvent(first) else { continue }
            guard e.calendar.allowsContentModifications else { throw WriteError.readOnly }
            try store.remove(e, span: .futureEvents, commit: true)
            removed += 1
        }
        return removed
    }

    func respond(_ event: ExternalEvent, _ response: EventAttendee.Response) async throws {
        guard event.provider == .google, let google else { throw WriteError.readOnly }
        try await google.respond(event, response)
    }

    /// Where a newly created event lives, so it can be removed again (⌘Z after a paste).
    enum CreatedEvent: Sendable {
        case google(calendarKey: String, eventId: String)
        case system(identifier: String)
    }

    @discardableResult
    func create(title: String, start: Date, end: Date, calendarId: String?,
                location: String? = nil, notes: String? = nil, copying template: ExternalEvent? = nil) async throws -> CreatedEvent? {
        let target = calendarId ?? defaultCalendarId
        if let target, GoogleCalendarAPI.parseCalendarKey(target) != nil {
            guard let google else { throw WriteError.noGoogle }
            let id = try await google.create(title: title, start: start, end: end, calendarKey: target,
                                             location: location, copying: template)
            return .google(calendarKey: target, eventId: id)
        }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = start
        e.endDate = end
        e.calendar = target.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewEvents
        e.location = location
        e.notes = notes
        if let t = template {
            e.isAllDay = t.isAllDay
            e.availability = t.isBusy ? .busy : .free
            e.alarms = t.reminders.map { EKAlarm(relativeOffset: -Double($0) * 60) }
        }
        guard e.calendar != nil else { throw WriteError.readOnly }
        try store.save(e, span: .thisEvent, commit: true)
        return e.eventIdentifier.map { .system(identifier: $0) }
    }

    /// Removes an event this app just created.
    func delete(_ created: CreatedEvent) async throws {
        switch created {
        case .google(let key, let id):
            guard let google else { throw WriteError.noGoogle }
            try await google.delete(calendarKey: key, eventId: id)
        case .system(let identifier):
            guard let e = store.event(withIdentifier: identifier) else { return }
            try store.remove(e, span: .thisEvent, commit: true)
        }
    }

    /// Weekly recurring event (class meetings) from `firstStart` until `until`.
    func createWeekly(title: String, firstStart: Date, duration: TimeInterval, weekdays: [Int],
                      until: Date, location: String?, calendarId: String?) async throws {
        let target = calendarId ?? defaultCalendarId
        if let target, GoogleCalendarAPI.parseCalendarKey(target) != nil {
            guard let google else { throw WriteError.noGoogle }
            var utc = Calendar(identifier: .gregorian)
            utc.timeZone = TimeZone(identifier: "UTC")!
            let c = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: until)
            let untilString = String(format: "%04d%02d%02dT%02d%02d%02dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
            let rule = "RRULE:FREQ=WEEKLY;BYDAY=\(GoogleCalendarAPI.byDay(weekdays));UNTIL=\(untilString)"
            try await google.create(title: title, start: firstStart, end: firstStart.addingTimeInterval(duration),
                                    calendarKey: target, location: location, recurrence: [rule])
            return
        }
        let e = EKEvent(eventStore: store)
        e.title = title
        e.startDate = firstStart
        e.endDate = firstStart.addingTimeInterval(duration)
        e.location = location
        e.calendar = target.flatMap { store.calendar(withIdentifier: $0) } ?? store.defaultCalendarForNewEvents
        guard e.calendar != nil else { throw WriteError.readOnly }
        let days = weekdays.compactMap { EKWeekday(rawValue: $0) }.map { EKRecurrenceDayOfWeek($0) }
        e.addRecurrenceRule(EKRecurrenceRule(
            recurrenceWith: .weekly, interval: 1, daysOfTheWeek: days,
            daysOfTheMonth: nil, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil,
            setPositions: nil, end: EKRecurrenceEnd(end: until)
        ))
        try store.save(e, span: .futureEvents, commit: true)
    }

    // MARK: Calendars (create / delete)

    /// Creates a calendar in a Google account or a system account (e.g. iCloud).
    func createCalendar(named name: String, inAccount account: String) async throws {
        if let google, google.accounts.contains(where: { $0.email == account }) {
            try await google.createCalendar(named: name, email: account)
            return
        }
        guard let source = store.sources.first(where: { $0.title == account }) else { throw WriteError.notFound }
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = name
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        reloadSystemCalendars()
        revision += 1
    }

    /// Google: deletes calendars you own; for shared/subscribed ones, removes them from your list.
    /// System: deletes the calendar (iCloud etc. allow this for calendars you own).
    func deleteCalendar(_ info: CalendarInfo) async throws {
        hiddenCalendarIds.remove(info.id)
        colorOverrides[info.id] = nil
        if info.provider == .google {
            guard let google, let ref = GoogleCalendarAPI.parseCalendarKey(info.id) else { throw WriteError.noGoogle }
            try await google.deleteCalendar(email: ref.account, calendarId: ref.calendarId)
            return
        }
        guard let calendar = store.calendar(withIdentifier: info.id) else { throw WriteError.notFound }
        try store.removeCalendar(calendar, commit: true)
        reloadSystemCalendars()
        revision += 1
    }

    /// What deleting does, for the confirmation text.
    func deleteKind(_ info: CalendarInfo) -> (verb: String, detail: String) {
        if info.provider == .google, let ref = GoogleCalendarAPI.parseCalendarKey(info.id),
           let entry = google?.calendars.first(where: { $0.key == info.id })?.entry {
            if entry.primary == true {
                return ("Remove", "Your main \(ref.account) calendar can't be deleted; it will be removed from this list.")
            }
            return entry.accessRole == "owner"
                ? ("Delete", "This permanently deletes the calendar and all its events from Google for everyone it's shared with.")
                : ("Remove", "This removes it from your Google calendar list. The calendar itself isn't deleted.")
        }
        return ("Delete", "This deletes the calendar and its events from \(info.account).")
    }

    /// Accounts that can hold new calendars: connected Google accounts + writable system sources.
    func canCreateCalendars(in account: String) -> Bool {
        if google?.accounts.contains(where: { $0.email == account }) == true { return true }
        return store.sources.contains { $0.title == account && ($0.sourceType == .calDAV || $0.sourceType == .local || $0.sourceType == .exchange) }
            && !account.lowercased().contains("subscribed")
    }

    func googleSettingsURL(for info: CalendarInfo) -> URL? {
        guard let ref = GoogleCalendarAPI.parseCalendarKey(info.id) else { return nil }
        let encoded = Data(ref.calendarId.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return URL(string: "https://calendar.google.com/calendar/r/settings/calendar/\(encoded)?authuser=\(ref.account)")
    }

    /// Finds the specific occurrence: eventIdentifier alone returns the series' first occurrence.
    private func findEvent(_ event: ExternalEvent) -> EKEvent? {
        let window = store.predicateForEvents(
            withStart: event.start.addingTimeInterval(-60), end: event.end.addingTimeInterval(60),
            calendars: store.calendar(withIdentifier: event.calendarId).map { [$0] }
        )
        return store.events(matching: window).first { $0.eventIdentifier == event.localId }
            ?? store.event(withIdentifier: event.localId)
    }

    private static func hex(_ color: CGColor?) -> UInt32 {
        guard let color,
              let srgb = color.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil),
              let c = srgb.components, c.count >= 3
        else { return 0x8A8A8A }
        func byte(_ v: CGFloat) -> UInt32 { UInt32(max(0, min(255, (v * 255).rounded()))) }
        return byte(c[0]) << 16 | byte(c[1]) << 8 | byte(c[2])
    }
}

/// For repeating events: which occurrences an edit or delete applies to.
enum EventEditScope {
    case one, following, all
}
