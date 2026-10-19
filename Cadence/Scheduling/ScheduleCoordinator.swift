//
//  ScheduleCoordinator.swift
//  Cadence
//
//  The only place that talks to both SwiftData and the scheduling engine.
//
//  Responsibilities:
//    • snapshot open tasks + busy time into a `ScheduleProblem`
//    • run the engine
//    • apply the plan (delete stale engine-owned blocks, insert new ones, update
//      task.scheduledStart/End and the explainability reason)
//    • keep an undo snapshot so "Reschedule" is always reversible
//    • refresh widget snapshots and notifications
//
//  Invariants it enforces on apply:
//    • pinned / user / imported blocks are never touched
//    • blocks that have already started are frozen (you don't get teleported mid-task)
//    • every auto block belongs to exactly one open task
//

import Foundation
import SwiftData

@MainActor
final class ScheduleCoordinator {
    private let context: ModelContext
    private let preferences: Preferences
    private let calendarService: CalendarService
    private let notifications: NotificationScheduler
    private let snapshotWriter: WidgetSnapshotWriter

    private var lastUndoToken: UndoToken?

    /// `calendarService` and `notifications` default to nil rather than being constructed
    /// in the parameter list: both are `@MainActor` types, and a default argument is
    /// evaluated in the caller's (nonisolated) context — which the compiler rejects.
    /// Building them inside the body keeps this initialiser's isolation intact, and
    /// callers that pass their own instances are unaffected.
    init(
        context: ModelContext,
        preferences: Preferences,
        calendarService: CalendarService? = nil,
        notifications: NotificationScheduler? = nil,
        snapshotWriter: WidgetSnapshotWriter = .init()
    ) {
        self.context = context
        self.preferences = preferences
        self.calendarService = calendarService ?? CalendarService()
        self.notifications = notifications ?? NotificationScheduler()
        self.snapshotWriter = snapshotWriter
    }

    // MARK: - Public API

    enum Reason: String {
        case startup, manual, taskChanged, blockMoved, dayRollover, appForeground, timer, widgetAction
        /// Explicit "close the gap I just left" compaction — the only time blocks move
        /// earlier. Never automatic: see `pullsBlocksForwardOnCompletion`.
        case completionCompaction

        var analyticsLabel: String { rawValue }
    }

    struct Outcome {
        let runID: UUID
        let insertedBlocks: Int
        let removedBlocks: Int
        let atRisk: [TaskScheduleReport]
        let plan: SchedulePlan
    }

    /// What the app may offer after a completion, instead of moving blocks by itself.
    struct PullForwardSuggestion {
        let message: String
        let nextBlockStart: Date
        /// Minutes that would be reclaimed by compacting.
        let reclaimableMinutes: Int
    }

    struct CompletionOutcome {
        let nextInstance: TaskItem?
        let suggestion: PullForwardSuggestion?
    }

