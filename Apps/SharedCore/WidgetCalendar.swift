import Foundation

/// The next two days of the calendar (events, work blocks, timed deadlines), saved by
/// the app for the Calendar widget. Google events live in the app's own cache, so the
/// widget can't fetch them itself.
struct WidgetCalendarItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case event, block, deadline }
    var id: String
    var kind: Kind
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    /// A container color name ("steel"), or nil to use `hex`.
    var colorName: String?
    var hex: UInt32
    var location: String?
    var isDone: Bool
}

enum WidgetCalendarFile {
    static var url: URL { AppPaths.databaseURL.deletingLastPathComponent().appendingPathComponent("widget-calendar.json") }

    static func write(_ items: [WidgetCalendarItem]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try? encoder.encode(items).write(to: url, options: .atomic)
    }

    static func read() -> [WidgetCalendarItem] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode([WidgetCalendarItem].self, from: $0) } ?? []
    }
}
