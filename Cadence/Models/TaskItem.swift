//
//  TaskItem.swift
//  Cadence
//
//  The central model. Everything here is written to be CloudKit-compatible:
//  every attribute has a default or is optional, there are no unique constraints,
//  and every relationship is optional or an array with an inverse.
//

import Foundation
import SwiftData

@Model
final class TaskItem {
    // Identity
    var id: UUID = UUID()
    var title: String = ""
    var notes: String = ""

    // Scheduling inputs
    var estimateMinutes: Int = 30
    var priorityRaw: Int = TaskPriority.none.rawValue
    var deadline: Date?
    var isHardDeadline: Bool = false
    var notBefore: Date?
    var isAnytime: Bool = false          // excluded from auto-scheduling
    var allowsSplitting: Bool = true

    // Scheduling outputs
    var scheduledStart: Date?
    var scheduledEnd: Date?
    var isPinned: Bool = false
    var lastScheduleReason: String?

    // Lifecycle
    var statusRaw: String = TaskStatus.open.rawValue
    var createdAt: Date = Date.now
    var updatedAt: Date = Date.now
    var completedAt: Date?
    var sortIndex: Double = 0

    // Repetition
    var repeatFrequencyRaw: String?
    var repeatInterval: Int = 1
    var repeatDaysOfWeekMask: Int = 0    // bit 0 = Sunday … bit 6 = Saturday
    var repeatEndDate: Date?
    var repeatFromCompletion: Bool = false
    var isRecurringTemplate: Bool = false
    var templateID: UUID?

    // Sync-friendliness
    var isSoftDeleted: Bool = false

    // Relationships
    var list: TaskList?

    @Relationship(deleteRule: .cascade, inverse: \Subtask.parent)
    var subtasks: [Subtask] = []

    @Relationship(inverse: \Tag.tasks)
    var tags: [Tag] = []

    @Relationship(deleteRule: .cascade, inverse: \TimeBlock.task)
    var blocks: [TimeBlock] = []

    init(
        title: String = "",
        notes: String = "",
        estimateMinutes: Int = 30,
        priority: TaskPriority = .none,
        deadline: Date? = nil,
        isHardDeadline: Bool = false,
        list: TaskList? = nil,
        allowsSplitting: Bool = true,
        isAnytime: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = UUID()
        self.title = title
        self.notes = notes
        self.estimateMinutes = estimateMinutes
        self.priorityRaw = priority.rawValue
        self.deadline = deadline
        self.isHardDeadline = isHardDeadline
        self.list = list
        self.allowsSplitting = allowsSplitting
        self.isAnytime = isAnytime
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    // MARK: - Typed accessors

    var priority: TaskPriority {
        get { TaskPriority(rawValue: priorityRaw) ?? .none }
        set { priorityRaw = newValue.rawValue }
    }

    var status: TaskStatus {
        get { TaskStatus(rawValue: statusRaw) ?? .open }
        set { statusRaw = newValue.rawValue }
    }

    var repeatFrequency: RepeatFrequency? {
        get {
            guard let raw = repeatFrequencyRaw else { return nil }
            return RepeatFrequency(rawValue: raw)
        }
        set {
            repeatFrequencyRaw = newValue?.rawValue
            if newValue == nil {
                repeatInterval = 1
                repeatDaysOfWeekMask = 0
                repeatEndDate = nil
            }
        }
    }

    var repeatDaysOfWeek: Set<Int> {
        get {
            var days: Set<Int> = []
            for bit in 0..<7 where repeatDaysOfWeekMask & (1 << bit) != 0 {
                days.insert(bit)
            }
            return days
        }
        set {
            var mask = 0
            for day in newValue { mask |= (1 << day) }
            repeatDaysOfWeekMask = mask
        }
    }

    // MARK: - Derived state

    var isOpen: Bool { status == .open }
    var isCompleted: Bool { status == .completed }
    var isRecurring: Bool { repeatFrequency != nil }

    var isOverdue: Bool {
        guard isOpen, let deadline else { return false }
        return deadline < Date.now
    }

    var orderedBlocks: [TimeBlock] {
        blocks.sorted { $0.start < $1.start }
    }

    var scheduledMinutes: Int {
        blocks.reduce(0) { $0 + $1.durationMinutes }
    }

    var remainingMinutes: Int {
        max(0, estimateMinutes - scheduledMinutes)
    }

    var estimateDescription: String { estimateMinutes.abbreviatedDuration }

    /// Short label used on calendar blocks and widgets.
    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
    }

    var subtaskProgress: (done: Int, total: Int) {
        let done = subtasks.filter { $0.isDone }.count
        return (done, subtasks.count)
    }

    // MARK: - Mutations

    func touch(_ date: Date = .now) {
        updatedAt = date
    }

    func markCompleted(_ date: Date = .now) {
        status = .completed
        completedAt = date
        touch(date)
        for subtask in subtasks { subtask.isDone = true }
    }

    func reopen(_ date: Date = .now) {
        status = .open
        completedAt = nil
        touch(date)
    }
}
