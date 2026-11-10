import Foundation

/// Google Calendar API v3 payloads (only the fields we use) and conversion to
/// `ExternalEvent`. Pure data: no networking here, so it's unit-testable.
public enum GoogleCalendarAPI {
    public struct CalendarListResponse: Codable, Sendable {
        public var items: [CalendarListEntry]?
        public var nextPageToken: String?
    }

    public struct CalendarListEntry: Codable, Sendable, Hashable {
        public var id: String
        public var summary: String?
        public var summaryOverride: String?
        public var backgroundColor: String?
        /// owner · writer · reader · freeBusyReader
        public var accessRole: String?
        public var primary: Bool?
        public var deleted: Bool?

        public var title: String { summaryOverride ?? summary ?? id }
        public var isWritable: Bool { accessRole == "owner" || accessRole == "writer" }
    }

    public struct EventsResponse: Codable, Sendable {
        public var items: [Event]?
        public var nextPageToken: String?
        public var nextSyncToken: String?
        /// Calendar's default reminders, used when an event says useDefault.
        public var defaultReminders: [Reminder]?
    }

    public struct EventDateTime: Codable, Sendable, Hashable {
        public var date: String?        // all-day: "2026-11-10"
        public var dateTime: String?    // timed: RFC 3339
        public var timeZone: String?

        public init(date: String? = nil, dateTime: String? = nil, timeZone: String? = nil) {
            self.date = date; self.dateTime = dateTime; self.timeZone = timeZone
        }
    }

    public struct Person: Codable, Sendable, Hashable {
        public var email: String?
        public var displayName: String?
        /// JSON "self": this attendee is you.
        public var isSelf: Bool?
        public var organizer: Bool?
        public var optional: Bool?
        public var resource: Bool?
        public var responseStatus: String?
        /// Present on group attendees (mailing lists).
        public var additionalGuests: Int?

        enum CodingKeys: String, CodingKey {
            case email, displayName, organizer, optional, resource, responseStatus, additionalGuests
            case isSelf = "self"
        }
    }

    public struct Reminder: Codable, Sendable, Hashable {
        public var method: String?
        public var minutes: Int?
    }

    public struct Reminders: Codable, Sendable, Hashable {
        public var useDefault: Bool?
        public var overrides: [Reminder]?
    }

    public struct ConferenceData: Codable, Sendable, Hashable {
        public struct EntryPoint: Codable, Sendable, Hashable {
            public var entryPointType: String?
            public var uri: String?
        }
        public struct Solution: Codable, Sendable, Hashable {
            public var name: String?
        }
        public var entryPoints: [EntryPoint]?
        public var conferenceSolution: Solution?
    }

    public struct Event: Codable, Sendable, Hashable {
        public var id: String
        /// confirmed · tentative · cancelled
        public var status: String?
        public var summary: String?
        public var description: String?
        public var location: String?
        public var htmlLink: String?
        public var start: EventDateTime?
        public var end: EventDateTime?
        public var attendees: [Person]?
        public var organizer: Person?
        public var creator: Person?
        public var hangoutLink: String?
        public var conferenceData: ConferenceData?
        /// "transparent" = free; default is busy.
        public var transparency: String?
        public var colorId: String?
        public var recurringEventId: String?
        public var recurrence: [String]?
        public var reminders: Reminders?
        public var eventType: String?
    }

    /// Google's fixed event color palette (colorId → hex).
    public static let eventColors: [String: UInt32] = [
        "1": 0x7986CB, "2": 0x33B679, "3": 0x8E24AA, "4": 0xE67C73, "5": 0xF6BF26, "6": 0xF4511E,
        "7": 0x039BE5, "8": 0x616161, "9": 0x3F51B5, "10": 0x0B8043, "11": 0xD50000,
    ]

    /// Stable calendar id across both providers: "g|<account>|<google calendar id>".
    public static func calendarKey(account: String, calendarId: String) -> String {
        "g|\(account)|\(calendarId)"
    }

    public static func parseCalendarKey(_ key: String) -> (account: String, calendarId: String)? {
        let parts = key.split(separator: "|", maxSplits: 2).map(String.init)
        guard parts.count == 3, parts[0] == "g" else { return nil }
        return (parts[1], parts[2])
    }

    public static func hex(_ string: String?) -> UInt32? {
        guard var s = string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        if s.hasPrefix("#") { s.removeFirst() }
        return UInt32(s, radix: 16)
    }

