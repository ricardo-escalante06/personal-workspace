import Foundation
import Observation
import WorkspaceKit

/// Google Calendar via its API, per connected account.
///
/// Sync: one full fetch per calendar (a window around today), then Google's
/// incremental `syncToken` every 30 s while the app is active. Deletions and edits
/// made in Google arrive in seconds. Events are cached on disk per account, so the
/// calendar opens instantly and works offline (read-only).
@MainActor
@Observable
final class GoogleCalendarService {
    struct Account: Identifiable, Equatable {
        var email: String
        var calendars: [GoogleCalendarAPI.CalendarListEntry] = []
        var lastSync: Date?
        var error: String?
        var id: String { email }
    }

    /// What we keep per account on disk.
    private struct Cache: Codable {
        var calendars: [GoogleCalendarAPI.CalendarListEntry] = []
        /// calendarId → eventId → event
        var events: [String: [String: GoogleCalendarAPI.Event]] = [:]
        var syncTokens: [String: String] = [:]
        var defaultReminders: [String: [GoogleCalendarAPI.Reminder]] = [:]
    }

    enum ServiceError: LocalizedError {
        case notConnected, http(Int, String)
        var errorDescription: String? {
            switch self {
            case .notConnected: "That Google account isn't connected."
            case .http(let code, let msg): "Google Calendar error \(code): \(msg)"
            }
        }
    }

    let auth: GoogleAuth
    private(set) var accounts: [Account] = []
    /// Bumped whenever cached events change, so views refetch.
    private(set) var revision = 0
    private(set) var isSyncing = false
    var onChange: (() -> Void)?

    @ObservationIgnored private var caches: [String: Cache] = [:]
    @ObservationIgnored private var accessTokens: [String: GoogleAuth.Tokens] = [:]
    @ObservationIgnored private var pollTask: Task<Void, Never>?

    /// Full-sync window. Incremental syncs then keep everything current.
    private let pastWindow: TimeInterval = 120 * 86_400
    private let futureWindow: TimeInterval = 400 * 86_400

    init(clientId: String) {
        auth = GoogleAuth(clientId: clientId)
        let emails = UserDefaults.standard.stringArray(forKey: "googleAccounts") ?? []
        for email in emails {
            let cache = Self.loadCache(email) ?? Cache()
            caches[email] = cache
            accounts.append(Account(email: email, calendars: cache.calendars))
        }
    }

    var isConnected: Bool { !accounts.isEmpty }

    // MARK: Accounts

    func connect() async throws {
        let tokens = try await auth.signIn()
        guard let email = tokens.email, let refresh = tokens.refreshToken else {
            throw GoogleAuth.AuthError.badResponse("no account email")
        }
        GoogleKeychain.save(refresh, for: email)
        accessTokens[email] = tokens
        if !accounts.contains(where: { $0.email == email }) {
            accounts.append(Account(email: email))
            caches[email] = Cache()
            saveAccountList()
        }
        await sync(email: email)
    }

    func disconnect(_ email: String) async {
        if let refresh = GoogleKeychain.load(email) { await auth.revoke(refreshToken: refresh) }
        GoogleKeychain.delete(email)
        accounts.removeAll { $0.email == email }
        caches[email] = nil
        accessTokens[email] = nil
        try? FileManager.default.removeItem(at: Self.cacheURL(email))
        saveAccountList()
        bump()
    }

    private func saveAccountList() {
        UserDefaults.standard.set(accounts.map(\.email), forKey: "googleAccounts")
    }

    // MARK: Polling

    /// Starts the 30-second incremental sync loop (idempotent).
    func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.syncAll()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    func syncAll() async {
        guard !isSyncing else { return }
        isSyncing = true
        defer { isSyncing = false }
        for account in accounts {
            await sync(email: account.email)
        }
    }

    private func sync(email: String) async {
        do {
            try await refreshCalendarList(email)
            var changed = false
            for cal in caches[email]?.calendars ?? [] {
                changed = try await syncEvents(email, calendarId: cal.id) || changed
            }
            update(email) { $0.lastSync = Date(); $0.error = nil }
            if changed { Self.saveCache(caches[email]!, email); bump() }
        } catch {
            update(email) { $0.error = error.localizedDescription }
        }
    }

