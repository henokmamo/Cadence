//
//  WidgetSnapshotContractTests.swift
//  CadenceTests
//
//  The App Group snapshot is the contract between two processes: the app writes it,
//  the widget extension reads it, and the widget's buttons patch it optimistically
//  before the app ever wakes up. Nothing in the app can catch a mistake in it — the
//  widget just shows the wrong thing — so it is tested directly.
//
//  These tests are deliberately Foundation-only, which means they run in two places:
//    • `swift test` on Linux/Windows (module: CadenceSharedContract, via SwiftPM)
//    • the Xcode test target on a simulator (everything compiled into the app module)
//  See WidgetSnapshot.swift for why the widget never opens SwiftData itself.
//

import Foundation
import XCTest

#if canImport(CadenceCore)
@testable import CadenceSharedContract
#else
@testable import Cadence
#endif

final class WidgetSnapshotContractTests: XCTestCase {

    private let calendar = Calendar(identifier: .gregorian)
    private var base: Date!
    private var taskA: UUID!
    private var taskB: UUID!
    private var memo: WidgetBlockSnapshot!
    private var invoices: WidgetBlockSnapshot!

    override func setUp() {
        super.setUp()
        base = calendar.date(from: DateComponents(year: 2026, month: 10, day: 5, hour: 10, minute: 0))!
        taskA = UUID()
        taskB = UUID()
        memo = block(from: 0, to: 30, task: taskA, title: "Write the Q4 strategy memo")
        invoices = block(from: 60, to: 120, task: taskB, title: "Send September invoices")

        // Every test starts from a known store: the suite is shared and its contents
        // persist between runs, so a test that assumes an empty store would be flaky.
        WidgetSnapshotStore.save(fixture())
    }

    override func tearDown() {
        WidgetSnapshotStore.save(.empty)
        super.tearDown()
    }

    // MARK: - Helpers

    private func at(_ minutes: Int) -> Date {
        base.addingTimeInterval(TimeInterval(minutes * 60))
    }

    private func block(from: Int, to: Int, task: UUID, title: String) -> WidgetBlockSnapshot {
        WidgetBlockSnapshot(id: UUID(), taskID: task, title: title,
                            start: at(from), end: at(to),
                            isPinned: false, listColorHex: nil)
    }

    private func fixture() -> WidgetSnapshot {
        WidgetSnapshot(generatedAt: base,
                       todayBlocks: [memo, invoices],
                       nextBlock: memo,
                       overdueCount: 2,
                       plannedMinutesToday: 90,
                       completedMinutesToday: 0,
                       atRiskTitles: ["Renew business licence"],
                       openTaskCount: 7)
    }

    // MARK: - Round-trip

    func testSnapshotSurvivesTheSharedStore() {
        let loaded = WidgetSnapshotStore.load()
        XCTAssertNotNil(loaded, "the app's write must be readable back")
        XCTAssertEqual(loaded?.todayBlocks.count, 2)
        XCTAssertEqual(loaded?.schemaVersion, 1)
        XCTAssertEqual(loaded?.openTaskCount, 7)
        XCTAssertEqual(loaded?.atRiskTitles, ["Renew business licence"])
    }

    func testCorruptPayloadReturnsNilInsteadOfCrashing() {
        // A widget must never crash on a half-written or stale-schema snapshot; it
        // shows the empty state and waits for the app to rewrite it.
        WidgetSnapshotStore.defaults.set(Data("not json at all".utf8), forKey: "widgetSnapshot.v1")
        XCTAssertNil(WidgetSnapshotStore.load())
    }

    // MARK: - Now & next lookups

    func testCurrentBlockFindsTheBlockInProgress() {
        XCTAssertEqual(WidgetSnapshotStore.load()?.currentBlock(at: at(10))?.title,
                       "Write the Q4 strategy memo")
    }

    func testBlockEndIsExclusive() {
        // The minute a block ends belongs to the gap, not to the block — otherwise a
        // 10:00–10:30 block would still look "in progress" at 10:30 exactly.
        XCTAssertNil(WidgetSnapshotStore.load()?.currentBlock(at: at(30)))
    }

