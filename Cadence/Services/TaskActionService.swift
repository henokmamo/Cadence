//
//  TaskActionService.swift
//  Cadence
//
//  Single funnel for "something happened to a task/block", wherever it came from:
//  the UI, a notification action, a widget button, Siri, or a queued App Group action.
//  Everything ends up going through ScheduleCoordinator, so behaviour is identical
//  no matter where the tap came from.
//

import Foundation
import SwiftData
import UserNotifications

@MainActor
final class TaskActionService {

    private let context: ModelContext
    private let coordinator: ScheduleCoordinator
    private let preferences: Preferences
    private let snapshotWriter = WidgetSnapshotWriter()

    init(context: ModelContext, coordinator: ScheduleCoordinator, preferences: Preferences) {
        self.context = context
        self.coordinator = coordinator
        self.preferences = preferences
    }

    // MARK: - Public actions

    func complete(taskID: UUID, now: Date = .now) {
        guard let task = task(withID: taskID) else { return }
        coordinator.complete(task: task, at: now)
    }

    func complete(blockID: UUID, now: Date = .now) {
        guard let block = block(withID: blockID), let task = block.task else { return }
        coordinator.complete(task: task, at: now)
    }

    func snooze(blockID: UUID, minutes: Int = 15, now: Date = .now) {
        guard let block = block(withID: blockID) else { return }
        coordinator.move(
            block: block,
            to: block.start.addingTimeInterval(TimeInterval(minutes * 60)),
            durationMinutes: block.durationMinutes,
            now: now
        )
    }

    /// "Skip this block": drop the block without completing the task, then let the
    /// engine find another home for the remaining work later in the week.
    func skip(blockID: UUID, now: Date = .now) {
        guard let block = block(withID: blockID) else { return }
        context.delete(block)
        try? context.save()
        coordinator.reschedule(reason: .blockMoved, now: now)
    }

    func rescheduleDay(now: Date = .now) {
        coordinator.reschedule(reason: .manual, now: now)
    }

    func capture(title: String, estimateMinutes: Int, now: Date = .now) {
        let inbox = fetchOrCreateInbox()
        let task = TaskItem(
            title: title,
            estimateMinutes: estimateMinutes,
            list: inbox,
            createdAt: now
        )
        context.insert(task)
        try? context.save()
        coordinator.reschedule(reason: .taskChanged, now: now)
    }

    // MARK: - Drain external inputs

    /// Called on launch/foreground: applies everything queued from widgets, Siri and
    /// notification actions, then refreshes the plan once.
    func drainPendingWork(now: Date = .now) {
        let actions = PendingActionQueue.pending()
        let captures = AppGroupCaptureQueue.pending()
        guard !actions.isEmpty || !captures.isEmpty else { return }
        PendingActionQueue.clear()
        AppGroupCaptureQueue.clear()

        for queued in captures {
            capture(title: queued.title, estimateMinutes: queued.estimateMinutes, now: now)
        }

        var needsReschedule = false
        for action in actions {
            switch action.kind {
            case .complete:
                if let taskID = action.taskID { complete(taskID: taskID, now: now) }
            case .snooze15:
                if let blockID = action.blockID { snooze(blockID: blockID, now: now) }
            case .skipBlock:
                if let blockID = action.blockID { skip(blockID: blockID, now: now) }
            case .rescheduleDay:
                needsReschedule = true
            }
        }

        if needsReschedule {
            coordinator.reschedule(reason: .widgetAction, now: now)
        } else {
            snapshotWriter.write(from: context, now: now)
        }
    }

    /// Handles notification actions delivered by the system.
    func handleNotificationAction(identifier: String, userInfo: [AnyHashable: Any], now: Date = .now) {
        switch identifier {
        case "CADENCE_ACTION_COMPLETE":
            if let raw = userInfo["taskID"] as? String, let id = UUID(uuidString: raw) {
                complete(taskID: id, now: now)
            }
        case "CADENCE_ACTION_SNOOZE_15":
            if let raw = userInfo["blockID"] as? String, let id = UUID(uuidString: raw) {
                snooze(blockID: id, minutes: 15, now: now)
            }
            if let raw = userInfo["taskID"] as? String, let id = UUID(uuidString: raw),
               let task = task(withID: id) {
                coordinator.snoozeCurrentBlock(of: task, minutes: 15, now: now)
            }
        case "CADENCE_ACTION_SKIP":
            if let raw = userInfo["blockID"] as? String, let id = UUID(uuidString: raw) {
                skip(blockID: id, now: now)
            }
        default:
            break
        }
    }

    // MARK: - Lookups

    private func task(withID id: UUID) -> TaskItem? {
        let descriptor = FetchDescriptor<TaskItem>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    private func block(withID id: UUID) -> TimeBlock? {
        let descriptor = FetchDescriptor<TimeBlock>(predicate: #Predicate { $0.id == id })
        return (try? context.fetch(descriptor))?.first
    }

    private func fetchOrCreateInbox() -> TaskList {
        let descriptor = FetchDescriptor<TaskList>(predicate: #Predicate { $0.isInbox == true })
        if let existing = (try? context.fetch(descriptor))?.first { return existing }
        let inbox = TaskList(name: "Inbox", colorHex: "#5A6CF3", symbolName: "tray", sortIndex: 0, isInbox: true)
        context.insert(inbox)
        return inbox
    }

    // MARK: - Notification delegate bridge

    /// Wired up from `AppDelegate`, keeps UNUserNotificationCenter delegate logic out of SwiftUI.
    static func handleRemoteNotificationPayload(_ userInfo: [AnyHashable: Any]) -> Bool {
        userInfo["kind"] != nil
    }
}
