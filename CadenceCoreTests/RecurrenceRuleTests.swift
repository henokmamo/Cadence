//
//  RecurrenceRuleTests.swift
//  CadenceCoreTests
//

import XCTest

// Compiles in two worlds: as the standalone CadenceCore package (Linux/macOS CI,
// `swift test`) and inside the Xcode app target, where the same files are compiled
// into the `Cadence` module.
#if canImport(CadenceCore)
@testable import CadenceCore
#else
@testable import Cadence
#endif

final class RecurrenceRuleTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9, _ minute: Int = 0) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    // MARK: - Daily / monthly / yearly

    func testDailyNextOccurrenceKeepsTimeOfDay() throws {
        let start = date(2026, 5, 4, 8, 30)
        let next = try XCTUnwrap(RecurrenceRule.nextOccurrence(
            after: start, frequency: .daily, interval: 1, weekdayMask: 0, endDate: nil, calendar: calendar
        ))
        XCTAssertEqual(next, date(2026, 5, 5, 8, 30))
    }

    func testMonthlyNextOccurrence() throws {
        let start = date(2026, 1, 31, 10, 0)
        let next = try XCTUnwrap(RecurrenceRule.nextOccurrence(
            after: start, frequency: .monthly, interval: 1, weekdayMask: 0, endDate: nil, calendar: calendar
        ))
        // Calendar arithmetic clamps to the last valid day of the shorter month.
        XCTAssertEqual(calendar.component(.month, from: next), 2)
        XCTAssertEqual(calendar.component(.hour, from: next), 10)
    }

    func testSeriesEndDateStopsRecurrence() {
        let start = date(2026, 5, 4)
        let end = date(2026, 5, 6)
        let next = RecurrenceRule.nextOccurrence(
            after: start, frequency: .daily, interval: 1, weekdayMask: 0, endDate: end, calendar: calendar
        )
        XCTAssertNotNil(next, "5 May is still inside the series")
        let beyond = RecurrenceRule.nextOccurrence(
            after: date(2026, 5, 6), frequency: .daily, interval: 1, weekdayMask: 0, endDate: end, calendar: calendar
        )
        XCTAssertNil(beyond, "Once the series has ended there is no next occurrence")
    }

    // MARK: - Weekly with weekday masks

    func testWeeklyOnSpecificWeekdaysJumpsToTheNextSelectedDay() throws {
        // Monday 4 May 2026, repeat on Mondays (0 = Sunday ⇒ Monday = 1) and Fridays (= 5).
        let mask = RecurrenceRule.mask(fromIndices: [1, 5])
        let next = try XCTUnwrap(RecurrenceRule.nextOccurrence(
            after: date(2026, 5, 4, 7, 0),
            frequency: .weekly, interval: 1, weekdayMask: mask, endDate: nil, calendar: calendar
        ))
        XCTAssertEqual(next, date(2026, 5, 8, 7, 0), "Friday is the next selected weekday")

        let after = try XCTUnwrap(RecurrenceRule.nextOccurrence(
            after: date(2026, 5, 8, 7, 0),
            frequency: .weekly, interval: 1, weekdayMask: mask, endDate: nil, calendar: calendar
        ))
        XCTAssertEqual(after, date(2026, 5, 11, 7, 0), "…and it rolls back round to Monday")
    }

    func testEveryOtherWeekSkipsAWeek() throws {
        let mask = RecurrenceRule.mask(fromIndices: [1])   // Mondays
        let next = try XCTUnwrap(RecurrenceRule.nextOccurrence(
            after: date(2026, 5, 4),
            frequency: .weekly, interval: 2, weekdayMask: mask, endDate: nil, calendar: calendar
        ))
        XCTAssertEqual(next, date(2026, 5, 18), "With interval 2 the following Monday is skipped")
    }

    func testWeekdayMaskRoundTrips() {
        let indices: Set<Int> = [0, 2, 4, 6]
        let mask = RecurrenceRule.mask(fromIndices: indices)
        XCTAssertEqual(RecurrenceRule.weekdayIndices(from: mask), indices)
    }

}