    func testCurrentBlockIsNilInsideAGap() {
        XCTAssertNil(WidgetSnapshotStore.load()?.currentBlock(at: at(45)))
    }

    func testUpcomingBlocksAreFutureBlocksInOrder() {
        let upcoming = WidgetSnapshotStore.load()?.upcomingBlocks(after: at(45)) ?? []
        XCTAssertEqual(upcoming.map(\.title), ["Send September invoices"])
        XCTAssertTrue(WidgetSnapshotStore.load()?.upcomingBlocks(after: at(150)).isEmpty ?? false)
    }

    func testDurationMinutesIsNeverNegative() {
        let reversed = WidgetBlockSnapshot(id: UUID(), taskID: UUID(), title: "oops",
                                           start: at(60), end: at(30),
                                           isPinned: false, listColorHex: nil)
        XCTAssertEqual(reversed.durationMinutes, 0)
    }

    // MARK: - Optimistic widget actions

    func testMarkCompletedRemovesTheBlockAndBanksItsMinutes() {
        WidgetSnapshotStore.markCompleted(taskID: taskA, at: at(10))
        let after = WidgetSnapshotStore.load()
        XCTAssertEqual(after?.todayBlocks.count, 1, "the finished block should be gone")
        XCTAssertEqual(after?.completedMinutesToday, 30, "30 minutes of work were done")
        XCTAssertEqual(after?.plannedMinutesToday, 90, "history of what was planned is kept")
        XCTAssertEqual(after?.nextBlock?.title, "Send September invoices")
        XCTAssertEqual(after?.openTaskCount, 7, "the app owns the real counts; the widget only guesses")
    }

    func testMarkCompletedOnlyTouchesTheGivenTask() {
        WidgetSnapshotStore.markCompleted(taskID: taskB, at: at(10))
        let after = WidgetSnapshotStore.load()
        XCTAssertEqual(after?.todayBlocks.map(\.title), ["Write the Q4 strategy memo"])
        XCTAssertEqual(after?.completedMinutesToday, 60)
    }

    func testMarkCompletedForAnUnknownTaskIsANoOp() {
        WidgetSnapshotStore.markCompleted(taskID: UUID(), at: at(10))
        XCTAssertEqual(WidgetSnapshotStore.load()?.todayBlocks.count, 2)
        XCTAssertEqual(WidgetSnapshotStore.load()?.completedMinutesToday, 0)
    }

    func testSnoozingShiftsAndPinsTheBlock() {
        WidgetSnapshotStore.markBlockSnoozed(blockID: invoices.id, minutes: 15, at: at(45))
        let snoozed = WidgetSnapshotStore.load()?.todayBlocks.first { $0.id == invoices.id }
        XCTAssertEqual(snoozed?.start, invoices.start.addingTimeInterval(900), "moves forward, never backward")
        XCTAssertEqual(snoozed?.end, invoices.end.addingTimeInterval(900), "keeps its length")
        XCTAssertEqual(snoozed?.isPinned, true, "a snoozed block is user intent — pin it")
        XCTAssertEqual(WidgetSnapshotStore.load()?.nextBlock?.id, invoices.id)
    }

    // MARK: - Empty state

    func testEmptySnapshotIsSafeToRender() {
        let empty = WidgetSnapshot.empty
        XCTAssertTrue(empty.todayBlocks.isEmpty)
        XCTAssertNil(empty.currentBlock(at: base))
        XCTAssertNil(empty.nextBlock)
        XCTAssertEqual(empty.remainingMinutesToday, 0)
    }

    func testRemainingMinutesNeverGoesNegative() {
        let overCompleted = WidgetSnapshot(generatedAt: base, todayBlocks: [], nextBlock: nil,
                                           overdueCount: 0, plannedMinutesToday: 30,
                                           completedMinutesToday: 90, atRiskTitles: [],
                                           openTaskCount: 0)
        XCTAssertEqual(overCompleted.remainingMinutesToday, 0)
    }
}
