//
//  TaskIntents.swift
//  Cadence  (compiled into BOTH the app and the CadenceWidget extension)
//
//  Interactive App Intents used by widgets, the lock screen and Siri.
//
//  Architecture note: intents fired from a widget button run in the *widget* process.
//  Rather than opening a second SwiftData container there (migration skew risk), they
//  (a) update the shared snapshot optimistically so the UI reacts instantly, and
//  (b) append a `PendingTaskAction` to an App Group queue that the app drains the moment
//  it becomes active, performs against the real store, and then reschedules the day.
//  The 1.0 app keeps a BGAppRefreshTask that drains the queue when the system allows it.
//

import AppIntents
import Foundation
import WidgetKit

// MARK: - Pending action queue (App Group)

enum TaskActionKind: String, Codable, Sendable {
    case complete
    case snooze15
    case skipBlock
    case rescheduleDay
}

struct PendingTaskAction: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var kind: TaskActionKind
    var taskID: UUID?
    var blockID: UUID?
    var createdAt: Date = .now
}

enum PendingActionQueue {
    private static let key = "pendingActions.v1"

    static func enqueue(_ action: PendingTaskAction) {
        var actions = pending()
        actions.append(action)
        write(actions)
    }

    static func pending() -> [PendingTaskAction] {
        guard let data = WidgetSnapshotStore.defaults.data(forKey: key),
              let actions = try? JSONDecoder().decode([PendingTaskAction].self, from: data) else {
            return []
        }
        return actions
    }

    static func clear() { write([]) }

    private static func write(_ actions: [PendingTaskAction]) {
        guard let data = try? JSONEncoder().encode(actions) else { return }
        WidgetSnapshotStore.defaults.set(data, forKey: key)
    }
}

// MARK: - Intents

struct CompleteTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Complete task"
    static var description = IntentDescription("Mark the task as done and close the gap in your day.")
    /// Runs without launching the app; the queue syncs on next activation.
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Task ID")
    var taskID: String

    init() {}

    init(taskID: UUID) { self.taskID = taskID.uuidString }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: taskID) else { return .result() }
        WidgetSnapshotStore.markCompleted(taskID: id)
        PendingActionQueue.enqueue(PendingTaskAction(kind: .complete, taskID: id))
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct SnoozeBlockIntent: AppIntent {
    static var title: LocalizedStringResource = "Snooze 15 minutes"
    static var description = IntentDescription("Push the current block back by 15 minutes.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Block ID")
    var blockID: String

    @Parameter(title: "Minutes", default: 15)
    var minutes: Int

    init() {}

    init(blockID: UUID, minutes: Int = 15) {
        self.blockID = blockID.uuidString
        self.minutes = minutes
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: blockID) else { return .result() }
        WidgetSnapshotStore.markBlockSnoozed(blockID: id, minutes: minutes)
        PendingActionQueue.enqueue(PendingTaskAction(kind: .snooze15, blockID: id))
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct RescheduleDayIntent: AppIntent {
    static var title: LocalizedStringResource = "Reschedule my day"
    static var description = IntentDescription("Re-plan everything that hasn't started yet.")
    static var openAppWhenRun: Bool = false

    init() {}

    func perform() async throws -> some IntentResult {
        PendingActionQueue.enqueue(PendingTaskAction(kind: .rescheduleDay))
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

struct AddTaskIntent: AppIntent {
    static var title: LocalizedStringResource = "Add a task"
    static var description = IntentDescription("Capture a task and let Cadence find time for it.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Title")
    var title: String

    @Parameter(title: "Estimate in minutes", default: 30)
    var estimateMinutes: Int

    init() {}

    init(title: String, estimateMinutes: Int = 30) {
        self.title = title
        self.estimateMinutes = estimateMinutes
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        AppGroupCaptureQueue.enqueue(title: title, estimateMinutes: estimateMinutes)
        return .result(dialog: "Added “\(title)” — Cadence will find time for it.")
    }
}

// MARK: - Capture queue (quick add from Siri / widget)

enum AppGroupCaptureQueue {
    private static let key = "pendingCaptures.v1"

    struct Capture: Codable, Identifiable, Sendable {
        var id: UUID = UUID()
        var title: String
        var estimateMinutes: Int
        var createdAt: Date = .now
    }

    static func enqueue(title: String, estimateMinutes: Int) {
        var items = pending()
        items.append(Capture(title: title, estimateMinutes: estimateMinutes))
        guard let data = try? JSONEncoder().encode(items) else { return }
        WidgetSnapshotStore.defaults.set(data, forKey: key)
    }

    static func pending() -> [Capture] {
        guard let data = WidgetSnapshotStore.defaults.data(forKey: key),
              let items = try? JSONDecoder().decode([Capture].self, from: data) else { return [] }
        return items
    }

    static func clear() { WidgetSnapshotStore.defaults.set(Data(), forKey: key) }
}
