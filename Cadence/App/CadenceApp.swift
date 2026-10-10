//
//  CadenceApp.swift
//  Cadence
//
//  App entry point. Wires up:
//    • the SwiftData container (local-first, CloudKit-ready — see AppModelContainer)
//    • the shared Preferences (App Group backed so the widget sees the same settings)
//    • the ScheduleCoordinator / TaskActionService objects the whole UI shares
//    • the notification delegate so lock-screen actions hit the same code path as taps
//

import SwiftUI
import SwiftData
import UIKit
import BackgroundTasks

@main
struct CadenceApp: App {

    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var environment: AppEnvironment

    private let container: ModelContainer

    @MainActor
    init() {
        let container = AppModelContainer.make()
        self.container = container
        _environment = State(initialValue: AppEnvironment(container: container))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(environment)
        }
        .modelContainer(container)
    }
}

// MARK: - Container

enum AppModelContainer {

    static let schema = Schema([
        TaskItem.self,
        TimeBlock.self,
        TaskList.self,
        Tag.self,
        Subtask.self,
        SchedulingLogEntry.self
    ])

    /// Local-first by default.
    ///
    /// To enable iCloud sync later (roadmap 1.3) you change exactly one argument:
    ///
    ///     let configuration = ModelConfiguration(
    ///         schema: schema,
    ///         isStoredInMemoryOnly: false,
    ///         groupContainer: .none,
    ///         cloudKitDatabase: .private("iCloud.com.example.cadence")
    ///     )
    ///
    /// …after adding the iCloud → CloudKit capability in Signing & Capabilities.
    /// No model changes are needed because every attribute has a default/optional,
    /// there are no unique constraints and all relationships have inverses.
    static func make(inMemory: Bool = false) -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: inMemory,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            // A store that cannot open is not recoverable in-place; fall back to memory
            // so the app still launches and the user can export/reinstall (v1.1: migration repair flow).
            assertionFailure("ModelContainer failed: \(error)")
            return try! ModelContainer(
                for: schema,
                configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)]
            )
        }
    }
}

// MARK: - Shared app objects

@MainActor
@Observable
final class AppEnvironment {

    /// Set at launch so AppDelegate (notifications) can reach the action service.
    static weak var current: AppEnvironment?

    let preferences: Preferences
    let calendarService: CalendarService
    private(set) var coordinator: ScheduleCoordinator
    private(set) var actions: TaskActionService
    let snapshotWriter = WidgetSnapshotWriter()

    private let container: ModelContainer

    /// Set by the UI after a reschedule so the toast can offer Undo.
    var lastOutcomeSummary: String?
    var showsUndoToast = false

    /// Calm mode: after a completion the UI *offers* to pull the next block forward
    /// instead of moving it. (Preferences.pullsBlocksForwardOnCompletion turns the
    /// offer into automatic compaction for people who prefer that.)
    struct Suggestion {
        let message: String
        let actionLabel: String
        let action: () -> Void
    }

    var suggestion: Suggestion?
    var showsSuggestionToast: Bool = false

    init(container: ModelContainer) {
        self.container = container
        let context = container.mainContext
        let preferences = Preferences()
        let calendarService = CalendarService()
        let localCoordinator = ScheduleCoordinator(
            context: context,
            preferences: preferences,
            calendarService: calendarService
        )

        self.preferences = preferences
        self.calendarService = calendarService
        self.coordinator = localCoordinator
        self.actions = TaskActionService(
            context: context,
            coordinator: localCoordinator,
            preferences: preferences
        )
        AppEnvironment.current = self
    }

    var context: ModelContext { container.mainContext }

    // MARK: - Lifecycle

    /// Called once when the UI appears.
    func bootstrap(now: Date = .now) async {
        SampleData.seedIfEmpty(context: context, now: now)

        NotificationScheduler().configure()
        actions.drainPendingWork(now: now)

        if preferences.hasCompletedOnboarding {
            applyReschedule(reason: .startup, now: now, silent: true)
        }
    }