    private func refreshCalendarList(_ email: String) async throws {
        var all: [GoogleCalendarAPI.CalendarListEntry] = []
        var pageToken: String?
        repeat {
            var query = ["maxResults": "250"]
            if let pageToken { query["pageToken"] = pageToken }
            let data = try await request(email, "GET", "/users/me/calendarList", query: query)
            let page = try JSONDecoder().decode(GoogleCalendarAPI.CalendarListResponse.self, from: data)
            all += (page.items ?? []).filter { $0.deleted != true }
            pageToken = page.nextPageToken
        } while pageToken != nil
        all.sort { ($0.primary == true ? 0 : 1, $0.title) < ($1.primary == true ? 0 : 1, $1.title) }

        if caches[email]?.calendars != all {
            caches[email]?.calendars = all
            // Forget calendars that went away.
            let ids = Set(all.map(\.id))
            let kept = (caches[email]?.events ?? [:]).filter { ids.contains($0.key) }
            caches[email]?.events = kept
            update(email) { $0.calendars = all }
            bump()
        }
    }

    /// Returns true if anything changed.
    private func syncEvents(_ email: String, calendarId: String) async throws -> Bool {
        var changed = false
        var pageToken: String?
        var syncToken = caches[email]?.syncTokens[calendarId]
        var isFull = syncToken == nil
        var fresh: [String: GoogleCalendarAPI.Event] = [:]

        while true {
            var query: [String: String] = ["singleEvents": "true", "showDeleted": "true", "maxResults": "2500"]
            if let pageToken { query["pageToken"] = pageToken }
            if let syncToken {
                query["syncToken"] = syncToken
            } else {
                query["timeMin"] = ISODate.format(Date().addingTimeInterval(-pastWindow))
                query["timeMax"] = ISODate.format(Date().addingTimeInterval(futureWindow))
            }
            let data: Data
            do {
                data = try await request(email, "GET", "/calendars/\(Self.escape(calendarId))/events", query: query)
            } catch ServiceError.http(410, _) {
                // Sync token expired: start over with a full sync.
                caches[email]?.syncTokens[calendarId] = nil
                syncToken = nil
                isFull = true
                pageToken = nil
                fresh = [:]
                continue
            }
            let page = try JSONDecoder().decode(GoogleCalendarAPI.EventsResponse.self, from: data)
            if let reminders = page.defaultReminders { caches[email]?.defaultReminders[calendarId] = reminders }

            for event in page.items ?? [] {
                if isFull {
                    if event.status != "cancelled" { fresh[event.id] = event }
                } else if event.status == "cancelled" {
                    if caches[email]?.events[calendarId]?.removeValue(forKey: event.id) != nil { changed = true }
                } else if caches[email]?.events[calendarId]?[event.id] != event {
                    caches[email]?.events[calendarId, default: [:]][event.id] = event
                    changed = true
                }
            }
            if let next = page.nextPageToken {
                pageToken = next
                continue
            }
            if isFull {
                if caches[email]?.events[calendarId] != fresh { changed = true }
                caches[email]?.events[calendarId] = fresh
            }
            caches[email]?.syncTokens[calendarId] = page.nextSyncToken
            return changed
        }
    }

    // MARK: Reading

    struct CalendarRef: Hashable {
        var key: String          // "g|email|calendarId"
        var email: String
        var entry: GoogleCalendarAPI.CalendarListEntry
    }

    var calendars: [CalendarRef] {
        accounts.flatMap { acc in
            acc.calendars.map { CalendarRef(key: GoogleCalendarAPI.calendarKey(account: acc.email, calendarId: $0.id), email: acc.email, entry: $0) }
        }
    }

    func events(from start: Date, to end: Date) -> [ExternalEvent] {
        var out: [ExternalEvent] = []
        for (email, cache) in caches {
            for cal in cache.calendars {
                let reminders = cache.defaultReminders[cal.id] ?? []
                for event in (cache.events[cal.id] ?? [:]).values {
                    guard let ev = GoogleCalendarAPI.externalEvent(event, account: email, calendar: cal, defaultReminders: reminders),
                          ev.end > start, ev.start < end else { continue }
                    out.append(ev)
                }
            }
        }
        return out
    }

