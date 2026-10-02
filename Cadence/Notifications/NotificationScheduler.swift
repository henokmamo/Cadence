//
//  NotificationScheduler.swift
//  Cadence
//
//  Local notifications only — no push server in v1.
//
//  iOS keeps at most 64 pending local notifications, so we keep a rolling window of
//  the next `maxPending` events (≈7 days) and refill it on every plan change, on
//  foreground, and from a BGAppRefreshTask.
//
//  Notification actions (Complete / Snooze 15m / Skip) are handled by App Intents so
//  they work straight from the lock screen without launching the UI.
//

import Foundation
import SwiftData
import UserNotifications

@MainActor
final class NotificationScheduler {

    static let blockStartCategory = "CADENCE_BLOCK_START"
    static let deadlineCategory = "CADENCE_DEADLINE"
    static let digestIdentifier = "CADENCE_DIGEST"

    /// Identifier prefixes so we can find and replace our own requests without
    /// touching anything else.
    private enum Prefix {
        static let block = "cadence.block."
        static let deadline = "cadence.deadline."
    }

    private let center = UNUserNotificationCenter.current()
    private let maxPending = 48

    // MARK: - Registration

    /// Called once at launch: registers categories and refreshes the plan's notifications.
    func configure() {
        let complete = UNNotificationAction(
            identifier: "CADENCE_ACTION_COMPLETE",
            title: "Complete",
            options: []
        )
        let snooze = UNNotificationAction(
            identifier: "CADENCE_ACTION_SNOOZE_15",
            title: "Snooze 15 min",
            options: []
        )
        let skip = UNNotificationAction(
            identifier: "CADENCE_ACTION_SKIP",
            title: "Skip this block",
            options: [.destructive]
        )

        let blockCategory = UNNotificationCategory(
            identifier: Self.blockStartCategory,
            actions: [complete, snooze, skip],
            intentIdentifiers: [],
            options: []
        )
        let deadlineCategory = UNNotificationCategory(
            identifier: Self.deadlineCategory,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([blockCategory, deadlineCategory])
    }

    func requestAuthorization() async -> Bool {
        do {
            return try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            return false
        }
    }

    func authorizationStatus() async -> UNAuthorizationStatus {
        await center.notificationSettings().authorizationStatus
    }

    // MARK: - Refresh

    /// Rebuild the pending-notification window from the current plan.
    func refresh(now: Date = .now, preferences: Preferences, context: ModelContext) {
        center.removeAllPendingNotificationRequests()

        guard preferences.notificationsAreOn else { return }

        let calendar = Calendar.current
        let windowEnd = calendar.date(byAdding: .day, value: 7, to: now) ?? now
        let blocks = fetchUpcomingBlocks(from: now, to: windowEnd, context: context)
        var scheduled = 0
        var scheduledTimes: [Date] = []

        if preferences.blockStartNotifications {
            for block in blocks where scheduled < maxPending {
                guard let task = block.task, task.isOpen else { continue }
                let fireDate = block.start.addingTimeInterval(-60)   // 1 minute before, felt as "now"
                guard fireDate > now else { continue }
                guard !isQuietHours(fireDate, preferences: preferences) else { continue }
                // Never stack two notifications on top of each other.
                guard !scheduledTimes.contains(where: { abs($0.timeIntervalSince(fireDate)) < 120 }) else { continue }
                scheduledTimes.append(fireDate)

                let content = UNMutableNotificationContent()
                content.title = "Starting now"
                content.body = "\(task.displayTitle) · \(block.durationMinutes.abbreviatedDuration)"
                content.sound = .default
                content.categoryIdentifier = Self.blockStartCategory
                content.userInfo = [
                    "blockID": block.id.uuidString,
                    "taskID": task.id.uuidString,
                    "kind": "block"
                ]

                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents(
                        [.year, .month, .day, .hour, .minute, .second], from: fireDate
                    ),
                    repeats: false
                )
                center.add(UNNotificationRequest(
                    identifier: Prefix.block + block.id.uuidString,
                    content: content,
                    trigger: trigger
                ))
                scheduled += 1
            }
        }

        if preferences.deadlineWarningsEnabled {
            for report in atRiskTasks(now: now, context: context) where scheduled < maxPending {
                guard let deadline = report.deadline, deadline > now else { continue }
                let fireDate = deadline.addingTimeInterval(-24 * 3600)
                guard fireDate > now, !isQuietHours(fireDate, preferences: preferences) else { continue }

                let content = UNMutableNotificationContent()
                content.title = "Won't fit before the deadline"
                content.body = "\(report.title) still needs \(report.remainingMinutes.abbreviatedDuration) "
                    + "before \(RelativeDateFormatter.stamp(deadline))."
                content.sound = .default
                content.categoryIdentifier = Self.deadlineCategory
                content.userInfo = ["taskID": report.id.uuidString, "kind": "deadline"]

                let trigger = UNCalendarNotificationTrigger(
                    dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate),
                    repeats: false
                )
                center.add(UNNotificationRequest(
                    identifier: Prefix.deadline + report.id.uuidString,
                    content: content,
                    trigger: trigger
                ))
                scheduled += 1
            }
        }

