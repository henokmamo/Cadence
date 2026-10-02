//
//  WidgetSnapshot.swift
//  Cadence  (compiled into BOTH the app and the CadenceWidget extension)
//
//  The widget is a separate process and must not open a SwiftData store it doesn't
//  own (migration skew between processes is a classic source of data loss). Instead
//  the app writes this small, versioned JSON snapshot into the shared App Group on
//  every plan change; the widget only ever reads it.
//
//  Deliberately tiny (a few KB) so writes are ~free and timeline reloads are cheap.
//

import Foundation

struct WidgetBlockSnapshot: Codable, Hashable, Identifiable {
    var id: UUID
    var taskID: UUID
    var title: String
    var start: Date
    var end: Date
    var isPinned: Bool
    var listColorHex: String?

    var durationMinutes: Int { max(0, Int(end.timeIntervalSince(start) / 60)) }

    func contains(_ date: Date) -> Bool { start <= date && date < end }
}

struct WidgetSnapshot: Codable, Hashable {
    var schemaVersion: Int = 1
    var generatedAt: Date
    /// Blocks for the current day, sorted by start.
    var todayBlocks: [WidgetBlockSnapshot]
    var nextBlock: WidgetBlockSnapshot?
    var overdueCount: Int
    var plannedMinutesToday: Int
    var completedMinutesToday: Int
    /// Titles of tasks the engine could not fully place — the honest part of the UI.
    var atRiskTitles: [String]
    var openTaskCount: Int
    var isProActive: Bool = true

    static let empty = WidgetSnapshot(
        generatedAt: .distantPast,
        todayBlocks: [],
        nextBlock: nil,
        overdueCount: 0,
        plannedMinutesToday: 0,
        completedMinutesToday: 0,
        atRiskTitles: [],
        openTaskCount: 0
    )

    func currentBlock(at date: Date) -> WidgetBlockSnapshot? {
        todayBlocks.first { $0.contains(date) }
    }

    func upcomingBlocks(after date: Date) -> [WidgetBlockSnapshot] {
        todayBlocks.filter { $0.start > date }.sorted { $0.start < $1.start }
    }

    var remainingMinutesToday: Int {
        max(0, plannedMinutesToday - completedMinutesToday)
    }
}

// MARK: - Shared storage

enum WidgetSnapshotStore {

    static let appGroupID = "group.com.example.cadence"
    private static let key = "widgetSnapshot.v1"

    static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    static func load() -> WidgetSnapshot? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(WidgetSnapshot.self, from: data)
    }

    static func save(_ snapshot: WidgetSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: key)
    }

    /// Optimistic local update so an interactive widget button feels instant, before
    /// the app process gets a chance to reschedule (see PendingActionQueue).
    static func markCompleted(taskID: UUID, at date: Date = .now) {
        guard var snapshot = load() else { return }
        let finished = snapshot.todayBlocks.filter { $0.taskID == taskID }
        snapshot.todayBlocks.removeAll { $0.taskID == taskID }
        snapshot.completedMinutesToday += finished.reduce(0) { $0 + $1.durationMinutes }
        snapshot.plannedMinutesToday = max(snapshot.completedMinutesToday, snapshot.plannedMinutesToday)
        snapshot.nextBlock = snapshot.upcomingBlocks(after: date).first
        snapshot.generatedAt = date
        save(snapshot)
    }

    static func markBlockSnoozed(blockID: UUID, minutes: Int, at date: Date = .now) {
        guard var snapshot = load(),
              let index = snapshot.todayBlocks.firstIndex(where: { $0.id == blockID }) else { return }
        var block = snapshot.todayBlocks[index]
        block.start = block.start.addingTimeInterval(TimeInterval(minutes * 60))
        block.end = block.end.addingTimeInterval(TimeInterval(minutes * 60))
        block.isPinned = true
        snapshot.todayBlocks[index] = block
        snapshot.todayBlocks.sort { $0.start < $1.start }
        snapshot.nextBlock = snapshot.upcomingBlocks(after: date).first
        snapshot.generatedAt = date
        save(snapshot)
    }
}