    // MARK: Writing

    private func location(_ event: ExternalEvent) throws -> (email: String, calendarId: String, eventId: String) {
        guard let ref = GoogleCalendarAPI.parseCalendarKey(event.calendarId), let id = event.providerEventId else {
            throw ServiceError.notConnected
        }
        return (ref.account, ref.calendarId, id)
    }

    private func dateTimeJSON(_ date: Date, allDay: Bool) -> [String: Any] {
        allDay ? ["date": LocalDate(date).description] : ["dateTime": ISODate.format(date), "timeZone": TimeZone.current.identifier]
    }

    func move(_ event: ExternalEvent, start: Date, end: Date, notify: Bool = true) async throws {
        let loc = try location(event)
        let body: [String: Any] = ["start": dateTimeJSON(start, allDay: event.isAllDay),
                                   "end": dateTimeJSON(end, allDay: event.isAllDay)]
        let data = try await request(loc.email, "PATCH", "/calendars/\(Self.escape(loc.calendarId))/events/\(Self.escape(loc.eventId))",
                                     query: ["sendUpdates": notify ? "all" : "none"], body: body)
        try store(data, email: loc.email, calendarId: loc.calendarId)
    }

    func delete(_ event: ExternalEvent, notify: Bool = true) async throws {
        let loc = try location(event)
        _ = try await request(loc.email, "DELETE", "/calendars/\(Self.escape(loc.calendarId))/events/\(Self.escape(loc.eventId))",
                              query: ["sendUpdates": notify ? "all" : "none"])
        caches[loc.email]?.events[loc.calendarId]?.removeValue(forKey: loc.eventId)
        Self.saveCache(caches[loc.email]!, loc.email)
        bump()
    }

