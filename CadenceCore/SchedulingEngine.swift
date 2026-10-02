//
//  SchedulingEngine.swift
//  Cadence
//
//  The auto-scheduler.
//
//  Design goals, in priority order:
//    1. Deterministic — same inputs always produce the same plan (no RNG, total sort order).
//    2. Explainable — every placement and every failure carries a human reason string.
//    3. Fast — O(n · m) greedy, sub-millisecond at realistic sizes, safe to run on the
//       main thread during a drag and inside a widget/App Intent.
//    4. Pure — value types in, value types out. No SwiftData, no UI, no EventKit.
//       (Verified by CadenceTests/SchedulingEngineTests.swift.)
//
//  Strategy: "EDF-first, earliest-fit, split-aware"
//    - Order tasks by earliest deadline first, then priority, then age. EDF is optimal
//      for meeting deadlines on a single resource; the chunked version here is a bounded,
//      human-explainable relaxation of that.
//    - Walk the free timeline and take the earliest gap that fits each chunk.
//    - Long tasks are split into chunks of at most `maxChunkMinutes`, preferring new days,
//      capped at `maxChunksPerTask`, never smaller than `minChunkMinutes`.
//    - User-pinned blocks are immovable: the engine plans *around* them, always.
//

import Foundation

// MARK: - Value types crossing the boundary

/// A task as the engine sees it. Snapshotted from SwiftData by ScheduleCoordinator.
struct SchedulableTask: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var estimateMinutes: Int
    var deadline: Date?
    var isHardDeadline: Bool
    var priority: TaskPriority
    var createdAt: Date
    var allowsSplitting: Bool
    var notBefore: Date?
    /// Present when the user pinned this task to a specific slot.
    var pinnedStart: Date?
    var pinnedEnd: Date?
}

/// Something the engine must plan around: pinned task blocks, imported calendar
/// events, manual busy blocks.
struct BusyInterval: Equatable, Sendable {
    var start: Date
    var end: Date
    var label: String
    var isMovable: Bool

    init(start: Date, end: Date, label: String = "Busy", isMovable: Bool = false) {
        self.start = min(start, end)
        self.end = max(start, end)
        self.label = label
        self.isMovable = isMovable
    }
}

struct SchedulingPolicy: Equatable, Sendable {
    /// Breathing room kept after every placed block.
    var bufferMinutes: Int = 10
    /// Never create a chunk shorter than this.
    var minChunkMinutes: Int = 15
    /// Longest single block; longer work is split across blocks.
    var maxChunkMinutes: Int = 90
    /// How many blocks one task may span.
    var maxChunksPerTask: Int = 3
    /// Soft cap on auto-scheduled minutes per calendar day.
    var dailyAutoMinutesCap: Int = 240
    /// How far ahead the engine plans.
    var horizonDays: Int = 14
    /// When true, no block is placed past a hard deadline.
    var respectDeadlineForPlacement: Bool = true
    /// Earliest-deadline-first ordering. Off ⇒ pure priority ordering.
    var edfEnabled: Bool = true

    static let `default` = SchedulingPolicy()
}

struct ScheduleProblem: Sendable {
    var now: Date
    var horizonEnd: Date
    /// Concrete working windows in absolute time (weekday rules already resolved).
    var workingWindows: [DateInterval]
    var busy: [BusyInterval]
    var tasks: [SchedulableTask]
    var policy: SchedulingPolicy
}

struct ScheduledBlock: Identifiable, Equatable, Sendable {
    let id: UUID
    let taskID: UUID
    let taskTitle: String
    var start: Date
    var end: Date
    var isPinned: Bool
    var isNew: Bool

    var durationMinutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }
}

struct TaskScheduleReport: Identifiable, Equatable, Sendable {
    var id: UUID { taskID }
    let taskID: UUID
    let taskTitle: String
    var status: ScheduleStatus
    var blocks: [ScheduledBlock]
    var reason: String
    /// Minutes of work that could not be placed.
    var shortfallMinutes: Int

