//
//  SampleData.swift
//  Cadence
//
//  First-run content. A task app with an empty list is impossible to evaluate, and
//  a task app seeded with "Buy milk" doesn't show what the scheduler can do — so this
//  seeds a realistic, slightly-overbooked week that exercises splitting, deadlines,
//  priorities and pins.
//

import Foundation
import SwiftData

enum SampleData {

    static func seedIfEmpty(context: ModelContext, now: Date = .now) {
        let descriptor = FetchDescriptor<TaskList>()
        let existing = (try? context.fetch(descriptor)) ?? []
        guard existing.isEmpty else { return }
        seed(context: context, now: now)
    }

    static func seed(context: ModelContext, now: Date = .now) {
        let calendar = Calendar.current

        let inbox = TaskList(name: "Inbox", colorHex: "#5A6CF3", symbolName: "tray", sortIndex: 0, isInbox: true)
        let work = TaskList(name: "Work", colorHex: "#3B82F6", symbolName: "briefcase", sortIndex: 1)
        let personal = TaskList(name: "Personal", colorHex: "#10B981", symbolName: "house", sortIndex: 2)
        let side = TaskList(name: "Launch", colorHex: "#F59E0B", symbolName: "paperplane", sortIndex: 3)
        [inbox, work, personal, side].forEach(context.insert)

        let deepWork = Tag(name: "deep work", colorHex: "#8B5CF6")
        let errands = Tag(name: "errands", colorHex: "#64748B")
        let admin = Tag(name: "admin", colorHex: "#94A3B8")
        [deepWork, errands, admin].forEach(context.insert)

        /// Next occurrence of a Calendar weekday (1 = Sunday … 7 = Saturday) at a given
        /// local time, always in the future.
        func nextWeekday(_ weekday: Int, hour: Int, minute: Int = 0) -> Date {
            var day = calendar.startOfDay(for: now)
            for _ in 0..<14 {
                if calendar.component(.weekday, from: day) == weekday,
                   let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                   candidate > now {
                    return candidate
                }
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
            return now.addingTimeInterval(24 * 3600)
        }

        // 1. Long, splittable, deadline — should be split into several blocks.
        let report = TaskItem(
            title: "Write the Q4 strategy memo",
            notes: "Two-page memo for the leadership review. Draft first, then tighten.",
            estimateMinutes: 300,
            priority: .high,
            deadline: calendar.date(byAdding: .day, value: 4, to: now),
            isHardDeadline: true,
            list: work,
            allowsSplitting: true
        )
        report.tags = [deepWork]
        report.subtasks = [
            Subtask(title: "Outline the argument", sortIndex: 0),
            Subtask(title: "Pull last quarter's numbers", sortIndex: 1),
            Subtask(title: "Draft", sortIndex: 2),
            Subtask(title: "Edit ruthlessly", sortIndex: 3)
        ]

        // 2. Short daily admin — quick win.
        let invoices = TaskItem(
            title: "Send September invoices",
            estimateMinutes: 45,
            priority: .medium,
            deadline: calendar.date(byAdding: .day, value: 2, to: now),
            isHardDeadline: true,
            list: work
        )
        invoices.tags = [admin]

        // 3. Anytime task — intentionally not scheduled.
        let bookshelf = TaskItem(
            title: "Fix the wobbly bookshelf",
            estimateMinutes: 60,
            priority: .low,
            list: personal,
            isAnytime: true
        )

        // 4. Recurring habit instance.
        let standup = TaskItem(
            title: "Weekly review",
            notes: "Inbox zero, next week's plan, one thing to improve.",
            estimateMinutes: 60,
            priority: .medium,
            list: work
        )
        standup.repeatFrequency = .weekly
        standup.repeatDaysOfWeek = [6]           // Friday (0 = Sunday)
        standup.notBefore = nextWeekday(6, hour: 16)

        // 5. Something already pinned — the scheduler must work around it.
        let call = TaskItem(
            title: "Call the accountant",
            estimateMinutes: 30,
            priority: .high,
            deadline: calendar.date(byAdding: .day, value: 1, to: now),
            list: work,
            allowsSplitting: false
        )
        call.isPinned = true
        let pinnedStart = nextWeekday(2, hour: 15)
        call.scheduledStart = pinnedStart
        call.scheduledEnd = pinnedStart.addingTimeInterval(30 * 60)

        // 6. Overdue — proves the at-risk surface.
        let tax = TaskItem(
            title: "Renew business licence",
            estimateMinutes: 40,
            priority: .high,
            deadline: calendar.date(byAdding: .day, value: -1, to: now),
            isHardDeadline: true,
            list: personal
        )
        tax.tags = [errands]

        // 7. A grab bag of smaller work items.
        let smallTasks: [(String, Int, TaskPriority, TaskList, Int)] = [
            ("Review PRs", 45, .medium, work, 1),
            ("Prep 1:1 agenda", 30, .medium, work, 2),
            ("Update onboarding doc", 60, .low, work, 3),
            ("Book dentist appointment", 15, .low, personal, 5),
            ("Order new keyboard", 15, .none, personal, 6),
            ("Draft launch email", 90, .high, side, 2),
            ("Record demo video", 120, .high, side, 3),
            ("Collect feedback from 3 testers", 45, .medium, side, 1)
        ]

        let allTasks: [TaskItem] = [report, invoices, bookshelf, standup, call, tax]
            + smallTasks.map { title, minutes, priority, list, days in
                let task = TaskItem(
                    title: title,
                    estimateMinutes: minutes,
                    priority: priority,
                    deadline: calendar.date(byAdding: .day, value: days, to: now),
                    list: list
                )
                if priority == .high { task.isHardDeadline = true }
                return task
            }

        allTasks.forEach(context.insert)
        try? context.save()
    }
}