    /// Converts an API event. Returns nil for cancelled events and ones without times.
    public static func externalEvent(
        _ e: Event,
        account: String,
        calendar: CalendarListEntry,
        defaultReminders: [Reminder] = [],
        timeZone: TimeZone = .current
    ) -> ExternalEvent? {
        guard e.status != "cancelled", let start = e.start, let end = e.end else { return nil }

        let isAllDay = start.date != nil
        let startDate: Date
        let endDate: Date
        if isAllDay {
            guard let s = start.date.flatMap(LocalDate.init(string:)),
                  let en = end.date.flatMap(LocalDate.init(string:)) else { return nil }
            startDate = s.startOfDay(in: timeZone)
            endDate = en.startOfDay(in: timeZone)   // Google's all-day end is exclusive
        } else {
            guard let s = start.dateTime.flatMap(ISODate.parse), let en = end.dateTime.flatMap(ISODate.parse) else { return nil }
            startDate = s
            endDate = en
        }

        let attendees: [EventAttendee] = (e.attendees ?? []).compactMap { p -> EventAttendee? in
            guard let email = p.email, p.resource != true else { return nil }
            return EventAttendee(
                email: email, name: p.displayName,
                response: EventAttendee.Response(rawValue: p.responseStatus ?? "") ?? .needsAction,
                isSelf: p.isSelf ?? false, isOrganizer: p.organizer ?? false,
                isOptional: p.optional ?? false, isGroup: (p.additionalGuests ?? 0) > 0
            )
        }
        let me = attendees.first { $0.isSelf }
        let organizer: EventAttendee? = e.organizer.flatMap { o -> EventAttendee? in
            guard let email = o.email else { return nil }
            return attendees.first { $0.email == email }
                ?? EventAttendee(email: email, name: o.displayName, response: .accepted,
                                 isSelf: o.isSelf ?? false, isOrganizer: true)
        }

        let video = e.conferenceData?.entryPoints?.first { $0.entryPointType == "video" }?.uri ?? e.hangoutLink
        let reminderMinutes: [Int] = {
            if e.reminders?.useDefault == true { return defaultReminders.compactMap(\.minutes) }
            return e.reminders?.overrides?.compactMap(\.minutes) ?? []
        }()

        var event = ExternalEvent(
            key: "google:\(e.id)",
            localId: e.id,
            calendarId: calendarKey(account: account, calendarId: calendar.id),
            calendarTitle: calendar.title,
            calendarColor: hex(calendar.backgroundColor) ?? 0x5AA9E6,
            title: e.summary?.isEmpty == false ? e.summary! : "(No title)",
            start: startDate,
            end: endDate,
            isAllDay: isAllDay,
            // You can edit if the calendar is writable and you're the organizer (or there are no guests).
            isWritable: calendar.isWritable && (organizer == nil || organizer?.isSelf == true || attendees.isEmpty),
            isTentative: false,
            location: e.location,
            notes: e.description
        )
        event.provider = .google
        event.providerEventId = e.id
        event.attendees = attendees
        event.organizer = organizer
        event.creatorEmail = e.creator?.email
        // Only an invitee has an RSVP of their own.
        event.selfResponse = (me != nil && organizer?.isSelf != true) ? me?.response : nil
        event.isTentative = event.isAwaitingResponse || e.status == "tentative"
        event.conferenceURL = video.flatMap(URL.init(string:))
        event.conferenceName = e.conferenceData?.conferenceSolution?.name ?? (e.hangoutLink != nil ? "Google Meet" : nil)
        event.htmlLink = e.htmlLink.flatMap(URL.init(string:))
        event.isBusy = e.transparency != "transparent"
        event.reminders = reminderMinutes.sorted()
        event.isRecurring = e.recurringEventId != nil || !(e.recurrence ?? []).isEmpty
        event.eventColor = e.colorId.flatMap { eventColors[$0] }
        return event
    }

    /// RFC 5545 weekday codes for weekly recurrence (1 = Sunday … 7 = Saturday).
    public static func byDay(_ weekdays: [Int]) -> String {
        let codes = [1: "SU", 2: "MO", 3: "TU", 4: "WE", 5: "TH", 6: "FR", 7: "SA"]
        return weekdays.sorted().compactMap { codes[$0] }.joined(separator: ",")
    }
}
