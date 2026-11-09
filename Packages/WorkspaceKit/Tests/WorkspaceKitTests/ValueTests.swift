import Foundation
import Testing
@testable import WorkspaceKit

@Suite struct RankTests {
    @Test func betweenIsStrictlyOrdered() {
        #expect(Rank.between(nil, nil) == "V")
        let pairs: [(String?, String?)] = [(nil, "1"), ("0V", "1"), ("V", nil), ("V", "W"), ("a", "a1"), ("Az", "B")]
        for (a, b) in pairs {
            let r = Rank.between(a, b)
            if let a { #expect(a < r, "\(a) < \(r)") }
            if let b { #expect(r < b, "\(r) < \(b)") }
            #expect(r.last != "0")
        }
    }

    @Test func repeatedInsertsStayOrdered() {
        // Always insert at the front, then always between the first two.
        var ranks = [Rank.initial]
        for _ in 0..<200 { ranks.insert(Rank.between(nil, ranks[0]), at: 0) }
        for _ in 0..<200 { ranks.insert(Rank.between(ranks[0], ranks[1]), at: 1) }
        #expect(ranks == ranks.sorted())
        #expect(Set(ranks).count == ranks.count)
    }

    @Test func sequenceIncreases() {
        let s = Rank.sequence(count: 50)
        #expect(s == s.sorted())
    }
}

@Suite struct DateValueTests {
    @Test func parsesPostgresTimestamps() throws {
        let base = try #require(ISODate.parse("2026-11-08T23:24:00Z"))
        #expect(ISODate.parse("2026-11-08T23:24:00.123456+00:00")!.timeIntervalSince(base) == 0.123456 || abs(ISODate.parse("2026-11-08T23:24:00.123456+00:00")!.timeIntervalSince(base) - 0.123456) < 1e-6)
        #expect(ISODate.parse("2026-11-08 15:24:00-08:00") == base)
        #expect(ISODate.parse("2026-11-09T07:24:00+08") == base)
        #expect(ISODate.parse("not a date") == nil)
    }

    @Test func formatRoundTrips() throws {
        let d = Date(timeIntervalSince1970: 1_800_000_000.25)
        let parsed = try #require(ISODate.parse(ISODate.format(d)))
        #expect(abs(parsed.timeIntervalSince(d)) < 0.001)
    }

    @Test func localDateIgnoresTimeZones() {
        let date = LocalDate(year: 2026, month: 11, day: 13)
        #expect(date.description == "2026-11-13")
        #expect(LocalDate(string: "2026-11-13") == date)
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let la = TimeZone(identifier: "America/Los_Angeles")!
        #expect(LocalDate(date.startOfDay(in: tokyo), in: tokyo) == date)
        #expect(LocalDate(date.startOfDay(in: la), in: la) == date)
        #expect(date.adding(days: 20) == LocalDate(year: 2026, month: 12, day: 3))
    }

    @Test func localTimeParses() {
        #expect(LocalTime(string: "23:59:00") == LocalTime(hour: 23, minute: 59))
        #expect(LocalTime(string: "07:05") == LocalTime(hour: 7, minute: 5))
        #expect(LocalTime(string: "25:00") == nil)
    }
}