        if preferences.morningDigestEnabled {
            let content = UNMutableNotificationContent()
            content.title = "Your day, planned"
            content.body = digestBody(now: now, context: context)
            content.sound = .default
            content.userInfo = ["kind": "digest"]

            var components = DateComponents()
            components.hour = preferences.digestMinutesFromMidnight / 60
            components.minute = preferences.digestMinutesFromMidnight % 60
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            center.add(UNNotificationRequest(
                identifier: Self.digestIdentifier,
                content: content,
                trigger: trigger
            ))
        }
    }

    // MARK: - Helpers

    private func fetchUpcomingBlocks(from: Date, to: Date, context: ModelContext) -> [TimeBlock] {
        let descriptor = FetchDescriptor<TimeBlock>(
            predicate: #Predicate { $0.start >= from && $0.start <= to && $0.isSoftDeleted == false },
            sortBy: [SortDescriptor(\.start)]
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private struct AtRiskTask {
        let id: UUID
        let title: String
        let deadline: Date
        let remainingMinutes: Int
    }

    private func atRiskTasks(now: Date, context: ModelContext) -> [AtRiskTask] {
        let descriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "open" && $0.isSoftDeleted == false }
        )
        let tasks = (try? context.fetch(descriptor)) ?? []
        return tasks.compactMap { task in
            guard let deadline = task.deadline, deadline > now else { return nil }
            let placable = task.blocks.filter { $0.end <= deadline }.reduce(0) { $0 + $1.durationMinutes }
            let remaining = max(0, task.estimateMinutes - placable)
            guard remaining > 0 else { return nil }
            return AtRiskTask(id: task.id, title: task.displayTitle, deadline: deadline, remainingMinutes: remaining)
        }
    }

    private func digestBody(now: Date, context: ModelContext) -> String {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else { return "Nothing planned yet." }
        let blocks = fetchUpcomingBlocks(from: startOfDay, to: endOfDay, context: context)
            .filter { $0.task?.isOpen == true }

        guard !blocks.isEmpty else { return "Nothing scheduled — a clean slate." }

        let plannedMinutes = blocks.reduce(0) { $0 + $1.durationMinutes }
        let first = blocks.first
        var body = "\(blocks.count) block\(blocks.count == 1 ? "" : "s") today · "
            + "\(plannedMinutes.abbreviatedDuration) planned"
        if let first {
            body += " · first at \(RelativeDateFormatter.time(first.start))"
        }
        let overdue = blocks.filter { $0.task?.isOverdue == true }.count
        if overdue > 0 { body += " · \(overdue) overdue" }
        return body
    }

    private func isQuietHours(_ date: Date, preferences: Preferences) -> Bool {
        let calendar = Calendar.current
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let start = preferences.quietHoursStartMinutes
        let end = preferences.quietHoursEndMinutes
        if start == end { return false }
        if start < end { return minutes >= start && minutes < end }
        return minutes >= start || minutes < end       // wraps midnight
    }
}
