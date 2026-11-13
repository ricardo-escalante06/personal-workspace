import Foundation

/// Edits to a calendar event from the event panel. nil = unchanged.
public struct EventChanges: Sendable, Hashable {
    public var title: String?
    public var location: String?
    public var notes: String?
    /// Google event color id ("1"…"11"); `.some(nil)` = back to the calendar's color.
    public var colorId: String??
    public var isBusy: Bool?
    /// Minutes before the start.
    public var reminders: [Int]?
    /// Move to another calendar (same account).
    public var calendarId: String?
    /// All-day on/off (keeps the date; timed events come back as 9–10 AM).
    public var isAllDay: Bool?
    /// Google only: guests to invite / remove (by email), a Meet link, and visibility
    /// ("default", "public", "private").
    public var addGuests: [String] = []
    public var removeGuests: [String] = []
    public var addMeet = false
    /// Takes the Google Meet link off the event.
    public var removeMeet = false
    public var visibility: String?
    public init() {}

    public var isEmpty: Bool { self == EventChanges() }

    /// Changes guests would want to hear about (Google emails them). Color, alerts,
    /// busy/free, visibility and which of your calendars it's on are yours alone.
    public var concernsGuests: Bool {
        title != nil || location != nil || notes != nil || isAllDay != nil
            || !addGuests.isEmpty || !removeGuests.isEmpty || addMeet || removeMeet
    }
}

public enum GoogleEventColors {
    /// Google's names for its event colors, in its menu order.
    public static let all: [(id: String, name: String)] = [
        ("11", "Tomato"), ("4", "Flamingo"), ("6", "Tangerine"), ("5", "Banana"), ("2", "Sage"), ("10", "Basil"),
        ("7", "Peacock"), ("9", "Blueberry"), ("1", "Lavender"), ("3", "Grape"), ("8", "Graphite"),
    ]
    public static func hex(_ id: String) -> UInt32? { GoogleCalendarAPI.eventColors[id] }
    public static func id(forHex hex: UInt32?) -> String? {
        guard let hex else { return nil }
        return GoogleCalendarAPI.eventColors.first { $0.value == hex }?.key
    }
}