    /// Called when the app returns to the foreground.
    func handleForeground(now: Date = .now) {
        actions.drainPendingWork(now: now)
        // Re-plan if the plan is older than 15 minutes or the day rolled over.
        if let last = lastRescheduleAt, now.timeIntervalSince(last) < 15 * 60 {
            snapshotWriter.write(from: context, now: now)
            return
        }
        applyReschedule(reason: .appForeground, now: now, silent: true)
    }

    func handleBackground() {
        snapshotWriter.write(from: context, now: .now)
    }

    // MARK: - Completion (calm by default)

    /// One entry point for completing a task from the UI. Returns whether a repeating
    /// task booked its next occurrence, and surfaces the pull-forward offer.
    @discardableResult
    func complete(task: TaskItem, at date: Date = .now) -> ScheduleCoordinator.CompletionOutcome {
        let outcome = coordinator.complete(task: task, at: date)

        if let instance = outcome.nextInstance {
            suggestion = Suggestion(
                message: "Done. Next “\(instance.title)” booked for \(RelativeDateFormatter.day(instance.notBefore ?? instance.createdAt)).",
                actionLabel: "Show",
                action: { [weak self] in
                    self?.applyReschedule(reason: .taskChanged, now: date, silent: true)
                    self?.showsSuggestionToast = false
                }
            )
            withAnimation { showsSuggestionToast = true }
        } else if let suggestion = outcome.suggestion {
            self.suggestion = Suggestion(
                message: suggestion.message,
                actionLabel: "Pull forward",
                action: { [weak self] in
                    guard let self else { return }
                    self.applyReschedule(reason: .completionCompaction, now: date)
                    self.showsSuggestionToast = false
                }
            )
            withAnimation { showsSuggestionToast = true }
        }

        return outcome
    }

    func acceptSuggestion() {
        let action = suggestion?.action
        withAnimation { showsSuggestionToast = false }
        suggestion = nil
        action?()
    }

    func dismissSuggestion() {
        withAnimation { showsSuggestionToast = false }
        suggestion = nil
    }

    // MARK: - Rescheduling facade (keeps toast/summary logic in one place)

    private(set) var lastRescheduleAt: Date?

    @discardableResult
    func applyReschedule(reason: ScheduleCoordinator.Reason, now: Date = .now, silent: Bool = false) -> ScheduleCoordinator.Outcome? {
        let outcome = coordinator.reschedule(reason: reason, now: now)
        lastRescheduleAt = now

        guard let outcome else {
            if !silent { lastOutcomeSummary = nil }
            return nil
        }
        if !silent {
            var parts: [String] = []
            parts.append("\(outcome.insertedBlocks) block\(outcome.insertedBlocks == 1 ? "" : "s") planned")
            if !outcome.atRisk.isEmpty {
                parts.append("\(outcome.atRisk.count) won't fit")
            }
            lastOutcomeSummary = parts.joined(separator: " · ")
            withAnimation { showsUndoToast = true }
        }
        return outcome
    }
}

// MARK: - App delegate (notifications + background refresh)

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        BackgroundRefresh.register()
        return true
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        MainActor.assumeIsolated { AppEnvironment.current?.handleBackground() }
    }

    // Show banners even while the app is open — a block starting is useful in-app too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        let identifier = response.actionIdentifier
        
        var safeUserInfo: [String: String] = [:]
        for (key, value) in userInfo {
            if let k = key as? String, let v = value as? String {
                safeUserInfo[k] = v
            }
        }
        
        await MainActor.run {
            AppEnvironment.current?.actions.handleNotificationAction(
                identifier: identifier,
                userInfo: safeUserInfo
            )
        }
    }
}

// MARK: - Background refresh

enum BackgroundRefresh {
    static let identifier = "com.example.cadence.refresh"

    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { task in
            guard let refresh = task as? BGAppRefreshTask else { return }
            handle(refresh)
        }
        schedule()
    }

    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        // Refill notifications + re-plan roughly every 4 hours; iOS decides the truth.
        request.earliestBeginDate = Date(timeIntervalSinceNow: 4 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGAppRefreshTask) {
        schedule()                                   // always chain the next one
        task.expirationHandler = { task.setTaskCompleted(success: false) }
        Task { @MainActor in
            AppEnvironment.current?.handleForeground()
            task.setTaskCompleted(success: true)
        }
    }
}
