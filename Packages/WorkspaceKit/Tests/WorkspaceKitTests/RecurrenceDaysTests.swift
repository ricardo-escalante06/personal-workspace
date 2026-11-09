import Foundation
import Testing
@testable import WorkspaceKit

@Suite struct RecurrenceDaysTests {
    @Test func shiftsWeekdaysAndRules() {
        #expect(RecurrenceDays.shift(7, by: 1) == 1)
        #expect(RecurrenceDays.shift(2, by: -1) == 1)
        #expect(RecurrenceDays.shiftByDay(in: "RRULE:FREQ=WEEKLY;BYDAY=MO,WE,FR;UNTIL=20261213T000000Z", by: 1)
                == "RRULE:FREQ=WEEKLY;BYDAY=TU,TH,SA;UNTIL=20261213T000000Z")
        #expect(RecurrenceDays.shiftByDay(in: "EXDATE:20261127", by: 1) == "EXDATE:20261127")
        #expect(RecurrenceDays.shiftByDay(in: "RRULE:FREQ=MONTHLY;BYDAY=1SU", by: -1) == "RRULE:FREQ=MONTHLY;BYDAY=1SA")
    }

    @Test func endingBeforeReplacesUntilAndCount() {
        let d = ISODate.parse("2026-11-16T18:00:00Z")!
        #expect(RecurrenceDays.ending("RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=10", before: d)
                == "RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261116T175959Z")
    }
}
