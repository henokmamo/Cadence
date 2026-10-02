//
//  Formatting.swift
//  CadenceCore
//
//  Every user-facing date string funnels through here. Two reasons:
//    1. Locale / 24-hour / first-day-of-week choices stay in one place, so a future
//       Ethiopian-calendar display option is a change here and nowhere else.
//    2. This file must compile and behave identically on Apple platforms and on Linux
//       (swift-corelibs-foundation), because the scheduling core is tested on Linux in
//       CI. That rules out `RelativeDateTimeFormatter`, which Apple ships but
//       corelibs-foundation does not, so the relative strings are built by hand.
//

import Foundation

enum RelativeDateFormatter {

    private static let calendar = Calendar.autoupdatingCurrent

    // MARK: - Relative ("in 42 min")

    /// Full-sentence relative time: "in 3 hours", "2 days ago".
    static func relative(from now: Date = .now, to date: Date) -> String {
        let seconds = date.timeIntervalSince(now)
        let future = seconds >= 0
        let totalMinutes = Int((abs(seconds) / 60).rounded())

        let phrase: String
        switch totalMinutes {
        case ..<1:   phrase = "just now"
        case ..<60:  phrase = plural(totalMinutes, "minute")
        case ..<(60 * 24):
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            phrase = minutes == 0
                ? plural(hours, "hour")
                : "\(plural(hours, "hour")) \(minutes) min"
        default:
            let days = totalMinutes / (60 * 24)
            let hours = (totalMinutes % (60 * 24)) / 60
            phrase = hours == 0
                ? plural(days, "day")
                : "\(plural(days, "day")) \(hours) h"
        }

        if phrase == "just now" { return phrase }
        return future ? "in \(phrase)" : "\(phrase) ago"
    }

    /// Compact "in 42m" / "12m ago" style used on cards and widgets.
    static func compactRelative(from now: Date = .now, to date: Date) -> String {
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded())
        if abs(minutes) < 1 { return "now" }
        if abs(minutes) < 60 { return minutes > 0 ? "in \(minutes)m" : "\(-minutes)m ago" }
        let hours = abs(minutes) / 60
        let mins = abs(minutes) % 60
        let chunk = mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
        return minutes > 0 ? "in \(chunk)" : "\(chunk) ago"
    }

    // MARK: - Clock time

    static func time(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }

    /// "09:30 – 11:00"
    static func timeRange(_ start: Date, _ end: Date) -> String {
        "\(time(start)) – \(time(end))"
    }

    static func timeOfDay(minutesFromMidnight: Int) -> String {
        let clamped = max(0, min(minutesFromMidnight, 24 * 60))
        let components = DateComponents(hour: clamped / 60, minute: clamped % 60)
        guard let date = calendar.date(from: components) else { return "" }
        return time(date)
    }

    // MARK: - Days

    /// "Today", "Tomorrow", "Wed 8 Oct"
    static func day(_ date: Date, reference: Date = .now) -> String {
        if calendar.isDate(date, inSameDayAs: reference) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: reference),
           calendar.isDate(date, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: reference),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        if calendar.isDate(date, equalTo: reference, toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// "Wed 8 Oct 09:30"
    static func short(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute())
    }

    /// "Wed 09:30" — used in reason strings and block labels.
    static func stamp(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    /// "Today 17:00", "Thu 17:00"
    static func deadlineStamp(_ date: Date, reference: Date = .now) -> String {
        "\(day(date, reference: reference)) \(time(date))"
    }

    // MARK: - Durations & spans

    /// 09:00–11:00 as "2h"
    static func span(_ start: Date, _ end: Date) -> String {
        Int(end.timeIntervalSince(start) / 60).abbreviatedDuration
    }

    /// Weekday symbols honouring the locale's first day of the week.
    static var orderedWeekdaySymbols: [(index: Int, short: String, full: String)] {
        let shortSymbols = calendar.shortWeekdaySymbols
        let fullSymbols = calendar.weekdaySymbols
        let first = calendar.firstWeekday - 1        // 0-based
        return (0..<7).map { offset in
            let index = (first + offset) % 7
            return (index: index, short: shortSymbols[index], full: fullSymbols[index])
        }
    }

    static func weekdayFullName(index: Int) -> String {
        let names = calendar.weekdaySymbols
        guard names.indices.contains(index) else { return "" }
        return names[index]
    }

    // MARK: - Helpers

    private static func plural(_ count: Int, _ noun: String) -> String {
        count == 1 ? "1 \(noun)" : "\(count) \(noun)s"
    }
}

// MARK: - Time formatting helpers for the hours pickers

extension Int {
    /// "9:00 AM" / "09:00" — respects the locale's 12/24-hour preference.
    var timeOfDayLabel: String { RelativeDateFormatter.timeOfDay(minutesFromMidnight: self) }
}