    var placedMinutes: Int { blocks.reduce(0) { $0 + $1.durationMinutes } }
}

struct SchedulePlan: Sendable {
    var runID: UUID
    var generatedAt: Date
    var blocks: [ScheduledBlock]
    var reports: [TaskScheduleReport]
    var freeIntervalsAfterPlanning: [DateInterval]

    var blocksForNewTasks: [ScheduledBlock] { blocks.filter { $0.isNew } }
    var atRiskReports: [TaskScheduleReport] {
        reports.filter { !$0.status.isFullyPlaced }
    }
    var totalPlannedMinutes: Int { blocks.reduce(0) { $0 + $1.durationMinutes } }

    func report(for taskID: UUID) -> TaskScheduleReport? {
        reports.first { $0.taskID == taskID }
    }
}

// MARK: - Engine

enum SchedulingEngine {

    static func plan(problem: ScheduleProblem) -> SchedulePlan {
        let runID = UUID()
        let policy = problem.policy
        let now = problem.now
        let horizonEnd = max(problem.horizonEnd, now)

        // 1. Free time = working windows − busy, clipped to [now, horizon].
        let busyMerged = merge(
            problem.busy.map { DateInterval(start: min($0.start, $0.end), end: max($0.start, $0.end)) }
        )
        var free = subtract(busy: busyMerged, from: problem.workingWindows)
            .compactMap { clip($0, lower: now, upper: horizonEnd) }
            // Gap must be able to host the smallest block we would ever create.
            .filter { $0.duration >= TimeInterval(policy.minChunkMinutes * 60) }

        var planBlocks: [ScheduledBlock] = []
        var reports: [TaskScheduleReport] = []
        var autoMinutesByDay: [Date: Int] = [:]

        // Pinned tasks are reported as-is and take no part in placement beyond being busy.
        let ordered = order(problem.tasks, policy: policy)

        for task in ordered {
            // Pinned: report, keep, never move.
            if let pinnedStart = task.pinnedStart,
               let pinnedEnd = task.pinnedEnd,
               pinnedEnd > pinnedStart {
                let block = ScheduledBlock(
                    id: task.id, taskID: task.id, taskTitle: task.title,
                    start: pinnedStart, end: pinnedEnd, isPinned: true, isNew: false
                )
                reports.append(TaskScheduleReport(
                    taskID: task.id, taskTitle: task.title, status: .pinned,
                    blocks: [block], reason: "Pinned by you — the scheduler leaves it alone.",
                    shortfallMinutes: 0
                ))
                planBlocks.append(block)
                continue
            }

            var remaining = max(1, task.estimateMinutes)
            var placed: [ScheduledBlock] = []
            var chunks = 0
            var lastChunkDay: Date?
            var relaxations: [String] = []
            // A task that must not be split gets exactly one attempt, and that attempt
            // has to fit the whole estimate.
            let chunkBudget = task.allowsSplitting ? policy.maxChunksPerTask : 1

            while remaining > 0 && chunks < chunkBudget {
                let desired = min(remaining, policy.maxChunkMinutes)
                guard let match = findSlot(
                    for: task,
                    desiredMinutes: desired,
                    free: free,
                    policy: policy,
                    autoMinutesByDay: autoMinutesByDay,
                    lastChunkDay: lastChunkDay,
                    isFirstChunk: chunks == 0,
                    relaxations: &relaxations
                ) else { break }

                let duration = match.minutes
                let block = ScheduledBlock(
                    id: UUID(), taskID: task.id, taskTitle: task.title,
                    start: match.start, end: match.start.addingTimeInterval(TimeInterval(duration * 60)),
                    isPinned: false, isNew: true
                )
                placed.append(block)
                planBlocks.append(block)

                let day = Calendar.current.startOfDay(for: block.start)
                autoMinutesByDay[day, default: 0] += duration
                lastChunkDay = day

                remaining -= duration
                chunks += 1
                free = consume(start: match.start, minutes: duration, from: free, policy: policy)
            }

            let totalPlaced = placed.reduce(0) { $0 + $1.durationMinutes }
            let status: ScheduleStatus
            let reason: String
            if placed.isEmpty {
                status = .unscheduled(reason: blockReason(for: task, free: free, policy: policy))
                reason = blockReason(for: task, free: free, policy: policy)
            } else if remaining > 0 {
                status = .partial(remainingMinutes: remaining)
                reason = "Placed \(totalPlaced.abbreviatedDuration) across \(placed.count) block\(placed.count == 1 ? "" : "s"); "
                    + "\(remaining.abbreviatedDuration) doesn't fit before the deadline."
            } else if placed.count > 1 {
                status = .scheduled
                reason = "Split into \(placed.count) blocks across \(distinctDays(placed)) day\(distinctDays(placed) == 1 ? "" : "s")."
            } else {
                status = .scheduled
                reason = "Fitted into the earliest open \(totalPlaced.abbreviatedDuration) slot."
            }
            let reasonWithCaveats = relaxations.isEmpty
                ? reason
                : reason + " (" + Set(relaxations).sorted().joined(separator: ", ") + ")"

            reports.append(TaskScheduleReport(
                taskID: task.id, taskTitle: task.title, status: status,
                blocks: placed.sorted { $0.start < $1.start },
                reason: reasonWithCaveats,
                shortfallMinutes: max(0, task.estimateMinutes - totalPlaced)
            ))
        }

        return SchedulePlan(
            runID: runID,
            generatedAt: now,
            blocks: planBlocks.sorted { $0.start < $1.start },
            reports: reports,
            freeIntervalsAfterPlanning: free
        )
    }

