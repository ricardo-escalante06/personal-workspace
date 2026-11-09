import Foundation

/// Someone invited to an event.
public struct EventAttendee: Sendable, Hashable, Codable {
    public enum Response: String, Sendable, Hashable, Codable {
        case needsAction, accepted, declined, tentative
    }
    public var email: String
    public var name: String?
    public var response: Response
    public var isSelf: Bool
    public var isOrganizer: Bool
    public var isOptional: Bool
    /// A group/mailing list counts as one row with many members.
    public var isGroup: Bool

    public init(email: String, name: String? = nil, response: Response, isSelf: Bool = false,
                isOrganizer: Bool = false, isOptional: Bool = false, isGroup: Bool = false) {
        self.email = email; self.name = name; self.response = response; self.isSelf = isSelf
        self.isOrganizer = isOrganizer; self.isOptional = isOptional; self.isGroup = isGroup
    }

    public var displayName: String { name?.isEmpty == false ? name! : email }
}

/// Where an event comes from: Google's API directly, or the system calendar (iCloud, etc.).
public enum EventProvider: String, Sendable, Hashable, Codable {
    case google, system
}

/// An event from Google Calendar (via its API) or the system calendar (EventKit).
/// WorkspaceKit never imports EventKit or talks to Google; the app's adapters fill this in.
public struct ExternalEvent: Identifiable, Sendable, Hashable {
    /// Stable across devices: calendarItemExternalIdentifier (+ occurrence start for recurring events).
    public var key: String
    /// Device-local EventKit id, used to edit the event.
    public var localId: String
    public var calendarId: String
    public var calendarTitle: String
    /// Calendar color as 0xRRGGBB.
    public var calendarColor: UInt32
    public var title: String
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var isWritable: Bool
    /// Tentative / cancelled: drawn dashed.
    public var isTentative: Bool
    public var location: String?
    public var notes: String?

    // Rich details (Google provides all of these; the system calendar only some).
    public var provider: EventProvider = .system
    /// Provider's own event id (Google event id, or EventKit identifier).
    public var providerEventId: String?
    public var attendees: [EventAttendee] = []
    public var organizer: EventAttendee?
    public var creatorEmail: String?
    /// Your own RSVP, when you're an invitee.
    public var selfResponse: EventAttendee.Response?
    public var conferenceURL: URL?
    public var conferenceName: String?
    public var htmlLink: URL?
    /// "Busy" vs "Free" (transparency).
    public var isBusy = true
    /// Reminder offsets in minutes before start.
    public var reminders: [Int] = []
    public var isRecurring = false
    /// Google's per-event color (overrides the calendar color), 0xRRGGBB.
    public var eventColor: UInt32?

    public var id: String { key }

    /// You're invited and haven't said yes yet: drawn dashed (like Notion Calendar).
    public var isAwaitingResponse: Bool {
        selfResponse == .needsAction || selfResponse == .tentative
    }
    public var isDeclined: Bool { selfResponse == .declined }
    /// You can RSVP: you're an attendee but not the organizer.
    public var canRSVP: Bool { selfResponse != nil && organizer?.isSelf != true }

    public init(key: String, localId: String, calendarId: String, calendarTitle: String, calendarColor: UInt32,
                title: String, start: Date, end: Date, isAllDay: Bool, isWritable: Bool,
                isTentative: Bool = false, location: String? = nil, notes: String? = nil) {
        self.key = key; self.localId = localId; self.calendarId = calendarId; self.calendarTitle = calendarTitle
        self.calendarColor = calendarColor; self.title = title; self.start = start; self.end = end
        self.isAllDay = isAllDay; self.isWritable = isWritable; self.isTentative = isTentative
        self.location = location; self.notes = notes
    }
}

/// Anything drawn on the calendar: a task's work block, a task deadline, or an external event.
public struct CalendarItem: Identifiable, Sendable, Equatable {
    public enum Source: Sendable, Equatable {
        case block(taskId: UUID, blockId: UUID)
        case deadline(taskId: UUID)
        case event(ExternalEvent)
    }

    public var source: Source
    public var title: String
    public var start: Date
    public var end: Date
    /// All-day row: date-only deadlines, timed deadlines (as markers), all-day events.
    public var isAllDay: Bool
    /// Container the item belongs to (task's container, or the event's mapped container).
    public var containerId: UUID?
    public var isDone: Bool
    public var isTentative: Bool
    /// Blocks are always editable; events only on writable calendars; deadlines move by date.
    public var isEditable: Bool
    /// Time shown on deadline markers ("11:59 PM").
    public var dueTime: LocalTime?
    /// The task's tag, for blocks and deadlines.
    public var categoryId: UUID? = nil

    public var id: String {
        switch source {
        case .block(_, let blockId): "block-\(blockId)"
        case .deadline(let taskId): "due-\(taskId)"
        case .event(let e): "event-\(e.key)"
        }
    }

    public var taskId: UUID? {
        switch source {
        case .block(let t, _), .deadline(let t): t
        case .event: nil
        }
    }

    public var event: ExternalEvent? {
        if case .event(let e) = source { return e }
        return nil
    }
}

/// A timed item placed in a day column: which sub-column it occupies and how many
/// sub-columns its overlap cluster has. Overlapping items share the width; they
/// never hide each other (DESIGN.md §3.3).
public struct PlacedItem: Identifiable, Sendable, Equatable {
    public var item: CalendarItem
    public var column: Int
    public var columnCount: Int
    /// Clipped to the day being drawn.
    public var start: Date
    public var end: Date
    public var id: String { item.id }
}

public enum TimeGridLayout {
    /// Lays out the timed items that intersect [dayStart, dayEnd).
    /// Classic interval-graph packing: items are grouped into clusters of transitive
    /// overlap; each item takes the first free sub-column; a cluster's width is its
    /// maximum column count.
    public static func layout(_ items: [CalendarItem], dayStart: Date, dayEnd: Date,
                              minimumDuration: TimeInterval = 15 * 60) -> [PlacedItem] {
        let timed = items
            .filter { !$0.isAllDay && $0.end > dayStart && $0.start < dayEnd }
            .map { item -> (CalendarItem, Date, Date) in
                let s = max(item.start, dayStart)
                // Very short items still get a readable height.
                let e = max(min(item.end, dayEnd), s.addingTimeInterval(minimumDuration))
                return (item, s, e)
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.2 != b.2 { return a.2 > b.2 }      // longer first
                return a.0.id < b.0.id                   // stable
            }

        var result: [PlacedItem] = []
        var cluster: [PlacedItem] = []
        var columnEnds: [Date] = []
        var clusterEnd = Date.distantPast

        func flush() {
            let count = max(columnEnds.count, 1)
            result += cluster.map { var p = $0; p.columnCount = count; return p }
            cluster = []
            columnEnds = []
        }

        for (item, s, e) in timed {
            if s >= clusterEnd, !cluster.isEmpty { flush() }
            let column = columnEnds.firstIndex { $0 <= s } ?? columnEnds.count
            if column == columnEnds.count { columnEnds.append(e) } else { columnEnds[column] = e }
            cluster.append(PlacedItem(item: item, column: column, columnCount: 1, start: s, end: e))
            clusterEnd = max(clusterEnd, e)
        }
        flush()
        return result
    }
}
