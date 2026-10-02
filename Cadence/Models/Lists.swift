//
//  Lists.swift
//  Cadence
//
//  TaskList, Tag, Subtask and the scheduling log.
//

import Foundation
import SwiftData

@Model
final class TaskList {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#5A6CF3"
    var symbolName: String = "folder"
    var sortIndex: Double = 0
    var isArchived: Bool = false
    var isInbox: Bool = false
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \TaskItem.list)
    var tasks: [TaskItem] = []

    init(
        name: String,
        colorHex: String = "#5A6CF3",
        symbolName: String = "folder",
        sortIndex: Double = 0,
        isInbox: Bool = false
    ) {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
        self.symbolName = symbolName
        self.sortIndex = sortIndex
        self.isInbox = isInbox
    }

    var openTasks: [TaskItem] {
        tasks.filter { $0.isOpen && !$0.isSoftDeleted }
    }
}

@Model
final class Tag {
    var id: UUID = UUID()
    var name: String = ""
    var colorHex: String = "#8E8E93"
    var createdAt: Date = Date.now

    var tasks: [TaskItem] = []

    init(name: String, colorHex: String = "#8E8E93") {
        self.id = UUID()
        self.name = name
        self.colorHex = colorHex
    }
}

@Model
final class Subtask {
    var id: UUID = UUID()
    var title: String = ""
    var isDone: Bool = false
    var sortIndex: Double = 0
    var createdAt: Date = Date.now

    var parent: TaskItem?

    init(title: String, isDone: Bool = false, sortIndex: Double = 0) {
        self.id = UUID()
        self.title = title
        self.isDone = isDone
        self.sortIndex = sortIndex
    }
}

/// One row per scheduling decision. Powers the "why is this here?" explainability
/// UI, the undo toast, and debugging in TestFlight feedback.
@Model
final class SchedulingLogEntry {
    var id: UUID = UUID()
    var runID: UUID = UUID()
    var taskID: UUID?
    var taskTitle: String = ""
    var placedAt: Date = Date.now
    var outcomeRaw: String = "scheduled"
    var reason: String = ""
    var plannedStart: Date?
    var plannedMinutes: Int = 0

    init(
        runID: UUID,
        taskID: UUID?,
        taskTitle: String,
        outcome: String,
        reason: String,
        plannedStart: Date? = nil,
        plannedMinutes: Int = 0
    ) {
        self.id = UUID()
        self.runID = runID
        self.taskID = taskID
        self.taskTitle = taskTitle
        self.outcomeRaw = outcome
        self.reason = reason
        self.plannedStart = plannedStart
        self.plannedMinutes = plannedMinutes
    }
}