    // MARK: - Placement

    private struct SlotMatch {
        let start: Date
        let minutes: Int
    }

    /// Earliest-fit search in three passes, so that "placed with a caveat" always beats
    /// "not placed at all" — but a caveat is always *reported*, never hidden.
    ///
    ///   pass 1  full comfort: the whole chunk fits, with a trailing buffer, under the
    ///           daily cap, on a fresh day  →  never produces a stunted block
    ///   pass 2  tight fit: the chunk may be shortened to what actually fits, or reuse
    ///           a day, as long as the buffer and cap still hold
    ///   pass 3  last resort: the soft daily cap, the buffer and cross-day spreading are
    ///           all relaxed — anything that fits is placed, and reported
    ///
    /// Tasks marked "don't split" must fit their whole estimate in one slot.
    private static func findSlot(
        for task: SchedulableTask,
        desiredMinutes: Int,
        free: [DateInterval],
        policy: SchedulingPolicy,
        autoMinutesByDay: [Date: Int],
        lastChunkDay: Date?,
        isFirstChunk: Bool,
        relaxations: inout [String]
    ) -> SlotMatch? {
        let calendar = Calendar.current
        let lowerBound = task.notBefore
        let deadline = (policy.respectDeadlineForPlacement && task.isHardDeadline) ? task.deadline : nil
        let wantsFullSlot = !task.allowsSplitting
        // Short tasks may produce a block shorter than the minimum chunk — the floor
        // only exists to stop the scheduler from shattering longer work.
        let floorMinutes = min(policy.minChunkMinutes, desiredMinutes)

        for pass in 1...3 {
            // Pass 1 takes the earliest full-size chunk ("start soon"). The relaxed
            // passes instead take the roomiest gap available, because a split task
            // should get the biggest holes in the day rather than whatever sliver
            // happens to come first. Ties break on earliest start, so it stays
            // deterministic.
            var best: SlotMatch?
            var bestCaveats: [String] = []

            for interval in free {
                var candidateStart = interval.start
                if let lowerBound { candidateStart = max(candidateStart, lowerBound) }
                guard candidateStart < interval.end else { continue }

                let available = interval.end.timeIntervalSince(candidateStart) / 60
                guard available >= Double(floorMinutes) else { continue }

                if wantsFullSlot {
                    // No splitting allowed: the whole estimate must fit here, and the
                    // slot must also satisfy the deadline.
                    guard available >= Double(desiredMinutes) else { continue }
                    if let deadline {
                        let finish = candidateStart.addingTimeInterval(TimeInterval(desiredMinutes * 60))
                        guard finish <= deadline else { continue }
                    }
                }

                var minutes = min(desiredMinutes, Int(available.rounded(.down)))
                minutes = max(floorMinutes, minutes)

                if let deadline {
                    let finish = candidateStart.addingTimeInterval(TimeInterval(minutes * 60))
                    if finish > deadline {
                        let untilDeadline = deadline.timeIntervalSince(candidateStart) / 60
                        guard untilDeadline >= Double(floorMinutes) else { continue }
                        minutes = Int(untilDeadline.rounded(.down))
                    }
                }

                let day = calendar.startOfDay(for: candidateStart)
                let load = autoMinutesByDay[day, default: 0]

                var caveats: [String] = []

                switch pass {
                case 1:
                    // Full size or nothing: a 90-minute block of work should never be
                    // started in a 20-minute hole just because it is the earliest one.
                    if minutes < desiredMinutes { continue }
                    let end = candidateStart.addingTimeInterval(TimeInterval(minutes * 60))
                    let buffer = TimeInterval(policy.bufferMinutes * 60)
                    if end.addingTimeInterval(buffer) > interval.end { continue }
                    if load + minutes > policy.dailyAutoMinutesCap { continue }
                    if !isFirstChunk, let lastChunkDay, calendar.isDate(day, inSameDayAs: lastChunkDay) { continue }
                case 2:
                    if load + minutes > policy.dailyAutoMinutesCap { continue }
                    if !isFirstChunk, let lastChunkDay, calendar.isDate(day, inSameDayAs: lastChunkDay) {
                        caveats.append("stacked on the same day")
                    }
                default:
                    // Last resort. Report precisely which comfort was given up.
                    if load + minutes > policy.dailyAutoMinutesCap {
                        caveats.append("daily cap relaxed")
                    }
                    if !isFirstChunk, let lastChunkDay, calendar.isDate(day, inSameDayAs: lastChunkDay) {
                        caveats.append("stacked on the same day")
                    }
                    let end = candidateStart.addingTimeInterval(TimeInterval(minutes * 60))
                    if end.addingTimeInterval(TimeInterval(policy.bufferMinutes * 60)) > interval.end {
                        caveats.append("no buffer after this block")
                    }
                }

                let candidate = SlotMatch(start: candidateStart, minutes: minutes)
                if pass == 1 { return candidate }          // earliest wins
                if let current = best {
                    if candidate.minutes > current.minutes {
                        best = candidate
                        bestCaveats = caveats
                    }
                } else {
                    best = candidate
                    bestCaveats = caveats
                }
            }

            if let best {
                relaxations.append(contentsOf: bestCaveats)
                if best.minutes < desiredMinutes { relaxations.append("tight fit") }
                return best
            }
        }
        return nil
    }

