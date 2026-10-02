//
//  SchedulingEngineTests.swift
//  CadenceTests
//
//  The engine is pure value-in/value-out, so these tests need no database, no
//  simulator state and no UI. They are the contract the rest of the app relies on:
//  if these pass, "Reschedule" cannot silently lose work.
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

final class SchedulingEngineTests: XCTestCase {

    // MARK: - Fixtures

    /// UTC calendar so the assertions don't depend on the machine's timezone.
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// Monday 2026-05-04 09:00 UTC — the anchor for nearly every test.
    private func monday(hour: Int = 9, minute: Int = 0, dayOffset: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 5
        components.day = 4 + dayOffset
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func workingDays(_ days: Int, startHour: Int = 9, endHour: Int = 17) -> [DateInterval] {
        (0..<days).compactMap { offset in
            let start = monday(hour: startHour, dayOffset: offset)
            guard let end = calendar.date(byAdding: .hour, value: endHour - startHour, to: start) else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    private func task(
        _ title: String,
        minutes: Int,
        priority: TaskPriority = .none,
        deadline: Date? = nil,
        hardDeadline: Bool = false,
        allowsSplitting: Bool = true,
        notBefore: Date? = nil,
        pinnedStart: Date? = nil,
        pinnedEnd: Date? = nil,
        createdOffset: TimeInterval = 0
    ) -> SchedulableTask {
        SchedulableTask(
            id: UUID(),
            title: title,
            estimateMinutes: minutes,
            deadline: deadline,
            isHardDeadline: hardDeadline,
            priority: priority,
            createdAt: monday().addingTimeInterval(createdOffset),
            allowsSplitting: allowsSplitting,
            notBefore: notBefore,
            pinnedStart: pinnedStart,
            pinnedEnd: pinnedEnd
        )
    }

    private func problem(
        tasks: [SchedulableTask],
        windows: [DateInterval],
        busy: [BusyInterval] = [],
        policy: SchedulingPolicy = .default,
        horizonDays: Int = 7
    ) -> ScheduleProblem {
        ScheduleProblem(
            now: monday(),
            horizonEnd: monday(dayOffset: horizonDays),
            workingWindows: windows,
            busy: busy,
            tasks: tasks,
            policy: policy
        )
    }

    private func policy(
        buffer: Int = 10,
        minChunk: Int = 15,
        maxChunk: Int = 90,
        maxChunks: Int = 3,
        dailyCap: Int = 240,
        edf: Bool = true
    ) -> SchedulingPolicy {
        var policy = SchedulingPolicy()
        policy.bufferMinutes = buffer
        policy.minChunkMinutes = minChunk
        policy.maxChunkMinutes = maxChunk
        policy.maxChunksPerTask = maxChunks
        policy.dailyAutoMinutesCap = dailyCap
        policy.edfEnabled = edf
        return policy
    }

    // MARK: - 1. Simple fit

    func testSimpleFitLandsInTheEarliestGap() throws {
        let plan = SchedulingEngine.plan(problem: problem(
            tasks: [task("Write spec", minutes: 60)],
            windows: workingDays(1)
        ))

        XCTAssertEqual(plan.blocks.count, 1)
        let block = try XCTUnwrap(plan.blocks.first)
        XCTAssertEqual(block.start, monday(hour: 9))
        XCTAssertEqual(block.durationMinutes, 60)
        XCTAssertEqual(plan.reports.first?.status, .scheduled)
    }

    // MARK: - 2. Deadlines beat priority

    func testDeadlineOutranksHigherPriority() {
        let urgentButUndated = task("Polish the deck", minutes: 60, priority: .high, createdOffset: -3600)
        let dueTomorrow = task(
            "File the report", minutes: 60, priority: .low,
            deadline: monday(hour: 23, dayOffset: 1), hardDeadline: true, createdOffset: 0
        )

        let plan = SchedulingEngine.plan(problem: problem(
            tasks: [urgentButUndated, dueTomorrow],
            windows: workingDays(2)
        ))

        let due = plan.blocks.first { $0.taskID == dueTomorrow.id }
        let urgent = plan.blocks.first { $0.taskID == urgentButUndated.id }
        XCTAssertEqual(due?.start, monday(hour: 9), "The dated task should get the earliest slot")
        XCTAssertEqual(urgent?.start, monday(hour: 10, minute: 10), "…and the undated one waits its turn")
    }

    func testPriorityOrderingWhenEdfDisabled() {
        let high = task("Important", minutes: 60, priority: .high, createdOffset: -3600)
        let low = task("Trivial", minutes: 60, priority: .low, createdOffset: 0)

        let plan = SchedulingEngine.plan(problem: problem(
            tasks: [low, high],
            windows: workingDays(1),
            policy: policy(edf: false)
        ))

        let highBlock = plan.blocks.first { $0.taskID == high.id }
        XCTAssertEqual(highBlock?.start, monday(hour: 9))
    }

    // MARK: - 3. Buffers

    func testBufferIsKeptBetweenBlocks() throws {
        let first = task("First", minutes: 60, createdOffset: -7200)
        let second = task("Second", minutes: 60, createdOffset: -3600)

        let plan = SchedulingEngine.plan(problem: problem(
            tasks: [first, second],
            windows: workingDays(1)
        ))

        let a = try XCTUnwrap(plan.blocks.first { $0.taskID == first.id })
        let b = try XCTUnwrap(plan.blocks.first { $0.taskID == second.id })
        XCTAssertEqual(b.start.timeIntervalSince(a.end), 10 * 60)
    }

    // MARK: - 4. Splitting

    func testLongTaskIsSplitAcrossDays() {
        let long = task("Strategy memo", minutes: 360, priority: .high)
        let plan = SchedulingEngine.plan(problem: problem(
            tasks: [long],
            windows: workingDays(4),
            policy: policy(maxChunk: 90, maxChunks: 4, dailyCap: 90)
        ))

        let blocks = plan.blocks.filter { $0.taskID == long.id }
        XCTAssertEqual(blocks.count, 4, "360 minutes at 90 per block = 4 blocks")
        XCTAssertEqual(blocks.reduce(0) { $0 + $1.durationMinutes }, 360, "No minutes may be lost when splitting")
        XCTAssertTrue(blocks.allSatisfy { $0.durationMinutes <= 90 })

        let distinctDays = Set(blocks.map { calendar.startOfDay(for: $0.start) })
        XCTAssertEqual(distinctDays.count, 4, "Split work should be spread over separate days")
        XCTAssertEqual(plan.reports.first?.status, .scheduled)
    }

    func testNonSplittableTaskTakesOneContiguousSlot() throws {
        let call = task("Call accountant", minutes: 60, allowsSplitting: false)
        let busy = [BusyInterval(start: monday(hour: 9, minute: 30), end: monday(hour: 11))]

        let plan = SchedulingEngine.plan(problem: problem(
            tasks: [call],
            windows: workingDays(1),
            busy: busy
        ))

        XCTAssertEqual(plan.blocks.count, 1)
        let block = try XCTUnwrap(plan.blocks.first)
        XCTAssertEqual(block.durationMinutes, 60)
        XCTAssertEqual(block.start, monday(hour: 11), "Must skip the 30-minute stub before the meeting")
    }

    // MARK: - 5. Busy time is never violated

    func testBlocksNeverOverlapBusyTime() {
        let meeting = BusyInterval(start: monday(hour: 10), end: monday(hour: 12), label: "Standup")
        let splittable = task("Refactor", minutes: 120)

        let plan = SchedulingEngine.plan(problem: problem(
            tasks: [splittable],
            windows: workingDays(1),
            busy: [meeting]
        ))

        for block in plan.blocks {
            XCTAssertFalse(
                block.start < meeting.end && meeting.start < block.end,
                "Block \(block.start)–\(block.end) overlaps the imported event"
            )
        }
        XCTAssertEqual(plan.blocks.reduce(0) { $0 + $1.durationMinutes }, 120)
    }

    // MARK: - 6. Daily cap

    func testDailyCapSpreadsWorkOverSeveralDays() {
        let tasks = (0..<10).map { index in
            task("Task \(index)", minutes: 60, createdOffset: TimeInterval(index))
        }

        let plan = SchedulingEngine.plan(problem: problem(
            tasks: tasks,
            windows: workingDays(3),
            policy: policy(dailyCap: 240)
        ))

        let minutesPerDay = Dictionary(grouping: plan.blocks) { calendar.startOfDay(for: $0.start) }
            .mapValues { $0.reduce(0) { $0 + $1.durationMinutes } }

        XCTAssertEqual(minutesPerDay.count, 3, "10 hours of work cannot fit in one capped day")
        let mondayKey = calendar.startOfDay(for: monday())
        XCTAssertEqual(minutesPerDay[mondayKey], 240, "Day one stops at the cap")
        XCTAssertEqual(plan.blocks.reduce(0) { $0 + $1.durationMinutes }, 600)
    }

    func testDailyCapIsSoftRatherThanLosingWork() {
        // Only one day of working hours exists, so the cap has to give way.
        let tasks = (0..<6).map { index in
            task("Extra \(index)", minutes: 60, createdOffset: TimeInterval(index))
        }

        let plan = SchedulingEngine.plan(problem: problem(
            tasks: tasks,
            windows: workingDays(1),
            policy: policy(dailyCap: 120)
        ))

        XCTAssertEqual(plan.blocks.reduce(0) { $0 + $1.durationMinutes }, 360)
        XCTAssertTrue(
            plan.reports.contains { $0.reason.contains("daily cap relaxed") },
            "Relaxing a rule must be reported, never silent"
        )
    }

    // MARK: - 7. Pins are sacred

    func testPinnedBlocksAreReportedAndNeverMoved() {
        let pinnedStart = monday(hour: 14)
        let pinnedEnd = monday(hour: 15)
        let pinned = task("Dentist", minutes: 60, pinnedStart: pinnedStart, pinnedEnd: pinnedEnd)
        let flexible = task("Report", minutes: 120)

        let plan = SchedulingEngine.plan(problem: problem(
            tasks: [pinned, flexible],
            windows: workingDays(1),
            busy: [BusyInterval(start: pinnedStart, end: pinnedEnd, label: "Dentist")]
        ))

        let pinnedBlock = plan.blocks.first { $0.taskID == pinned.id }
        XCTAssertEqual(pinnedBlock?.start, pinnedStart)
        XCTAssertEqual(pinnedBlock?.end, pinnedEnd)
        XCTAssertTrue(pinnedBlock?.isPinned == true)
        XCTAssertFalse(pinnedBlock?.isNew == true, "A pin is not something the engine created")

        for block in plan.blocks where block.taskID == flexible.id {
            XCTAssertFalse(block.start < pinnedEnd && pinnedStart < block.end, "Must plan around the pin")
        }
    }

    // MARK: - 8. Honest failures

    func testUnschedulableTaskReportsShortfallAndReason() throws {
        let impossible = task("Write book", minutes: 600)
        let plan = SchedulingEngine.plan(problem: problem(
            tasks: [impossible],
            windows: workingDays(1),
            policy: policy(maxChunk: 90, maxChunks: 2)
        ))

        let report = try XCTUnwrap(plan.report(for: impossible.id))
        XCTAssertEqual(report.placedMinutes, 180, "Two 90-minute chunks is the configured ceiling")
        XCTAssertEqual(report.status, .partial(remainingMinutes: 600 - report.placedMinutes))
        XCTAssertEqual(report.shortfallMinutes, 600 - report.placedMinutes)
        XCTAssertFalse(report.reason.isEmpty)
    }

    func testNoWorkingHoursMeansNoPlanAndAClearReason() throws {
        let plan = SchedulingEngine.plan(problem: problem(
            tasks: [task("Anything", minutes: 30)],
            windows: []
        ))

        XCTAssertTrue(plan.blocks.isEmpty)
        let report = try XCTUnwrap(plan.reports.first)
        XCTAssertFalse(report.status.isFullyPlaced)
        XCTAssertTrue(report.reason.contains("No open working time"))
    }

    func testNotBeforeIsRespected() throws {
        let later = task("Tomorrow-ish", minutes: 60, notBefore: monday(hour: 13))
        let plan = SchedulingEngine.plan(problem: problem(tasks: [later], windows: workingDays(1)))

        let block = try XCTUnwrap(plan.blocks.first)
        XCTAssertEqual(block.start, monday(hour: 13))
    }

    func testTasksBeyondHorizonAreNotSilentlyDropped() {
        let future = task("Next month", minutes: 60, notBefore: monday(dayOffset: 30))
        let plan = SchedulingEngine.plan(problem: problem(
            tasks: [future],
            windows: workingDays(7),
            horizonDays: 7
        ))

        XCTAssertTrue(plan.blocks.isEmpty)
        XCTAssertEqual(plan.reports.count, 1, "It must still be reported")
        XCTAssertFalse(plan.reports[0].status.isFullyPlaced)
    }

    // MARK: - 9. Determinism

    func testPlanIsIdenticalRegardlessOfInputOrder() {
        let tasks = (0..<12).map { index in
            task(
                "Task \(index)",
                minutes: [30, 45, 60, 90][index % 4],
                priority: TaskPriority(rawValue: index % 4) ?? .none,
                deadline: index % 3 == 0 ? monday(hour: 23, dayOffset: 2) : nil,
                hardDeadline: index % 3 == 0,
                createdOffset: TimeInterval(index * 60)
            )
        }

        func signature(_ plan: SchedulePlan) -> [String] {
            plan.blocks
                .map { "\($0.taskID.uuidString)|\(Int($0.start.timeIntervalSince1970))|\($0.durationMinutes)" }
                .sorted()
        }

        let reference = signature(SchedulingEngine.plan(problem: problem(tasks: tasks, windows: workingDays(5))))

        for seed in 0..<25 {
            var shuffled = tasks
            var generator = SeededGenerator(seed: UInt64(seed))
            shuffled.shuffle(using: &generator)
            let plan = SchedulingEngine.plan(problem: problem(tasks: shuffled, windows: workingDays(5)))
            XCTAssertEqual(signature(plan), reference, "Order of input must not change the plan")
        }
    }

    // MARK: - 10. Interval algebra

    func testSubtractRemovesBusyOverlap() {
        let window = DateInterval(start: monday(hour: 9), end: monday(hour: 17))
        let busy = [
            DateInterval(start: monday(hour: 10), end: monday(hour: 11)),
            DateInterval(start: monday(hour: 10, minute: 30), end: monday(hour: 12))   // overlapping
        ]

        let free = SchedulingEngine.subtract(busy: SchedulingEngine.merge(busy), from: [window])

        XCTAssertEqual(free.count, 2)
        XCTAssertEqual(free[0], DateInterval(start: monday(hour: 9), end: monday(hour: 10)))
        XCTAssertEqual(free[1], DateInterval(start: monday(hour: 12), end: monday(hour: 17)))
    }

    func testMergeUnionsOverlappingIntervals() {
        let merged = SchedulingEngine.merge([
            DateInterval(start: monday(hour: 9), end: monday(hour: 10)),
            DateInterval(start: monday(hour: 9, minute: 30), end: monday(hour: 11)),
            DateInterval(start: monday(hour: 13), end: monday(hour: 14))
        ])

        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].end, monday(hour: 11))
    }

    // MARK: - 11. Working hours + DST

    func testWorkingHoursMaterialisation() throws {
        var rules = [WorkingWindow]()
        for weekday in 2...6 {
            rules.append(WorkingWindow(weekday: weekday, startMinutes: 9 * 60, endMinutes: 13 * 60))
            rules.append(WorkingWindow(weekday: weekday, startMinutes: 14 * 60, endMinutes: 18 * 60))
        }
        let range = DateInterval(start: monday(), end: monday(dayOffset: 7))
        let windows = WorkingHours.windows(from: rules, in: range, calendar: calendar)

        XCTAssertEqual(windows.count, 10, "5 weekdays × 2 windows")
        XCTAssertTrue(windows.allSatisfy { $0.duration == 4 * 3600 })
    }

    /// DST in the US: 2026-03-08 02:00 → 03:00. Blocks must stay exactly as long as
    /// planned even though the wall-clock day is 23 hours long.
    func testDSTTransitionDoesNotDistortBlocks() {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = TimeZone(identifier: "America/New_York")!
        newYork.firstWeekday = 2

        var components = DateComponents()
        components.year = 2026
        components.month = 3
        components.day = 7            // Saturday before the switch
        components.hour = 8
        let start = newYork.date(from: components)!

        var rules = [WorkingWindow]()
        for weekday in 1...7 {
            rules.append(WorkingWindow(weekday: weekday, startMinutes: 8 * 60, endMinutes: 20 * 60))
        }
        let range = DateInterval(start: start, end: newYork.date(byAdding: .day, value: 3, to: start)!)

        let windows = WorkingHours.windows(from: rules, in: range, calendar: newYork)
        XCTAssertFalse(windows.isEmpty)

        let task = SchedulableTask(
            id: UUID(), title: "Long job", estimateMinutes: 300,
            deadline: nil, isHardDeadline: false, priority: .medium,
            createdAt: start, allowsSplitting: true, notBefore: nil,
            pinnedStart: nil, pinnedEnd: nil
        )
        var policy = SchedulingPolicy()
        policy.maxChunkMinutes = 120
        policy.maxChunksPerTask = 4
        policy.dailyAutoMinutesCap = 480

        let plan = SchedulingEngine.plan(problem: ScheduleProblem(
            now: start, horizonEnd: range.end,
            workingWindows: windows, busy: [], tasks: [task], policy: policy
        ))

        XCTAssertEqual(plan.blocks.reduce(0) { $0 + $1.durationMinutes }, 300)
        for block in plan.blocks {
            XCTAssertEqual(block.durationMinutes * 60, Int(block.end.timeIntervalSince(block.start)),
                           "Duration is measured in real elapsed time, not wall-clock labels")
            XCTAssertTrue(windows.contains { $0.contains(block.start) })
        }
    }

    /// Same check in the user's own timezone, where there is no DST at all.
    func testAddisAbabaAndRiyadhHaveNoDSTSurprises() {
        for identifier in ["Africa/Addis_Ababa", "Asia/Riyadh"] {
            var zoneCalendar = Calendar(identifier: .gregorian)
            zoneCalendar.timeZone = TimeZone(identifier: identifier)!
            zoneCalendar.firstWeekday = 1

            var rules = [WorkingWindow]()
            for weekday in 1...5 {
                rules.append(WorkingWindow(weekday: weekday, startMinutes: 9 * 60, endMinutes: 18 * 60))
            }

            var components = DateComponents()
            components.year = 2026
            components.month = 10
            components.day = 3
            components.hour = 8
            let start = zoneCalendar.date(from: components)!
            let range = DateInterval(start: start, end: zoneCalendar.date(byAdding: .day, value: 6, to: start)!)

            let windows = WorkingHours.windows(from: rules, in: range, calendar: zoneCalendar)
            XCTAssertFalse(windows.isEmpty, "\(identifier) should produce working windows")
            XCTAssertTrue(windows.allSatisfy { $0.duration > 0 })
            XCTAssertEqual(windows.first?.duration, 9 * 3600, "A 09:00–18:00 window is 9 real hours")
        }
    }
}

// MARK: - Seeded RNG (keeps the determinism test reproducible)

struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 6364136223846793005 &+ 1442695040888963407
        if state == 0 { state = 0x4d595df4d0f33173 }
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}