    @discardableResult
    func reschedule(reason: Reason = .manual, now: Date = .now) -> Outcome? {
        let policy = preferences.schedulingPolicy
        let horizonEnd = Calendar.current.date(byAdding: .day, value: policy.horizonDays, to: now) ?? now
        let range = DateInterval(start: now, end: horizonEnd)

        // 0. Mirror the user's calendar into read-only imported blocks. They then take
        //    part in the plan like any other immovable busy time — no separate code path.
        syncImportedBlocks(in: range, now: now)

        // 1. Freeze what must not move: started blocks, pinned blocks, user blocks,
        //    imported events. Everything else (future, engine-owned) is up for grabs.
        let allBlocks = fetchBlocks()
        let frozen = allBlocks.filter { !$0.isSoftDeleted && !$0.isEngineOwned }

        let busy: [BusyInterval] = frozen.map {
            BusyInterval(
                start: $0.start,
                end: $0.end,
                label: $0.task?.displayTitle ?? $0.origin.label,
                isMovable: false
            )
        }

        // 2. Snapshot open, auto-scheduled tasks.
        let tasks = fetchOpenTasks()
        let schedulable: [SchedulableTask] = tasks.compactMap { task in
            guard !task.isAnytime, !task.isSoftDeleted else { return nil }
            if task.isRecurringTemplate { return nil }
            let pinned = task.isPinned
            return SchedulableTask(
                id: task.id,
                title: task.displayTitle,
                estimateMinutes: task.estimateMinutes,
                deadline: task.deadline,
                isHardDeadline: task.isHardDeadline,
                priority: task.priority,
                createdAt: task.createdAt,
                allowsSplitting: task.allowsSplitting,
                notBefore: maxDate(task.notBefore, now),
                pinnedStart: pinned ? task.scheduledStart : nil,
                pinnedEnd: pinned ? task.scheduledEnd : nil
            )
        }

        // 3. Working windows in absolute time for the horizon.
        let windows = WorkingHours.windows(from: preferences.workingWindows, in: range)
        let problem = ScheduleProblem(
            now: now,
            horizonEnd: horizonEnd,
            workingWindows: windows,
            busy: busy,
            tasks: schedulable,
            policy: policy
        )

        // 4. Plan.
        let plan = SchedulingEngine.plan(problem: problem)

        // 5. Apply. Remember what we remove so the user can undo.
        var removed: [BlockSnapshot] = []
        let engineOwned = allBlocks.filter { $0.isEngineOwned && $0.end > now }
        for block in engineOwned {
            removed.append(BlockSnapshot(block))
            context.delete(block)
        }

        var inserted = 0
        var insertedBlockIDs: Set<UUID> = []
        let taskByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        for planned in plan.blocks where planned.isNew {
            guard let task = taskByID[planned.taskID] else { continue }
            let block = TimeBlock(
                start: planned.start,
                end: planned.end,
                origin: .auto,
                isPinned: false,
                task: task
            )
            context.insert(block)
            insertedBlockIDs.insert(block.id)
            inserted += 1
        }

        // 6. Roll blocks up onto tasks + store the explanation.
        for report in plan.reports {
            guard let task = taskByID[report.taskID] else { continue }
            task.lastScheduleReason = report.reason
            let placed = report.blocks.filter { $0.isPinned == false }
            if placed.isEmpty {
                if !task.isPinned {
                    task.scheduledStart = nil
                    task.scheduledEnd = nil
                }
            } else {
                task.scheduledStart = placed.map(\.start).min()
                task.scheduledEnd = placed.map(\.end).max()
            }
            task.touch(now)
        }

        // 7. Log the decision for explainability.
        let runID = plan.runID
        for report in plan.reports {
            let entry = SchedulingLogEntry(
                runID: runID,
                taskID: report.taskID,
                taskTitle: report.taskTitle,
                outcome: String(describing: report.status),
                reason: report.reason,
                plannedStart: report.blocks.first?.start,
                plannedMinutes: report.placedMinutes
            )
            context.insert(entry)
        }

        try? context.save()

        lastUndoToken = UndoToken(runID: runID, removed: removed, insertedBlockIDs: insertedBlockIDs)

        // 8. Fan out: widgets, notifications.
        refreshDerivedState(now: now)
        snapshotWriter.write(from: context, now: now)

        return Outcome(
            runID: runID,
            insertedBlocks: inserted,
            removedBlocks: removed.count,
            atRisk: plan.atRiskReports,
            plan: plan
        )
    }

    /// Undo the most recent reshuffle (used by the "Undo" toast).
    func undoLastReschedule(now: Date = .now) {
        guard let token = lastUndoToken else { return }
        let blocks = fetchBlocks()
        // Drop the blocks that run created…
        for block in blocks where token.insertedBlockIDs.contains(block.id) {
            context.delete(block)
        }
        // …and restore the ones it removed.
        let taskByID = Dictionary(uniqueKeysWithValues: fetchOpenTasks().map { ($0.id, $0) })
        for snapshot in token.removed {
            let block = TimeBlock(
                start: snapshot.start,
                end: snapshot.end,
                origin: .auto,
                isPinned: snapshot.isPinned,
                task: snapshot.taskID.flatMap { taskByID[$0] }
            )
            block.id = snapshot.id
            context.insert(block)
        }
        try? context.save()
        lastUndoToken = nil
        refreshDerivedState(now: now)
        snapshotWriter.write(from: context, now: now)
    }