    /// Remove `minutes` of capacity at `start` and re-open the rest of that interval
    /// after the buffer. Returns the updated free list, still sorted.
    private static func consume(
        start: Date,
        minutes: Int,
        from free: [DateInterval],
        policy: SchedulingPolicy
    ) -> [DateInterval] {
        var result: [DateInterval] = []
        let blockEnd = start.addingTimeInterval(TimeInterval(minutes * 60))
        let resumeAt = blockEnd.addingTimeInterval(TimeInterval(policy.bufferMinutes * 60))

        for interval in free {
            guard interval.start <= start, start < interval.end else {
                result.append(interval)
                continue
            }
            if resumeAt < interval.end, resumeAt > interval.start {
                result.append(DateInterval(start: resumeAt, end: interval.end))
            }
            // Anything before `start` inside this interval is untouched (the search
            // always places at the earliest legal instant, so this is usually empty).
            if interval.start < start {
                result.append(DateInterval(start: interval.start, end: start))
            }
        }
        return result
            .filter { $0.duration >= TimeInterval(policy.minChunkMinutes * 60) }
            .sorted { $0.start < $1.start }
    }

    private static func blockReason(
        for task: SchedulableTask,
        free: [DateInterval],
        policy: SchedulingPolicy
    ) -> String {
        let minutes = task.estimateMinutes
        let required = max(policy.minChunkMinutes, min(minutes, policy.maxChunkMinutes))
        if free.isEmpty {
            if let deadline = task.deadline {
                return "Already full before \(RelativeDateFormatter.stamp(deadline)) — no open working time left."
            }
            return "No open working time left in the planning horizon."
        }
        let longest = free.map { Int($0.duration / 60) }.max() ?? 0
        if longest < required {
            let deadlineText = task.deadline.map { " before \(RelativeDateFormatter.short($0))" } ?? ""
            return "Longest free gap is \(longest.abbreviatedDuration) — needs "
                + "\(required.abbreviatedDuration)\(deadlineText)."
        }
        return "Could not be placed; \(minutes.abbreviatedDuration) still unplanned."
    }

