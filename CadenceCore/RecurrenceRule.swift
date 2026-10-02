//
//  RecurrenceRule.swift
//  CadenceCore
//
//  Pure recurrence arithmetic: "given this occurrence, when is the next one?"
//  No SwiftData, no TaskItem — the app layer turns the answer into a new task
//  (see Cadence/Scheduling/RecurrenceFactory.swift).
//
//  Recurring tasks are stored as a template plus materialised instances.
//  Materialising (rather than computing on the fly) keeps the scheduler, widget and
//  notifications on one simple code path, and keeps `blocks` ordinary database rows.
//

import Foundation

enum RecurrenceRule {

    /// Next occurrence strictly after `date`, honouring interval, weekday sets and an
    /// optional series end. Returns nil for one-shot tasks or ended series.
    static func nextOccurrence(
        after date: Date,
        frequency: RepeatFrequency,
        interval: Int,
        weekdayMask: Int,
        endDate: Date?,
        calendar: Calendar = .current
    ) -> Date? {
        let step = max(1, interval)
        var candidate: Date?

        switch frequency {
        case .daily:
            candidate = calendar.date(byAdding: .day, value: step, to: date)

        case .weekly:
            let days = weekdayIndices(from: weekdayMask)
            if days.isEmpty {
                candidate = calendar.date(byAdding: .weekOfYear, value: step, to: date)
            } else {
                // Walk forward day by day, respecting the week interval.
                var cursor = calendar.startOfDay(for: date)
                for _ in 0..<(step * 7 + 7) {
                    guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                    cursor = next
                    let weekdayIndex = calendar.component(.weekday, from: cursor) - 1
                    if days.contains(weekdayIndex) {
                        // Only accept days inside an "on" week.
                        if step == 1 || weeksBetween(date, cursor, calendar: calendar) % step == 0 {
                            candidate = combine(day: cursor, like: date, calendar: calendar)
                            break
                        }
                    }
                }
            }

        case .monthly:
            candidate = calendar.date(byAdding: .month, value: step, to: date)

        case .yearly:
            candidate = calendar.date(byAdding: .year, value: step, to: date)
        }

        guard var result = candidate else { return nil }
        if let endDate, result > endDate { return nil }
        // Preserve the time of day for non-weekly rules where date math may drift.
        if frequency != .weekly {
            result = combine(day: result, like: date, calendar: calendar)
        }
        return result
    }

    // MARK: - Helpers

    /// Mask convention (matches `TaskItem.repeatDaysOfWeekMask`): bit 0 = Sunday … bit 6 = Saturday.
    static func weekdayIndices(from mask: Int) -> Set<Int> {
        var days: Set<Int> = []
        for bit in 0..<7 where mask & (1 << bit) != 0 { days.insert(bit) }
        return days
    }

    static func mask(fromIndices indices: Set<Int>) -> Int {
        var mask = 0
        for index in indices where (0..<7).contains(index) { mask |= (1 << index) }
        return mask
    }

    private static func combine(day: Date, like date: Date, calendar: Calendar) -> Date {
        let time = calendar.dateComponents([.hour, .minute], from: date)
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = time.hour
        components.minute = time.minute
        return calendar.date(from: components) ?? day
    }

    private static func weeksBetween(_ a: Date, _ b: Date, calendar: Calendar) -> Int {
        let start = calendar.startOfDay(for: a)
        let end = calendar.startOfDay(for: b)
        let weeks = calendar.dateComponents([.weekOfYear], from: start, to: end).weekOfYear ?? 0
        return abs(weeks)
    }
}