    var canUndo: Bool { lastUndoToken != nil }

    // MARK: - Moving a single block (drag & drop)

    /// Move or resize one block. Any manual change pins it: user intent beats the algorithm.
    func move(block: TimeBlock, to start: Date, durationMinutes: Int, now: Date = .now) {
        let duration = max(preferences.minChunkMinutes, durationMinutes)
        block.start = start
        block.end = start.addingTimeInterval(TimeInterval(duration * 60))
        block.isPinned = true
        block.origin = .user
        block.isUserCreated = true
        if let task = block.task {
            task.isPinned = true
            task.estimateMinutes = max(task.estimateMinutes, duration)
            task.scheduledStart = task.orderedBlocks.map(\.start).min()
            task.scheduledEnd = task.orderedBlocks.map(\.end).max()
            task.lastScheduleReason = "Pinned to \(RelativeDateFormatter.stamp(block.start)) by you."
            task.touch(now)
        }
        try? context.save()
        snapshotWriter.write(from: context, now: now)
    }

    func unpin(task: TaskItem, now: Date = .now) {
        task.isPinned = false
        for block in task.blocks where block.origin == .user {
            block.isPinned = false
            block.origin = .auto
            block.isUserCreated = false
        }
        task.touch(now)
        try? context.save()
        reschedule(reason: .taskChanged, now: now)
    }

    // MARK: - Completion

    /// Completing a task clears its future blocks. In calm mode (the default) nothing
    /// else moves: the gap you just created stays open, and the UI *offers* to pull the
    /// next block forward instead of doing it behind your back.
    @discardableResult
    func complete(task: TaskItem, at date: Date = .now) -> CompletionOutcome {
        let futureBlocks = task.blocks
            .filter { $0.end >= date }
            .sorted { $0.start < $1.start }
        let freedFrom: Date? = futureBlocks.first?.start

        task.markCompleted(date)
        for block in futureBlocks where block.isEngineOwned {
            task.blocks.removeAll { $0.id == block.id }
            context.delete(block)
        }

        // Repeating task? Book the next occurrence immediately, so it is visible and
        // schedulable the moment you finish this one.
        var nextInstance: TaskItem?
        if task.isRecurring {
            if let instance = RecurrenceFactory.makeNextInstance(for: task, after: date) {
                context.insert(instance)
                nextInstance = instance
            }
        }

        try? context.save()

        let suggestion = preferences.pullsBlocksForwardOnCompletion
            ? nil
            : pullForwardSuggestion(freedFrom: freedFrom, now: date)

        if preferences.pullsBlocksForwardOnCompletion {
            reschedule(reason: .taskChanged, now: date)
        } else {
            refreshDerivedState(now: date)
            snapshotWriter.write(from: context, now: date)
        }

        return CompletionOutcome(nextInstance: nextInstance, suggestion: suggestion)
    }

    /// Is there a later block today that could slide into the space just freed?
    /// Deliberately conservative: only suggests when the gap is worth reclaiming.
    func pullForwardSuggestion(freedFrom: Date?, now: Date = .now) -> PullForwardSuggestion? {
        guard let freedFrom else { return nil }
        let calendar = Calendar.current
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now

        let upcoming = fetchBlocks()
            .filter { !$0.isSoftDeleted && $0.origin == .auto && $0.start > now && $0.start < endOfDay }
            .sorted { $0.start < $1.start }
        guard let next = upcoming.first, next.start > freedFrom else { return nil }

        let gap = Int(next.start.timeIntervalSince(max(freedFrom, now)) / 60)
        guard gap >= preferences.minChunkMinutes * 2 else { return nil }   // not worth moving things for

        return PullForwardSuggestion(
            message: "Next block is at \(RelativeDateFormatter.time(next.start)) — \(gap.abbreviatedDuration) gap here",
            nextBlockStart: next.start,
            reclaimableMinutes: gap
        )
    }

