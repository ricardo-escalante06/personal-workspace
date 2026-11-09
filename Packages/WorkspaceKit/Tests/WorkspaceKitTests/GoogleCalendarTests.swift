import Foundation
import Testing
@testable import WorkspaceKit

private let calendar = GoogleCalendarAPI.CalendarListEntry(
    id: "ricardo@hackberkeley.org", summary: "ricardo@hackberkeley.org", summaryOverride: nil,
    backgroundColor: "#5AA9E6", accessRole: "owner", primary: true, deleted: nil
)

private func decode(_ json: String) throws -> GoogleCalendarAPI.Event {
    try JSONDecoder().decode(GoogleCalendarAPI.Event.self, from: Data(json.utf8))
}

@Suite struct GoogleCalendarTests {
    @Test func invitationAwaitingReplyIsDashedWithParticipants() throws {
        // Like "Logs and Sticks": organized by someone else, 57 guests (one group), you said no.
        let e = try decode("""
        {"id":"abc_20261115T180000Z","status":"confirmed","summary":"Logs and Sticks",
         "location":"2401 Piedmont Ave, Berkeley, CA 94704, USA",
         "start":{"dateTime":"2026-11-15T10:00:00-08:00"},"end":{"dateTime":"2026-11-15T14:00:00-08:00"},
         "organizer":{"email":"charlie@hackberkeley.org","displayName":"Charlie Huang"},
         "attendees":[
           {"email":"charlie@hackberkeley.org","displayName":"Charlie Huang","organizer":true,"responseStatus":"accepted"},
           {"email":"team@hackberkeley.org","displayName":"Team","responseStatus":"needsAction","additionalGuests":55},
           {"email":"ricardo@hackberkeley.org","self":true,"responseStatus":"needsAction"}],
         "reminders":{"useDefault":true},"recurringEventId":"abc"}
        """)
        let ev = try #require(GoogleCalendarAPI.externalEvent(e, account: "ricardo@hackberkeley.org", calendar: calendar,
                                                               defaultReminders: [.init(method: "popup", minutes: 10)]))
        #expect(ev.title == "Logs and Sticks")
        #expect(ev.selfResponse == .needsAction)
        #expect(ev.isAwaitingResponse && ev.isTentative)   // drawn dashed
        #expect(ev.canRSVP)
        #expect(!ev.isWritable)                             // not the organizer
        #expect(ev.organizer?.displayName == "Charlie Huang")
        #expect(ev.attendees.count == 3)
        #expect(ev.attendees.contains { $0.isGroup })
        #expect(ev.reminders == [10])
        #expect(ev.isRecurring)
        #expect(ev.end.timeIntervalSince(ev.start) == 4 * 3600)
        #expect(ev.calendarId == "g|ricardo@hackberkeley.org|ricardo@hackberkeley.org")
    }

    @Test func acceptedInviteIsSolidAndOwnEventsAreEditable() throws {
        let accepted = try decode("""
        {"id":"x","summary":"Sync","start":{"dateTime":"2026-11-10T17:00:00Z"},"end":{"dateTime":"2026-11-10T18:00:00Z"},
         "organizer":{"email":"boss@x.com"},
         "attendees":[{"email":"boss@x.com","organizer":true,"responseStatus":"accepted"},
                      {"email":"me@x.com","self":true,"responseStatus":"accepted"}],
         "hangoutLink":"https://meet.google.com/abc-defg-hij"}
        """)
        let a = try #require(GoogleCalendarAPI.externalEvent(accepted, account: "me@x.com", calendar: calendar))
        #expect(!a.isTentative)
        #expect(a.conferenceURL?.host == "meet.google.com")
        #expect(a.conferenceName == "Google Meet")

        let mine = try decode("""
        {"id":"y","summary":"Lecture 10b","start":{"dateTime":"2026-11-09T13:00:00-08:00"},
         "end":{"dateTime":"2026-11-09T14:45:00-08:00"},"organizer":{"email":"me@x.com","self":true},
         "transparency":"transparent","colorId":"11"}
        """)
        let m = try #require(GoogleCalendarAPI.externalEvent(mine, account: "me@x.com", calendar: calendar))
        #expect(m.isWritable)
        #expect(m.selfResponse == nil && !m.canRSVP)
        #expect(!m.isBusy)
        #expect(m.eventColor == 0xD50000)
    }

    @Test func allDayAndCancelled() throws {
        let allDay = try decode("""
        {"id":"vd","summary":"Veterans Day","start":{"date":"2026-11-11"},"end":{"date":"2026-11-12"}}
        """)
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let v = try #require(GoogleCalendarAPI.externalEvent(allDay, account: "a", calendar: calendar, timeZone: la))
        #expect(v.isAllDay)
        #expect(LocalDate(v.start, in: la) == LocalDate(year: 2026, month: 11, day: 11))
        #expect(v.end.timeIntervalSince(v.start) == 86_400)

        let cancelled = try decode(#"{"id":"c","status":"cancelled"}"#)
        #expect(GoogleCalendarAPI.externalEvent(cancelled, account: "a", calendar: calendar) == nil)
    }

    @Test func calendarKeysAndByDay() {
        let key = GoogleCalendarAPI.calendarKey(account: "me@x.com", calendarId: "en.usa#holiday@group.v.calendar.google.com")
        let parsed = GoogleCalendarAPI.parseCalendarKey(key)
        #expect(parsed?.account == "me@x.com")
        #expect(parsed?.calendarId == "en.usa#holiday@group.v.calendar.google.com")
        #expect(GoogleCalendarAPI.byDay([6, 2, 4]) == "MO,WE,FR")
    }
}