    /// Shifts every occurrence of `event`'s series by `delta` and gives them `duration`.
    /// A move to another weekday also moves the repeat days (Mon/Wed → Tue/Thu).
    func moveSeries(of event: ExternalEvent, delta: TimeInterval, duration: TimeInterval, dayShift: Int, notify: Bool = true) async throws {
        let loc = try location(event)
        let master = caches[loc.email]?.events[loc.calendarId]?[loc.eventId]?.recurringEventId ?? loc.eventId
        let path = "/calendars/\(Self.escape(loc.calendarId))/events/\(Self.escape(master))"
        let data = try await request(loc.email, "GET", path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let startString = (json["start"] as? [String: Any])?["dateTime"] as? String,
              let start = ISODate.parse(startString) else { throw ServiceError.notConnected }
        let newStart = start.addingTimeInterval(delta)
        var body: [String: Any] = ["start": dateTimeJSON(newStart, allDay: false),
                                   "end": dateTimeJSON(newStart.addingTimeInterval(duration), allDay: false)]
        if dayShift != 0, let rules = json["recurrence"] as? [String] {
            body["recurrence"] = rules.map { RecurrenceDays.shiftByDay(in: $0, by: dayShift) }
        }
        _ = try await request(loc.email, "PATCH", path, query: ["sendUpdates": notify ? "all" : "none"], body: body)
        // Instances are re-expanded on the next sync.
        await sync(email: loc.email)
    }

    /// Saves panel edits. `wholeSeries` edits the repeating event itself instead of
    /// this occurrence. A calendar change uses Google's move call (same account only).
    func update(_ event: ExternalEvent, _ changes: EventChanges, wholeSeries: Bool, notify: Bool = true) async throws {
        let loc = try location(event)
        let master = caches[loc.email]?.events[loc.calendarId]?[loc.eventId]?.recurringEventId
        let eventId = wholeSeries ? (master ?? loc.eventId) : loc.eventId
        var body: [String: Any] = [:]
        if let t = changes.title { body["summary"] = t }
        if let l = changes.location { body["location"] = l }
        if let n = changes.notes { body["description"] = n }
        if let c = changes.colorId { body["colorId"] = c ?? NSNull() }
        if let busy = changes.isBusy { body["transparency"] = busy ? "opaque" : "transparent" }
        if let r = changes.reminders {
            body["reminders"] = ["useDefault": false,
                                 "overrides": r.map { ["method": "popup", "minutes": $0] }]
        }
        if let v = changes.visibility { body["visibility"] = v }
        if let allDay = changes.isAllDay {
            let day = LocalDate(event.start)
            if allDay {
                body["start"] = ["date": day.description]
                body["end"] = ["date": day.adding(days: 1).description]
            } else {
                let start = day.at(LocalTime(hour: 9, minute: 0))
                body["start"] = dateTimeJSON(start, allDay: false)
                body["end"] = dateTimeJSON(start.addingTimeInterval(3600), allDay: false)
            }
        }
        if !changes.addGuests.isEmpty || !changes.removeGuests.isEmpty {
            // Google replaces the whole guest list: start from the current one.
            let current = (caches[loc.email]?.events[loc.calendarId]?[loc.eventId]?.attendees ?? []).compactMap { p -> [String: Any]? in
                guard let email = p.email, !changes.removeGuests.contains(email) else { return nil }
                var a: [String: Any] = ["email": email]
                if let r = p.responseStatus { a["responseStatus"] = r }
                if let o = p.optional { a["optional"] = o }
                return a
            }
            let existing = Set(current.compactMap { $0["email"] as? String })
            body["attendees"] = current + changes.addGuests.filter { !existing.contains($0) }.map { ["email": $0] }
        }
        var query = ["sendUpdates": notify ? "all" : "none"]
        if changes.addMeet {
            body["conferenceData"] = ["createRequest": ["requestId": UUID().uuidString,
                                                        "conferenceSolutionKey": ["type": "hangoutsMeet"]]]
            query["conferenceDataVersion"] = "1"
        } else if changes.removeMeet {
            body["conferenceData"] = NSNull()
            query["conferenceDataVersion"] = "1"
        }
        var calendarId = loc.calendarId
        if !body.isEmpty {
            let data = try await request(loc.email, "PATCH", "/calendars/\(Self.escape(calendarId))/events/\(Self.escape(eventId))",
                                         query: query, body: body)
            if !wholeSeries { try store(data, email: loc.email, calendarId: calendarId) }
        }
        if let target = changes.calendarId, let ref = GoogleCalendarAPI.parseCalendarKey(target),
           ref.account == loc.email, ref.calendarId != calendarId {
            _ = try await request(loc.email, "POST", "/calendars/\(Self.escape(calendarId))/events/\(Self.escape(master ?? loc.eventId))/move",
                                  query: ["destination": ref.calendarId, "sendUpdates": notify ? "all" : "none"])
            calendarId = ref.calendarId
        }
        await sync(email: loc.email)
    }

    /// "This and following": ends the series just before `event`, and (when moving)
    /// starts a copy of it at `newStart`. `newStart == nil` deletes the rest.
    func editFollowing(of event: ExternalEvent, newStart: Date?, newEnd: Date?, dayShift: Int, notify: Bool = true) async throws {
        let loc = try location(event)
        let master = caches[loc.email]?.events[loc.calendarId]?[loc.eventId]?.recurringEventId ?? loc.eventId
        let path = "/calendars/\(Self.escape(loc.calendarId))/events/\(Self.escape(master))"
        let data = try await request(loc.email, "GET", path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let startString = (json["start"] as? [String: Any])?["dateTime"] as? String,
              let seriesStart = ISODate.parse(startString),
              let rules = json["recurrence"] as? [String] else { throw ServiceError.notConnected }
        // From the first occurrence, "this and following" is the whole series.
        if abs(seriesStart.timeIntervalSince(event.start)) < 60 {
            if let newStart, let newEnd {
                try await moveSeries(of: event, delta: newStart.timeIntervalSince(event.start),
                                     duration: newEnd.timeIntervalSince(newStart), dayShift: dayShift, notify: notify)
            } else {
                try await deleteSeries(of: event, notify: notify)
            }
            return
        }
        _ = try await request(loc.email, "PATCH", path, query: ["sendUpdates": notify ? "all" : "none"],
                              body: ["recurrence": rules.map { RecurrenceDays.ending($0, before: event.start) }])
        if let newStart, let newEnd {
            var body: [String: Any] = ["start": dateTimeJSON(newStart, allDay: false),
                                       "end": dateTimeJSON(newEnd, allDay: false),
                                       "recurrence": rules.map { RecurrenceDays.shiftByDay(in: $0, by: dayShift) }]
            for key in ["summary", "description", "location", "colorId", "reminders", "attendees", "visibility", "transparency"] {
                if let v = json[key] { body[key] = v }
            }
            _ = try await request(loc.email, "POST", "/calendars/\(Self.escape(loc.calendarId))/events",
                                  query: ["sendUpdates": notify ? "all" : "none"], body: body)
        }
        await sync(email: loc.email)
    }

    /// Deletes the whole recurring series `event` is an instance of.
    func deleteSeries(of event: ExternalEvent, notify: Bool = true) async throws {
        let loc = try location(event)
        let master = caches[loc.email]?.events[loc.calendarId]?[loc.eventId]?.recurringEventId ?? loc.eventId
        _ = try await request(loc.email, "DELETE", "/calendars/\(Self.escape(loc.calendarId))/events/\(Self.escape(master))",
                              query: ["sendUpdates": notify ? "all" : "none"])
        let remaining = caches[loc.email]?.events[loc.calendarId]?
            .filter { $0.key != master && $0.value.recurringEventId != master }
        caches[loc.email]?.events[loc.calendarId] = remaining
        if let cache = caches[loc.email] { Self.saveCache(cache, loc.email) }
        bump()
    }

    /// Deletes an event by id (undoing a paste).
    func delete(calendarKey: String, eventId: String) async throws {
        guard let ref = GoogleCalendarAPI.parseCalendarKey(calendarKey) else { throw ServiceError.notConnected }
        _ = try await request(ref.account, "DELETE", "/calendars/\(Self.escape(ref.calendarId))/events/\(Self.escape(eventId))")
        caches[ref.account]?.events[ref.calendarId]?.removeValue(forKey: eventId)
        if let cache = caches[ref.account] { Self.saveCache(cache, ref.account) }
        bump()
    }

    /// Yes / No / Maybe on an invitation.
    func respond(_ event: ExternalEvent, _ response: EventAttendee.Response) async throws {
        let loc = try location(event)
        guard let raw = caches[loc.email]?.events[loc.calendarId]?[loc.eventId] else { throw ServiceError.notConnected }
        let attendees: [[String: Any]] = (raw.attendees ?? []).map { p in
            var a: [String: Any] = [:]
            if let email = p.email { a["email"] = email }
            a["responseStatus"] = p.isSelf == true ? response.rawValue : (p.responseStatus ?? "needsAction")
            if let optional = p.optional { a["optional"] = optional }
            return a
        }
        let data = try await request(loc.email, "PATCH", "/calendars/\(Self.escape(loc.calendarId))/events/\(Self.escape(loc.eventId))",
                                     query: ["sendUpdates": "all"], body: ["attendees": attendees])
        try store(data, email: loc.email, calendarId: loc.calendarId)
    }

    @discardableResult
    func create(title: String, start: Date, end: Date, calendarKey: String,
                location: String? = nil, recurrence: [String]? = nil, copying template: ExternalEvent? = nil) async throws -> String {
        guard let ref = GoogleCalendarAPI.parseCalendarKey(calendarKey) else { throw ServiceError.notConnected }
        let allDay = template?.isAllDay ?? false
        var body: [String: Any] = ["summary": title]
        if allDay {
            body["start"] = ["date": LocalDate(start).description]
            body["end"] = ["date": LocalDate(end.addingTimeInterval(-1)).adding(days: 1).description]
        } else {
            body["start"] = dateTimeJSON(start, allDay: false)
            body["end"] = dateTimeJSON(end, allDay: false)
        }
        if let location { body["location"] = location }
        // A copy (paste, or undoing a delete) keeps the original's look and settings.
        if let t = template {
            if let notes = t.notes, !notes.isEmpty { body["description"] = notes }
            if let color = GoogleEventColors.id(forHex: t.eventColor) { body["colorId"] = color }
            body["transparency"] = t.isBusy ? "opaque" : "transparent"
            body["reminders"] = ["useDefault": false, "overrides": t.reminders.map { ["method": "popup", "minutes": $0] }]
        }
        if let recurrence { body["recurrence"] = recurrence }
        let data = try await request(ref.account, "POST", "/calendars/\(Self.escape(ref.calendarId))/events", body: body)
        try store(data, email: ref.account, calendarId: ref.calendarId)
        let created = try JSONDecoder().decode(GoogleCalendarAPI.Event.self, from: data)
        if recurrence != nil {
            // Recurring events expand into instances on the next incremental sync.
            Task { await self.sync(email: ref.account) }
        }
        return created.id
    }

    // MARK: Calendars

    func createCalendar(named name: String, email: String) async throws {
        _ = try await request(email, "POST", "/calendars",
                              body: ["summary": name, "timeZone": TimeZone.current.identifier])
        await sync(email: email)
    }

    /// Owned secondary calendars are deleted; anything else is removed from your list.
    func deleteCalendar(email: String, calendarId: String) async throws {
        let entry = caches[email]?.calendars.first { $0.id == calendarId }
        if entry?.accessRole == "owner" && entry?.primary != true {
            _ = try await request(email, "DELETE", "/calendars/\(Self.escape(calendarId))")
        } else {
            _ = try await request(email, "DELETE", "/users/me/calendarList/\(Self.escape(calendarId))")
        }
        caches[email]?.calendars.removeAll { $0.id == calendarId }
        caches[email]?.events[calendarId] = nil
        caches[email]?.syncTokens[calendarId] = nil
        update(email) { $0.calendars.removeAll { $0.id == calendarId } }
        if let cache = caches[email] { Self.saveCache(cache, email) }
        bump()
    }

    /// Caches the event Google returned from a write so the UI updates immediately.
    private func store(_ data: Data, email: String, calendarId: String) throws {
        let event = try JSONDecoder().decode(GoogleCalendarAPI.Event.self, from: data)
        if event.recurrence == nil {
            caches[email]?.events[calendarId, default: [:]][event.id] = event
            Self.saveCache(caches[email]!, email)
            bump()
        }
    }

    // MARK: HTTP

    private func accessToken(_ email: String) async throws -> String {
        if let t = accessTokens[email], t.expiresAt > Date() { return t.accessToken }
        guard let refresh = GoogleKeychain.load(email) else { throw ServiceError.notConnected }
        let t = try await auth.refresh(refreshToken: refresh)
        accessTokens[email] = t
        return t.accessToken
    }

    private func request(_ email: String, _ method: String, _ path: String,
                         query: [String: String] = [:], body: [String: Any]? = nil, retry: Bool = true) async throws -> Data {
        var components = URLComponents(string: "https://www.googleapis.com/calendar/v3")!
        components.percentEncodedPath += path
        if !query.isEmpty { components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await accessToken(email))", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401, retry {
            accessTokens[email] = nil
            return try await self.request(email, method, path, query: query, body: body, retry: false)
        }
        guard (200..<300).contains(status) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
                .flatMap { ($0["error"] as? [String: Any])?["message"] as? String } ?? "request failed"
            throw ServiceError.http(status, message)
        }
        return data
    }

    /// Calendar ids contain '@' and '#'; escape for a path segment.
    static func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~@")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // MARK: Cache files

    private func bump() {
        revision += 1
        onChange?()
    }

    private func update(_ email: String, _ change: (inout Account) -> Void) {
        guard let i = accounts.firstIndex(where: { $0.email == email }) else { return }
        change(&accounts[i])
    }

    private static func cacheURL(_ email: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let safe = email.replacingOccurrences(of: "/", with: "_")
        return base.appendingPathComponent("PersonalWorkspace/google-\(safe).json")
    }

    private static func loadCache(_ email: String) -> Cache? {
        guard let data = try? Data(contentsOf: cacheURL(email)) else { return nil }
        return try? JSONDecoder().decode(Cache.self, from: data)
    }

    private static func saveCache(_ cache: Cache, _ email: String) {
        let url = cacheURL(email)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(cache) { try? data.write(to: url, options: .atomic) }
    }
}
