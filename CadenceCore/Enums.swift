//
//  Enums.swift
//  Cadence
//
//  Shared value types used across models, the scheduling engine and the UI.
//  Raw values are what get persisted; the enums themselves are ergonomic wrappers.
//

import Foundation

// MARK: - Priority

enum TaskPriority: Int, CaseIterable, Codable, Identifiable, Sendable {
    case none = 0
    case low = 1
    case medium = 2
    case high = 3

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .none: return "None"
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        }
    }

    var symbolName: String {
        switch self {
        case .none: return "minus"
        case .low: return "arrow.down"
        case .medium: return "equal"
        case .high: return "exclamationmark"
        }
    }
}

// MARK: - Status

enum TaskStatus: String, CaseIterable, Codable, Sendable {
    case open
    case completed
    case cancelled

    var label: String {
        switch self {
        case .open: return "Open"
        case .completed: return "Completed"
        case .cancelled: return "Cancelled"
        }
    }
}

// MARK: - Repetition

enum RepeatFrequency: String, CaseIterable, Codable, Identifiable, Sendable {
    case daily
    case weekly
    case monthly
    case yearly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        }
    }
}

// MARK: - Time blocks

/// Where a block came from. `auto` blocks are owned by the scheduler and may be
/// moved on the next reshuffle; everything else is treated as immovable busy time.
enum BlockOrigin: String, CaseIterable, Codable, Sendable {
    case auto
    case user
    case imported

    var label: String {
        switch self {
        case .auto: return "Auto-scheduled"
        case .user: return "Added by you"
        case .imported: return "From Calendar"
        }
    }
}

// MARK: - Scheduling outcome

enum ScheduleStatus: Equatable, Sendable {
    case scheduled
    case pinned
    case partial(remainingMinutes: Int)
    case unscheduled(reason: String)

    var isFullyPlaced: Bool {
        switch self {
        case .scheduled, .pinned: return true
        case .partial, .unscheduled: return false
        }
    }
}

// MARK: - Small helpers

extension Int {
    /// "1h 30m", "45m", "2h"
    var abbreviatedDuration: String {
        // NB: `max` must be qualified — inside an Int extension the unqualified name
        // resolves to the static property `Int.max`, not the global function.
        let minutes = Swift.max(0, self)
        let hours = minutes / 60
        let mins = minutes % 60
        if hours == 0 { return "\(mins)m" }
        if mins == 0 { return "\(hours)h" }
        return "\(hours)h \(mins)m"
    }
}

extension Date {
    func roundedDown(toMinutes step: Int, calendar: Calendar = .current) -> Date {
        guard step > 0 else { return self }
        let seconds = timeIntervalSinceReferenceDate
        let stepSeconds = TimeInterval(step * 60)
        return Date(timeIntervalSinceReferenceDate: (seconds / stepSeconds).rounded(.down) * stepSeconds)
    }
}
