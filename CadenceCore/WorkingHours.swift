//
//  WorkingHours.swift
//  Cadence
//
//  Turns "Mon–Fri 09:00–18:00" style rules into concrete working windows in
//  absolute time — timezone- and DST-correct, because the engine deals only in
//  instants.
//

import Foundation

/// One contiguous open window on a given weekday.
struct WorkingWindow: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: UUID
    var weekday: Int          // 1 = Sunday … 7 = Saturday (Calendar convention)
    var startMinutes: Int     // minutes from midnight, e.g. 9:00 → 540
    var endMinutes: Int       // exclusive, e.g. 18:00 → 1080

    init(id: UUID = UUID(), weekday: Int, startMinutes: Int, endMinutes: Int) {
        self.id = id
        self.weekday = weekday
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }

    var isValid: Bool { weekday >= 1 && weekday <= 7 && endMinutes > startMinutes }

    var startTimeLabel: String {
        RelativeDateFormatter.timeOfDay(minutesFromMidnight: startMinutes)
    }

    var endTimeLabel: String {
        RelativeDateFormatter.timeOfDay(minutesFromMidnight: endMinutes)
    }
}

enum WorkingHours {

    /// The owner's actual week (chosen in SPEC §15), used for a fresh install:
    ///
    ///   • Tuesday–Thursday  10:00–18:00  office hours (13:00–14:00 kept free for lunch)
    ///   • Friday–Monday     10:00–16:00  catch-up and personal time
    ///   • Every day         20:00–23:00  the late block, for a different kind of task
    ///
    /// Everything here is editable per weekday in Settings → Working hours, and the
    /// scheduler only ever uses these windows — it will not invent time outside them.
    static var defaultWindows: [WorkingWindow] {
        var windows: [WorkingWindow] = []

        // Office days (Calendar weekday convention: 1 = Sunday … 7 = Saturday).
        for weekday in [3, 4, 5] {
            windows.append(WorkingWindow(weekday: weekday, startMinutes: 10 * 60, endMinutes: 13 * 60))
            windows.append(WorkingWindow(weekday: weekday, startMinutes: 14 * 60, endMinutes: 18 * 60))
        }

        // Long weekend: catch up on the week, and keep it human.
        for weekday in [6, 7, 1, 2] {
            windows.append(WorkingWindow(weekday: weekday, startMinutes: 10 * 60, endMinutes: 16 * 60))
        }

        // The evening block, every day.
        for weekday in 1...7 {
            windows.append(WorkingWindow(weekday: weekday, startMinutes: 20 * 60, endMinutes: 23 * 60))
        }

        return windows
    }

    /// Compact human summary of a rule set, e.g. "Tue–Thu 10:00–18:00 · Fri–Mon 10:00–16:00 · 20:00–23:00 daily".
    static func summary(of rules: [WorkingWindow]) -> String {
        guard !rules.isEmpty else { return "None" }
        var byShape: [String: [Int]] = [:]
        for rule in rules where rule.isValid {
            let key = "\(rule.startMinutes)-\(rule.endMinutes)"
            byShape[key, default: []].append(rule.weekday)
        }
        return byShape
            .sorted { $0.key < $1.key }
            .map { key, weekdays in
                let parts = key.split(separator: "-").map { Int($0) ?? 0 }
                let span = "\(RelativeDateFormatter.timeOfDay(minutesFromMidnight: parts[0]))"
                    + "–\(RelativeDateFormatter.timeOfDay(minutesFromMidnight: parts[1]))"
                let days = weekdays.sorted()
                if days.count == 7 { return "\(span) daily" }
                return "\(dayRangeLabel(days)) \(span)"
            }
            .joined(separator: " · ")
    }

    private static func dayRangeLabel(_ weekdays: [Int]) -> String {
        guard let first = weekdays.first, let last = weekdays.last else { return "" }
        let short = { (weekday: Int) -> String in
            let names = Calendar.autoupdatingCurrent.veryShortWeekdaySymbols
            return names.indices.contains(weekday - 1) ? names[weekday - 1] : "?"
        }
        return weekdays.count == 1 ? short(first) : "\(short(first))–\(short(last))"
    }

    /// Materialise every open window that intersects `range`, in absolute time.
    static func windows(
        from rules: [WorkingWindow],
        in range: DateInterval,
        calendar: Calendar = .current
    ) -> [DateInterval] {
        let valid = rules.filter(\.isValid)
        guard !valid.isEmpty else { return [] }

        var result: [DateInterval] = []
        var day = calendar.startOfDay(for: range.start)
        let lastDay = calendar.startOfDay(for: range.end)
        var guardCounter = 0

        while day <= lastDay && guardCounter < 400 {      // ~13 months of safety
            guardCounter += 1
            let weekday = calendar.component(.weekday, from: day)
            for rule in valid where rule.weekday == weekday {
                guard let start = calendar.date(byAdding: .minute, value: rule.startMinutes, to: day),
                      let end = calendar.date(byAdding: .minute, value: rule.endMinutes, to: day),
                      end > start else { continue }
                if let clipped = SchedulingEngine.clip(
                    DateInterval(start: start, end: end),
                    lower: range.start,
                    upper: range.end
                ) {
                    result.append(clipped)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result.sorted { $0.start < $1.start }
    }
}
