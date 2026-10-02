//
//  RecurrenceFactory.swift
//  Cadence
//
//  The SwiftData half of recurrence: the pure arithmetic lives in
//  CadenceCore/RecurrenceRule.swift (and is tested on Linux), and this file turns its
//  answers into real task instances.
//
//  Materialising the next occurrence when one completes — rather than generating a
//  series up front — keeps the store small, the widget honest, and "delete this one
//  occurrence" trivially correct.
//

import Foundation
import SwiftData

enum RecurrenceFactory {

    /// The next occurrence of a recurring task, relative to a completed instance.
    static func nextOccurrenceDate(
        for task: TaskItem,
        after date: Date,
        calendar: Calendar = .current
    ) -> Date? {
        guard let frequency = task.repeatFrequency else { return nil }
        // Anchor on the instance's own start where possible so "weekly on Tuesday"
        // keeps its time of day even if the task drifted.
        let anchor = task.scheduledStart ?? task.notBefore ?? date
        return RecurrenceRule.nextOccurrence(
            after: max(anchor, date),
            frequency: frequency,
            interval: task.repeatInterval,
            weekdayMask: task.repeatDaysOfWeekMask,
            endDate: task.repeatEndDate,
            calendar: calendar
        )
    }

    /// Builds the next instance of a recurring task, or nil when the series has ended.
    /// The caller inserts it into the context.
    static func makeNextInstance(
        for task: TaskItem,
        after date: Date = .now,
        calendar: Calendar = .current
    ) -> TaskItem? {
        guard task.isRecurring, !task.isRecurringTemplate else { return nil }
        guard let occurrence = nextOccurrenceDate(for: task, after: date, calendar: calendar) else { return nil }

        let anchor = task.scheduledStart ?? task.notBefore ?? task.createdAt
        let instance = makeInstance(of: task, at: occurrence, anchor: anchor)

        // A repeating task never lands before its own occurrence, and starts unscheduled.
        instance.notBefore = occurrence
        instance.isAnytime = task.isAnytime
        return instance
    }

    /// Copies the shape of a recurring task, with the deadline shifted by the same
    /// offset as the occurrence (a 5pm Friday report stays a 5pm Friday report).
    static func makeInstance(
        of template: TaskItem,
        at date: Date,
        anchor: Date? = nil
    ) -> TaskItem {
        let anchorDate = anchor ?? template.notBefore ?? template.createdAt

        let instance = TaskItem(
            title: template.title,
            notes: template.notes,
            estimateMinutes: template.estimateMinutes,
            priority: template.priority,
            deadline: template.deadline.map { $0.addingTimeInterval(date.timeIntervalSince(anchorDate)) },
            isHardDeadline: template.isHardDeadline,
            list: template.list,
            allowsSplitting: template.allowsSplitting,
            isAnytime: template.isAnytime,
            createdAt: date
        )
        instance.notBefore = date
        instance.templateID = template.id
        instance.tags = template.tags
        instance.subtasks = template.subtasks
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { Subtask(title: $0.title, sortIndex: $0.sortIndex) }
        return instance
    }
}
