//
//  WorkingHoursTests.swift
//  CadenceCoreTests
//
//  Locks in the owner's actual week (SPEC §15) and the way rules become real time:
//
//    Tue–Thu  10:00–18:00  office (lunch 13:00–14:00 kept free)
//    Fri–Mon  10:00–16:00  catch-up + personal
//    daily    20:00–23:00  the evening block
//
//  These are the tests that would fail loudly if a default were ever changed by
//  accident — a scheduler that quietly plans work at 03:00 is worse than no scheduler.
//

import XCTest

#if canImport(CadenceCore)
@testable import CadenceCore
#else
@testable import Cadence
#endif

final class WorkingHoursTests: XCTestCase {

    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Africa/Addis_Ababa")!   // UTC+3, no DST
        calendar.firstWeekday = 2                                        // Monday first
        return calendar
    }()

    /// Sunday 4 October 2026 — a full week starts the next day.
    private func day(_ offset: Int) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 10
        components.day = 4 + offset
        components.hour = 0
        return calendar.date(from: components)!
    }

    private func week(of date: Date) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    // MARK: - The shape of the week

    func testDefaultWeekHasTheThreeWindowShapes() {
        let windows = WorkingHours.defaultWindows
        let shapes = Set(windows.map { "\($0.startMinutes)-\($0.endMinutes)" })

        XCTAssertEqual(windows.count, 3 * 2 + 4 * 1 + 7 * 1, "6 office + 4 catch-up + 7 evening windows")
        XCTAssertTrue(shapes.contains("600-780"), "10:00–13:00 office mornings")
        XCTAssertTrue(shapes.contains("840-1080"), "14:00–18:00 office afternoons")
        XCTAssertTrue(shapes.contains("600-960"), "10:00–16:00 Fri–Mon")
        XCTAssertTrue(shapes.contains("1200-1380"), "20:00–23:00 evenings")
        XCTAssertTrue(windows.allSatisfy(\.isValid))
    }

    func testOfficeDaysAreTuesdayWednesdayThursday() {
        let byWeekday = Dictionary(grouping: WorkingHours.defaultWindows, by: \.weekday)
        for weekday in [3, 4, 5] {
            let windows = (byWeekday[weekday] ?? []).sorted { $0.startMinutes < $1.startMinutes }
            // Two office windows (10:00–13:00, 14:00–18:00) plus the shared evening block.
            XCTAssertEqual(windows.map(\.startMinutes), [600, 840, 1200],
                           "Tue/Wed/Thu start at 10:00, 14:00 and the 20:00 evening block")
            XCTAssertEqual(windows.map(\.endMinutes), [780, 1080, 1380],
                           "…and run to 13:00, 18:00 and 23:00")
            XCTAssertEqual(windows.first?.startTimeLabel, RelativeDateFormatter.timeOfDay(minutesFromMidnight: 600))
        }
    }

    func testFridayToMondayIsCatchUpTime() {
        let byWeekday = Dictionary(grouping: WorkingHours.defaultWindows, by: \.weekday)
        for weekday in [6, 7, 1, 2] {   // Fri, Sat, Sun, Mon
            let windows = byWeekday[weekday] ?? []
            XCTAssertTrue(
                windows.contains { $0.startMinutes == 600 && $0.endMinutes == 960 },
                "weekday \(weekday) should have the 10:00–16:00 catch-up window"
            )
        }
    }

    func testEveryDayHasTheEveningBlock() {
        let byWeekday = Dictionary(grouping: WorkingHours.defaultWindows, by: \.weekday)
        for weekday in 1...7 {
            let evening = (byWeekday[weekday] ?? []).filter { $0.startMinutes >= 1200 }
            XCTAssertEqual(evening.count, 1, "weekday \(weekday) needs exactly one evening window")
            XCTAssertEqual(evening.first?.startMinutes, 20 * 60, "which starts at 20:00, matching 'anything after 8PM'")
            XCTAssertEqual(evening.first?.endMinutes, 23 * 60)
        }
    }

    // MARK: - Materialisation

    func testTuesdayMaterialisesThreeWindowsIncludingEvening() {
        // 6 October 2026 is a Tuesday.
        let windows = WorkingHours.windows(from: WorkingHours.defaultWindows, in: week(of: day(2)), calendar: calendar)

        XCTAssertEqual(windows.count, 3)
        let hours = windows.map { calendar.component(.hour, from: $0.start) }
        XCTAssertEqual(hours, [10, 14, 20])
        XCTAssertEqual(windows.map { Int($0.duration / 60) }, [180, 240, 180])
    }

    func testSaturdayMaterialisesCatchUpAndEvening() {
        let windows = WorkingHours.windows(from: WorkingHours.defaultWindows, in: week(of: day(6)), calendar: calendar)

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(calendar.component(.hour, from: windows[0].start), 10)
        XCTAssertEqual(Int(windows[0].duration / 60), 360, "six-hour catch-up window")
        XCTAssertEqual(calendar.component(.hour, from: windows[1].start), 20)
    }

    func testNoWorkIsEverPlannedOutsideTheWindows() {
        // A full week of planning, one very long task: every block must land inside a
        // declared window and never in the lunch hour or the small hours.
        var policy = SchedulingPolicy()
        policy.maxChunkMinutes = 120
        policy.maxChunksPerTask = 20
        policy.dailyAutoMinutesCap = 480

        let start = day(1)                       // Monday
        let range = DateInterval(start: start, end: day(8))
        let windows = WorkingHours.windows(from: WorkingHours.defaultWindows, in: range, calendar: calendar)

        let task = SchedulableTask(
            id: UUID(), title: "Week of work", estimateMinutes: 1800,
            deadline: nil, isHardDeadline: false, priority: .medium,
            createdAt: start, allowsSplitting: true, notBefore: nil,
            pinnedStart: nil, pinnedEnd: nil
        )

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = calendar.timeZone

        let plan = SchedulingEngine.plan(problem: ScheduleProblem(
            now: start, horizonEnd: range.end, workingWindows: windows,
            busy: [], tasks: [task], policy: policy
        ))

        XCTAssertFalse(plan.blocks.isEmpty)
        for block in plan.blocks {
            XCTAssertTrue(
                windows.contains { $0.contains(block.start) && block.end <= $0.end },
                "block \(block.start)–\(block.end) escaped the working windows"
            )
            let hour = utcCalendar.component(.hour, from: block.start)
            XCTAssertFalse(hour == 13 && utcCalendar.component(.weekday, from: block.start) == 3,
                           "13:00 on Tuesday is the lunch hour — nothing should be scheduled there")
        }
    }

    // MARK: - Human summary

    func testSummaryMentionsTheThreeShapes() throws {
        let summary = WorkingHours.summary(of: WorkingHours.defaultWindows)
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains("daily"), "the evening window applies to every day: \(summary)")
    }
}
