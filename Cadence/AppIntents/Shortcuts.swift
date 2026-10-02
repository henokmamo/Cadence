//
//  Shortcuts.swift
//  Cadence
//
//  Siri, Spotlight and the Shortcuts app entry points. App-only — the widget target
//  deliberately doesn't register shortcuts, so they can't be duplicated.
//

import AppIntents

// MARK: - App Shortcuts (Siri, Spotlight, Shortcuts app)

struct CadenceShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RescheduleDayIntent(),
            phrases: [
                "Reschedule my day in \(.applicationName)",
                "Replan my day with \(.applicationName)"
            ],
            shortTitle: "Reschedule my day",
            systemImageName: "arrow.triangle.2.circlepath"
        )
        AppShortcut(
            intent: AddTaskIntent(),
            phrases: [
                "Add a task to \(.applicationName)",
                "Capture a task in \(.applicationName)"
            ],
            shortTitle: "Add a task",
            systemImageName: "plus.circle"
        )
    }
}
