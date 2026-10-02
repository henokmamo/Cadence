//
//  Preferences.swift
//  Cadence
//
//  User settings. Backed by UserDefaults so the widget extension and App Intents
//  can read the same values without a SwiftData fetch. (The widget process is a
//  separate process; UserDefaults in an App Group is the cheap, reliable channel.)
//

import Foundation
import Observation

@Observable
final class Preferences {

    static let appGroupID = "group.com.example.cadence"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private let store: UserDefaults

    init(store: UserDefaults? = nil) {
        self.store = store ?? Preferences.defaults
        self.workingWindows = Self.loadWindows(from: self.store)
        self.bufferMinutes = self.store.object(forKey: Key.buffer) as? Int ?? 10
        self.minChunkMinutes = self.store.object(forKey: Key.minChunk) as? Int ?? 15
        self.maxChunkMinutes = self.store.object(forKey: Key.maxChunk) as? Int ?? 90
        self.maxChunksPerTask = self.store.object(forKey: Key.maxChunks) as? Int ?? 3
        self.dailyAutoMinutesCap = self.store.object(forKey: Key.dailyCap) as? Int ?? 240
        self.horizonDays = self.store.object(forKey: Key.horizon) as? Int ?? 14
        self.edfEnabled = self.store.object(forKey: Key.edf) as? Bool ?? true
        self.importCalendarEnabled = self.store.object(forKey: Key.importCalendar) as? Bool ?? false
        self.excludedCalendarIDs = Set(self.store.stringArray(forKey: Key.excludedCalendars) ?? [])
        self.blockStartNotifications = self.store.object(forKey: Key.blockStartNotif) as? Bool ?? true
        self.notificationsAreOn = self.store.object(forKey: Key.notificationsOn) as? Bool ?? false
        self.morningDigestEnabled = self.store.object(forKey: Key.digestOn) as? Bool ?? true
        self.deadlineWarningsEnabled = self.store.object(forKey: Key.deadlineWarn) as? Bool ?? true
        self.digestMinutesFromMidnight =
            self.store.object(forKey: Key.digestTime) as? Int ?? (7 * 60 + 30)
        self.quietHoursStartMinutes = self.store.object(forKey: Key.quietStart) as? Int ?? (21 * 60)
        self.quietHoursEndMinutes = self.store.object(forKey: Key.quietEnd) as? Int ?? (7 * 60)
        self.pullsBlocksForwardOnCompletion = self.store.object(forKey: Key.pullForward) as? Bool ?? false
        self.hasCompletedOnboarding = self.store.object(forKey: Key.onboarded) as? Bool ?? false
    }

    // MARK: - Working hours

    var workingWindows: [WorkingWindow] {
        didSet { saveWindows() }
    }

    // MARK: - Scheduling

    var bufferMinutes: Int {
        didSet { store.set(bufferMinutes, forKey: Key.buffer) }
    }

    var minChunkMinutes: Int {
        didSet { store.set(minChunkMinutes, forKey: Key.minChunk) }
    }

    var maxChunkMinutes: Int {
        didSet { store.set(maxChunkMinutes, forKey: Key.maxChunk) }
    }

    var maxChunksPerTask: Int {
        didSet { store.set(maxChunksPerTask, forKey: Key.maxChunks) }
    }

    var dailyAutoMinutesCap: Int {
        didSet { store.set(dailyAutoMinutesCap, forKey: Key.dailyCap) }
    }

    var horizonDays: Int {
        didSet { store.set(horizonDays, forKey: Key.horizon) }
    }

    /// Deadlines first (EDF) vs. priority first.
    var edfEnabled: Bool {
        didSet { store.set(edfEnabled, forKey: Key.edf) }
    }

    /// Calm by default: finishing early does **not** silently yank the next block
    /// forward. The gap stays free and the user is *offered* a pull-forward instead
    /// (a "calm" answer to SPEC §15.4 — the aggressive setting exists, off by default).
    var pullsBlocksForwardOnCompletion: Bool {
        didSet { store.set(pullsBlocksForwardOnCompletion, forKey: Key.pullForward) }
    }

    // MARK: - Calendar import

    var importCalendarEnabled: Bool {
        didSet { store.set(importCalendarEnabled, forKey: Key.importCalendar) }
    }

    var excludedCalendarIDs: Set<String> {
        didSet { store.set(Array(excludedCalendarIDs), forKey: Key.excludedCalendars) }
    }

    // MARK: - Notifications

    var notificationsAreOn: Bool {
        didSet { store.set(notificationsAreOn, forKey: Key.notificationsOn) }
    }

    var blockStartNotifications: Bool {
        didSet { store.set(blockStartNotifications, forKey: Key.blockStartNotif) }
    }

    var morningDigestEnabled: Bool {
        didSet { store.set(morningDigestEnabled, forKey: Key.digestOn) }
    }

    var deadlineWarningsEnabled: Bool {
        didSet { store.set(deadlineWarningsEnabled, forKey: Key.deadlineWarn) }
    }

    var digestMinutesFromMidnight: Int {
        didSet { store.set(digestMinutesFromMidnight, forKey: Key.digestTime) }
    }

    var quietHoursStartMinutes: Int {
        didSet { store.set(quietHoursStartMinutes, forKey: Key.quietStart) }
    }

    var quietHoursEndMinutes: Int {
        didSet { store.set(quietHoursEndMinutes, forKey: Key.quietEnd) }
    }

    var hasCompletedOnboarding: Bool {
        didSet { store.set(hasCompletedOnboarding, forKey: Key.onboarded) }
    }

    // MARK: - Bridge to the engine

    var schedulingPolicy: SchedulingPolicy {
        var policy = SchedulingPolicy()
        policy.bufferMinutes = bufferMinutes
        policy.minChunkMinutes = minChunkMinutes
        policy.maxChunkMinutes = maxChunkMinutes
        policy.maxChunksPerTask = maxChunksPerTask
        policy.dailyAutoMinutesCap = dailyAutoMinutesCap
        policy.horizonDays = horizonDays
        policy.edfEnabled = edfEnabled
        return policy
    }

    // MARK: - Persistence helpers

    private enum Key {
        static let windows = "workingWindows.v1"
        static let buffer = "policy.buffer"
        static let minChunk = "policy.minChunk"
        static let maxChunk = "policy.maxChunk"
        static let maxChunks = "policy.maxChunks"
        static let dailyCap = "policy.dailyCap"
        static let horizon = "policy.horizon"
        static let edf = "policy.edf"
        static let pullForward = "policy.pullForwardOnCompletion"
        static let importCalendar = "calendar.import"
        static let excludedCalendars = "calendar.excluded"
        static let notificationsOn = "notifications.on"
        static let blockStartNotif = "notifications.blockStart"
        static let digestOn = "notifications.digest"
        static let deadlineWarn = "notifications.deadline"
        static let digestTime = "notifications.digestTime"
        static let quietStart = "notifications.quietStart"
        static let quietEnd = "notifications.quietEnd"
        static let onboarded = "onboarding.done"
    }

    private static func loadWindows(from store: UserDefaults) -> [WorkingWindow] {
        guard let data = store.data(forKey: Key.windows),
              let decoded = try? JSONDecoder().decode([WorkingWindow].self, from: data),
              !decoded.isEmpty else {
            return WorkingHours.defaultWindows
        }
        return decoded.sorted { ($0.weekday, $0.startMinutes) < ($1.weekday, $1.startMinutes) }
    }

    private func saveWindows() {
        guard let data = try? JSONEncoder().encode(workingWindows) else { return }
        store.set(data, forKey: Key.windows)
    }
}
