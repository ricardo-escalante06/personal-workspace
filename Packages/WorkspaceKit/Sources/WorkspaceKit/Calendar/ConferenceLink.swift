import Foundation

/// Custom meeting links (Zoom, Teams, anything) live in an event's location, the way
/// Google Calendar shows them; this recognizes them.
public enum ConferenceLink {
    /// The location as a link, when the whole location is one web address.
    public static func url(in location: String?) -> URL? {
        guard let text = location?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.contains(" "), let url = normalized(text) else { return nil }
        return url
    }

    /// "zoom.us/j/123" → "https://zoom.us/j/123"; nil for something that isn't a link.
    public static func normalized(_ text: String) -> URL? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        let withScheme = t.lowercased().hasPrefix("http://") || t.lowercased().hasPrefix("https://") ? t : "https://" + t
        guard let url = URL(string: withScheme), let host = url.host, host.contains(".") else { return nil }
        return url
    }

    public static func firstLine(of text: String?) -> String? {
        text?.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    /// The description without its first line (taking a link off).
    public static func droppingFirstLine(of text: String?) -> String {
        let lines = (text ?? "").split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        return lines.count > 1 ? String(lines[1]).trimmingCharacters(in: .newlines) : ""
    }

    /// A friendly name for the service behind a link.
    public static func name(for url: URL) -> String {
        let host = url.host?.lowercased() ?? ""
        if host.hasSuffix("zoom.us") { return "Zoom" }
        if host.contains("teams.microsoft") || host.contains("teams.live") { return "Microsoft Teams" }
        if host.hasSuffix("meet.google.com") { return "Google Meet" }
        if host.contains("webex") { return "Webex" }
        if host.hasSuffix("discord.gg") || host.hasSuffix("discord.com") { return "Discord" }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }
}
