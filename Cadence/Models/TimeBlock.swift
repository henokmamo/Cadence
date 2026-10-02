//
//  TimeBlock.swift
//  Cadence
//
//  A scheduled slice of a task on the calendar. Auto blocks are owned by the
//  scheduling engine; `user` and `imported` blocks are immovable busy time.
//

import Foundation
import SwiftData

@Model
final class TimeBlock {
    var id: UUID = UUID()
    var start: Date = Date.now
    var end: Date = Date.now.addingTimeInterval(30 * 60)

    var isPinned: Bool = false
    var isUserCreated: Bool = false
    var originRaw: String = BlockOrigin.auto.rawValue

    /// Set when the block mirrors an EventKit event, so re-imports can reconcile
    /// instead of duplicating.
    var externalEventID: String?

    /// Soft-delete tombstone: CloudKit-friendly, keeps undo possible.
    var isSoftDeleted: Bool = false

    var task: TaskItem?

    init(
        start: Date,
        end: Date,
        origin: BlockOrigin = .auto,
        isPinned: Bool = false,
        externalEventID: String? = nil,
        task: TaskItem? = nil
    ) {
        self.id = UUID()
        self.start = start
        self.end = end
        self.originRaw = origin.rawValue
        self.isPinned = isPinned
        self.isUserCreated = (origin == .user)
        self.externalEventID = externalEventID
        self.task = task
    }

    var origin: BlockOrigin {
        get { BlockOrigin(rawValue: originRaw) ?? .auto }
        set { originRaw = newValue.rawValue }
    }

    var durationMinutes: Int {
        max(0, Int(end.timeIntervalSince(start) / 60))
    }

    /// Blocks the engine may move or delete. Anything else is busy time.
    var isEngineOwned: Bool {
        origin == .auto && !isPinned && !isUserCreated
    }

    var dateInterval: DateInterval {
        DateInterval(start: start, end: max(end, start.addingTimeInterval(60)))
    }

    func overlaps(_ other: TimeBlock) -> Bool {
        start < other.end && other.start < end
    }

    func contains(_ date: Date) -> Bool {
        start <= date && date < end
    }
}