    /// The user accepted the offer: compact the rest of the day now.
    @discardableResult
    func pullForward(now: Date = .now) -> Outcome? {
        reschedule(reason: .completionCompaction, now: now)
    }

    /// Snooze: push the current block's start by N minutes, pinned.
    func snoozeCurrentBlock(of task: TaskItem, minutes: Int = 15, now: Date = .now) {
        guard let block = task.blocks.first(where: { $0.contains(now) }) ?? task.blocks.first(where: { $0.start > now }) else {
            return
        }
        let newStart = block.start.addingTimeInterval(TimeInterval(minutes * 60))
        move(block: block, to: newStart, durationMinutes: block.durationMinutes, now: now)
    }

    // MARK: - Derived state refresh

    func refreshDerivedState(now: Date = .now) {
        let tasks = fetchOpenTasks()
        for task in tasks {
            let futureOrActive = task.blocks.filter { $0.end > now }
            task.scheduledStart = futureOrActive.map(\.start).min()
            task.scheduledEnd = futureOrActive.map(\.end).max()
        }
        try? context.save()
        notifications.refresh(now: now, preferences: preferences, context: context)
    }

    // MARK: - Calendar import

    /// Upserts imported blocks for the planning horizon and removes ones that no
    /// longer exist in the user's calendar. Imported blocks are never scheduled into,
    /// moved, completed or notified about — they are scenery the engine plans around.
    private func syncImportedBlocks(in range: DateInterval, now: Date) {
        let existing = fetchBlocks().filter { $0.origin == .imported }
        guard preferences.importCalendarEnabled, calendarService.isAuthorized else {
            for block in existing { context.delete(block) }
            return
        }

        let events = calendarService.importedEvents(in: range, excluding: preferences.excludedCalendarIDs)
        let wanted = Dictionary(uniqueKeysWithValues: events.map { ($0.id, $0) })

        // Remove blocks whose event vanished or was edited away from our horizon.
        for block in existing {
            guard let key = block.externalEventID, let event = wanted[key] else {
                context.delete(block)
                continue
            }
            if block.start != event.start || block.end != event.end {
                block.start = event.start
                block.end = event.end
            }
        }

        // Insert the new ones.
        let knownKeys = Set(existing.compactMap(\.externalEventID))
        for event in events where !knownKeys.contains(event.id) {
            // `isPinned` stays false: origin == .imported is already immovable, and a
            // pin badge on someone else's meeting would be a lie.
            let block = TimeBlock(
                start: event.start,
                end: event.end,
                origin: .imported,
                isPinned: false,
                externalEventID: event.id
            )
            context.insert(block)
        }
    }

    // MARK: - Fetches

    private func fetchOpenTasks() -> [TaskItem] {
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "open" }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchBlocks() -> [TimeBlock] {
        (try? context.fetch(FetchDescriptor<TimeBlock>())) ?? []
    }

    private func maxDate(_ a: Date?, _ b: Date?) -> Date? {
        switch (a, b) {
        case let (a?, b?): return max(a, b)
        case let (a?, nil): return a
        case let (nil, b?): return b
        case (nil, nil): return nil
        }
    }

    // MARK: - Undo bookkeeping

    private struct BlockSnapshot {
        let id: UUID
        let start: Date
        let end: Date
        let isPinned: Bool
        let taskID: UUID?

        init(_ block: TimeBlock) {
            self.id = block.id
            self.start = block.start
            self.end = block.end
            self.isPinned = block.isPinned
            self.taskID = block.task?.id
        }
    }

    private struct UndoToken {
        let runID: UUID
        let removed: [BlockSnapshot]
        let insertedBlockIDs: Set<UUID>
    }
}