//
//  TaskModelTests.swift
//  CadenceTests
//
//  App-level tests: the SwiftData layer, the calm-mode completion behaviour and the
//  recurrence factory. These need the Apple frameworks, so they run in Xcode / on a
//  macOS CI runner — the pure engine tests live in CadenceCoreTests and run everywhere,
//  including Linux.
//

import XCTest
import SwiftData
@testable import Cadence

@MainActor
final class TaskModelTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        container = try ModelContainer(
            for: AppModelContainer.schema,
            configurations: [ModelConfiguration(schema: AppModelContainer.schema, isStoredInMemoryOnly: true)]
        )
        context = container.mainContext
    }

    override func tearDown() async throws {
        container = nil
        context = nil
    }

    // MARK: - Helpers

    private func makePreferences() -> Preferences {
        // A private UserDefaults suite per test, so tests never touch the App Group.
        let suiteName = "cadence.tests.\(UUID().uuidString)"
        return Preferences(store: UserDefaults(suiteName: suiteName)!)
    }

    /// Mon–Fri 09:00–18:00 in a fixed timezone, starting "now" so the coordinator's
    /// `now`-relative filtering behaves like production.
    private func makeCoordinator(preferences: Preferences) -> ScheduleCoordinator {
        var rules: [WorkingWindow] = []
        for weekday in 2...6 {
            rules.append(WorkingWindow(weekday: weekday, startMinutes: 9 * 60, endMinutes: 18 * 60))
        }
        preferences.workingWindows = rules
        return ScheduleCoordinator(
            context: context,
            preferences: preferences,
            calendarService: CalendarService(),
            notifications: NotificationScheduler(),
            snapshotWriter: WidgetSnapshotWriter()
        )
    }

    private func insert(_ task: TaskItem) {
        context.insert(task)
        try? context.save()
    }

    // MARK: - Calm completion

    func testCompletingEarlyLeavesOtherBlocksExactlyWhereTheyWere() throws {
        let preferences = makePreferences()
        let coordinator = makeCoordinator(preferences: preferences)
        let now = Date.now

        let inbox = TaskList(name: "Inbox", isInbox: true)
        context.insert(inbox)

        let first = TaskItem(title: "First", estimateMinutes: 60, list: inbox)
        let second = TaskItem(title: "Second", estimateMinutes: 60, list: inbox)
        insert(first)
        insert(second)

        // Place them by hand: 09:00–10:00 and 11:00–12:00 today, with a deliberate gap.
        let calendar = Calendar.current
        let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        let ten = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: now)!
        let eleven = calendar.date(bySettingHour: 11, minute: 0, second: 0, of: now)!
        let twelve = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!

        let firstBlock = TimeBlock(start: nine, end: ten, origin: .auto, task: first)
        let secondBlock = TimeBlock(start: eleven, end: twelve, origin: .auto, task: second)
        context.insert(firstBlock)
        context.insert(secondBlock)
        first.scheduledStart = nine
        first.scheduledEnd = ten
        second.scheduledStart = eleven
        second.scheduledEnd = twelve
        try context.save()

        let outcome = coordinator.complete(task: first, at: ten)

        // The completed task's block is gone…
        XCTAssertTrue(first.isCompleted)
        XCTAssertEqual(first.blocks.count, 0)

        // …but the untouched block has not been pulled forward, and calm mode offers it.
        let remaining = try XCTUnwrap(second.blocks.first)
        XCTAssertEqual(remaining.start, eleven, "calm mode must not move blocks on its own")
        XCTAssertEqual(outcome.suggestion?.nextBlockStart, eleven)
        XCTAssertNotNil(outcome.suggestion, "the gap should be offered, not silently filled")
    }

    func testAggressiveModeCompactsWhenAsked() throws {
        let preferences = makePreferences()
        preferences.pullsBlocksForwardOnCompletion = true
        let coordinator = makeCoordinator(preferences: preferences)
        let now = Date.now

        let task = TaskItem(title: "Early", estimateMinutes: 30)
        let later = TaskItem(title: "Later", estimateMinutes: 30)
        insert(task)
        insert(later)

        let calendar = Calendar.current
        let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: now)!
        let laterStart = calendar.date(bySettingHour: 15, minute: 0, second: 0, of: now)!

        context.insert(TimeBlock(start: nine, end: nine.addingTimeInterval(1800), origin: .auto, task: task))
        context.insert(TimeBlock(start: laterStart, end: laterStart.addingTimeInterval(1800), origin: .auto, task: later))
        try context.save()

        _ = coordinator.complete(task: task, at: nine.addingTimeInterval(1800))

        // With the aggressive setting the whole day is re-planned, so "Later" moves
        // into the earliest gap rather than waiting until 15:00.
        let moved = try XCTUnwrap(later.orderedBlocks.first)
        XCTAssertLessThan(moved.start, laterStart)
    }

    func testPinnedBlocksSurviveAReschedule() throws {
        let preferences = makePreferences()
        let coordinator = makeCoordinator(preferences: preferences)

        let pinned = TaskItem(title: "Dentist", estimateMinutes: 60)
        insert(pinned)

        let calendar = Calendar.current
        let start = calendar.date(bySettingHour: 14, minute: 0, second: 0, of: .now)!
        context.insert(TimeBlock(start: start, end: start.addingTimeInterval(3600), origin: .user, isPinned: true, task: pinned))
        pinned.isPinned = true
        pinned.scheduledStart = start
        pinned.scheduledEnd = start.addingTimeInterval(3600)
        try context.save()

        _ = coordinator.reschedule(reason: .manual)

        let block = try XCTUnwrap(pinned.orderedBlocks.first)
        XCTAssertEqual(block.start, start, "a pinned block must never be moved by the engine")
        XCTAssertTrue(block.isPinned)
    }

    // MARK: - Recurrence

    func testCompletingARecurringTaskBooksTheNextOccurrence() throws {
        let preferences = makePreferences()
        let coordinator = makeCoordinator(preferences: preferences)

        let weekly = TaskItem(title: "Weekly review", estimateMinutes: 60)
        weekly.repeatFrequency = .weekly
        weekly.repeatDaysOfWeek = [5]                 // Fridays (0 = Sunday)
        insert(weekly)

        let calendar = Calendar.current
        let monday = calendar.date(bySettingHour: 10, minute: 0, second: 0, of: .now)!
        weekly.notBefore = monday
        try context.save()

        let outcome = coordinator.complete(task: weekly, at: monday)

        let next = try XCTUnwrap(outcome.nextInstance, "a repeating task should book its next run")
        XCTAssertEqual(next.title, "Weekly review")
        XCTAssertEqual(next.templateID, weekly.id)
        XCTAssertEqual(next.repeatFrequency, .weekly)
        XCTAssertNotEqual(next.id, weekly.id)
        XCTAssertTrue(next.isOpen)

        // …and it should be after the occurrence we just finished.
        let nextDate = try XCTUnwrap(next.notBefore)
        XCTAssertGreaterThan(nextDate, calendar.startOfDay(for: monday))
        XCTAssertEqual(calendar.component(.weekday, from: nextDate), 6, "Friday = 6")
    }

    func testNonRecurringTaskBooksNothing() throws {
        let preferences = makePreferences()
        let coordinator = makeCoordinator(preferences: preferences)

        let once = TaskItem(title: "One-off", estimateMinutes: 30)
        insert(once)

        let outcome = coordinator.complete(task: once)
        XCTAssertNil(outcome.nextInstance)
    }

    @MainActor
    func testInstanceCopiesShapeButNotIdentity() throws {
        let template = TaskItem(
            title: "Weekly review",
            notes: "Clear the inbox",
            estimateMinutes: 60,
            priority: .medium
        )
        template.repeatDaysOfWeek = [5]
        insert(template)

        let occurrence = Date.now.addingTimeInterval(7 * 24 * 3600)
        let instance = RecurrenceFactory.makeInstance(of: template, at: occurrence)

        XCTAssertEqual(instance.title, "Weekly review")
        XCTAssertEqual(instance.notes, "Clear the inbox")
        XCTAssertEqual(instance.estimateMinutes, 60)
        XCTAssertEqual(instance.priority, .medium)
        XCTAssertEqual(instance.templateID, template.id)
        XCTAssertNotEqual(instance.id, template.id)
        XCTAssertTrue(instance.isOpen)
    }

    // MARK: - Model arithmetic

    func testCompletingATaskMarksSubtasksAndStampsTheDate() throws {
        let task = TaskItem(title: "Ship it", estimateMinutes: 90)
        task.subtasks = [Subtask(title: "Write", sortIndex: 0), Subtask(title: "Review", sortIndex: 1)]
        insert(task)

        let when = Date.now
        task.markCompleted(when)

        XCTAssertEqual(task.status, .completed)
        XCTAssertEqual(task.completedAt, when)
        XCTAssertTrue(task.subtasks.allSatisfy(\.isDone))
        XCTAssertEqual(task.subtaskProgress.done, 2)
    }

    func testRemainingMinutesReflectsPlacedBlocks() throws {
        let task = TaskItem(title: "Half done", estimateMinutes: 120)
        insert(task)

        let start = Date.now
        context.insert(TimeBlock(start: start, end: start.addingTimeInterval(3600), origin: .auto, task: task))
        try context.save()

        XCTAssertEqual(task.scheduledMinutes, 60)
        XCTAssertEqual(task.remainingMinutes, 60)
        XCTAssertFalse(task.isOverdue)

        task.deadline = Date.now.addingTimeInterval(-3600)
        XCTAssertTrue(task.isOverdue)
    }
}
