//
//  WidgetSnapshotWriter.swift
//  Cadence
//
//  Builds the App Group snapshot the widget reads. Called after every plan change,
//  task mutation, completion and on foreground.
//

import Foundation
import SwiftData
import WidgetKit

struct WidgetSnapshotWriter {

    func write(from context: ModelContext, now: Date = .now) {
        let snapshot = build(from: context, now: now)
        WidgetSnapshotStore.save(snapshot)
        WidgetCenter.shared.reloadAllTimelines()
    }

    func build(from context: ModelContext, now: Date = .now) -> WidgetSnapshot {
        let calendar = Calendar.current
        let startOfDay = calendar.startOfDay(for: now)
        let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) ?? now

        let blockDescriptor = FetchDescriptor<TimeBlock>(
            predicate: #Predicate { $0.start < endOfDay && $0.start >= startOfDay && $0.isSoftDeleted == false },
            sortBy: [SortDescriptor(\.start)]
        )
        let blocks = (try? context.fetch(blockDescriptor)) ?? []

        let taskDescriptor = FetchDescriptor<TaskItem>(
            predicate: #Predicate { $0.statusRaw == "open" && $0.isSoftDeleted == false }
        )
        let openTasks = (try? context.fetch(taskDescriptor)) ?? []

        let blockSnapshots: [WidgetBlockSnapshot] = blocks.compactMap { block in
            guard let task = block.task else { return nil }
            return WidgetBlockSnapshot(
                id: block.id,
                taskID: task.id,
                title: task.displayTitle,
                start: block.start,
                end: block.end,
                isPinned: block.isPinned,
                listColorHex: task.list?.colorHex
            )
        }

        let completedMinutes = blocks
            .filter { $0.task?.isCompleted == true }
            .reduce(0) { $0 + $1.durationMinutes }

        let overdueCount = openTasks.filter(\.isOverdue).count

        let soon = now.addingTimeInterval(48 * 3600)
        let atRisk = openTasks.filter { task in
            guard let deadline = task.deadline, deadline <= soon, deadline > now else { return false }
            return task.remainingMinutes > 0
        }

        let nextBlock = blockSnapshots
            .filter { $0.start > now }
            .sorted { $0.start < $1.start }
            .first

        return WidgetSnapshot(
            generatedAt: now,
            todayBlocks: blockSnapshots,
            nextBlock: nextBlock,
            overdueCount: overdueCount,
            plannedMinutesToday: blockSnapshots.reduce(0) { $0 + $1.durationMinutes },
            completedMinutesToday: completedMinutes,
            atRiskTitles: atRisk.prefix(3).map(\.displayTitle),
            openTaskCount: openTasks.count
        )
    }
}