    private static func distinctDays(_ blocks: [ScheduledBlock]) -> Int {
        let calendar = Calendar.current
        return Set(blocks.map { calendar.startOfDay(for: $0.start) }).count
    }

    // MARK: - Ordering

    /// Total, stable ordering: identical inputs ⇒ identical output.
    static func order(_ tasks: [SchedulableTask], policy: SchedulingPolicy) -> [SchedulableTask] {
        let distantFuture = Date.distantFuture
        return tasks.sorted { lhs, rhs in
            if policy.edfEnabled {
                let lhsHasDeadline = lhs.deadline != nil
                let rhsHasDeadline = rhs.deadline != nil
                if lhsHasDeadline != rhsHasDeadline { return lhsHasDeadline }
                if lhsHasDeadline, rhsHasDeadline, lhs.deadline != rhs.deadline {
                    return (lhs.deadline ?? distantFuture) < (rhs.deadline ?? distantFuture)
                }
            }
            if lhs.priority.rawValue != rhs.priority.rawValue {
                return lhs.priority.rawValue > rhs.priority.rawValue
            }
            if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: - Interval algebra (exposed for tests)

    static func merge(_ intervals: [DateInterval]) -> [DateInterval] {
        let sorted = intervals.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
        var result: [DateInterval] = []
        for interval in sorted {
            if var last = result.last, interval.start <= last.end {
                last = DateInterval(start: last.start, end: max(last.end, interval.end))
                result[result.count - 1] = last
            } else {
                result.append(interval)
            }
        }
        return result
    }

    /// Returns `intervals` with every part covered by `busy` removed.
    static func subtract(busy: [DateInterval], from intervals: [DateInterval]) -> [DateInterval] {
        let busy = merge(busy)
        var result: [DateInterval] = []
        for interval in intervals {
            var pieces: [DateInterval] = [interval]
            for block in busy {
                var next: [DateInterval] = []
                for piece in pieces {
                    if block.end <= piece.start || block.start >= piece.end {
                        next.append(piece)                       // no overlap
                    } else {
                        if piece.start < block.start {
                            next.append(DateInterval(start: piece.start, end: block.start))
                        }
                        if block.end < piece.end {
                            next.append(DateInterval(start: block.end, end: piece.end))
                        }
                    }
                }
                pieces = next
            }
            result.append(contentsOf: pieces)
        }
        return result.filter { $0.end > $0.start }.sorted { $0.start < $1.start }
    }

    static func clip(_ interval: DateInterval, lower: Date?, upper: Date?) -> DateInterval? {
        var start = interval.start
        var end = interval.end
        if let lower { start = max(start, lower) }
        if let upper { end = min(end, upper) }
        guard end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
}
