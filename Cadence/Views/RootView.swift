//
//  RootView.swift
//  Cadence
//
//  The shell: four tabs, the undo toast that makes every reshuffle reversible,
//  and the first-run sheet that asks for notification permission *in context*
//  (after showing what the app will do) instead of on a cold launch.
//

import SwiftUI
import SwiftData

enum AppTab: Hashable {
    case today, calendar, tasks, settings
}

struct RootView: View {

    @Environment(AppEnvironment.self) private var app
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var context

    @State private var selection: AppTab = .today
    @State private var showsOnboarding = false

    var body: some View {
        @Bindable var app = app

        TabView(selection: $selection) {
            NavigationStack {
                TodayView(onOpenCalendar: { selection = .calendar })
            }
            .tabItem { Label("Today", systemImage: "sun.max") }
            .tag(AppTab.today)

            NavigationStack {
                CalendarScreen()
            }
            .tabItem { Label("Calendar", systemImage: "calendar") }
            .tag(AppTab.calendar)

            NavigationStack {
                TasksScreen()
            }
            .tabItem { Label("Tasks", systemImage: "checklist") }
            .tag(AppTab.tasks)

            NavigationStack {
                SettingsScreen()
            }
            .tabItem { Label("Settings", systemImage: "gearshape") }
            .tag(AppTab.settings)
        }
        .tint(Theme.accent)
        .overlay(alignment: .bottom) {
            VStack(spacing: Theme.Space.s) {
                if app.showsSuggestionToast, let suggestion = app.suggestion {
                    ToastBanner(
                        systemImage: "arrow.up.forward.circle",
                        tint: Theme.accent,
                        message: suggestion.message,
                        actionLabel: suggestion.actionLabel,
                        onAction: { app.acceptSuggestion() },
                        onDismiss: { app.dismissSuggestion() }
                    )
                }
                if app.showsUndoToast, let summary = app.lastOutcomeSummary {
                    ToastBanner(
                        systemImage: "sparkles",
                        tint: Theme.accent,
                        message: summary,
                        actionLabel: "Undo",
                        onAction: {
                            app.coordinator.undoLastReschedule()
                            withAnimation { app.showsUndoToast = false }
                        },
                        onDismiss: { withAnimation { app.showsUndoToast = false } }
                    )
                }
            }
            .padding(.bottom, 68)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
        .task {
            await app.bootstrap()
            showsOnboarding = !app.preferences.hasCompletedOnboarding
        }
        .sheet(isPresented: $showsOnboarding) {
            OnboardingSheet()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                app.handleForeground()
            case .background:
                app.handleBackground()
                BackgroundRefresh.schedule()
            default:
                break
            }
        }
        // Keep the "day rollover" honest: if the app is open at midnight, re-plan.
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
            app.applyReschedule(reason: .dayRollover)
        }
    }
}

// MARK: - Toast

/// Bottom banner used for two things only: undo an automatic reshuffle, or take up the
/// calm-mode offer to pull the next block forward. Nothing here moves a block by itself.
private struct ToastBanner: View {
    let systemImage: String
    let tint: Color
    let message: String
    let actionLabel: String
    let onAction: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
            Text(message)
                .font(.subheadline)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(actionLabel, action: onAction)
                .font(.subheadline.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(tint)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .padding(.horizontal, Theme.Space.l)
    }
}

// MARK: - Onboarding

struct OnboardingSheet: View {

    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss

    @State private var step: Int = 0
    @State private var requestingNotifications = false

    var body: some View {
        VStack(spacing: Theme.Space.xl) {
            Spacer(minLength: 0)

            Image(systemName: step == 0 ? "calendar.badge.clock" : "bell.badge")
                .font(.system(size: 54, weight: .regular))
                .foregroundStyle(Theme.accent)
                .symbolEffect(.pulse)

            VStack(spacing: Theme.Space.s) {
                Text(step == 0 ? "Cadence plans your day" : "Stay on schedule")
                    .font(.title2.bold())
                Text(step == 0
                     ? "Give it your tasks and your working hours. It finds real gaps in your calendar and blocks the time — you can always drag things around."
                     : "Cadence can nudge you a minute before each block starts, and warn you when something won't fit before its deadline. Local notifications only — nothing leaves your phone.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.Space.xl)
            }

            Spacer(minLength: 0)

            VStack(spacing: Theme.Space.m) {
                if step == 0 {
                    Button("Continue") { withAnimation { step = 1 } }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .frame(maxWidth: .infinity)
                } else {
                    Button {
                        requestingNotifications = true
                        Task {
                            let granted = await NotificationScheduler().requestAuthorization()
                            app.preferences.notificationsAreOn = granted
                            requestingNotifications = false
                            finish()
                        }
                    } label: {
                        if requestingNotifications {
                            ProgressView()
                        } else {
                            Text("Turn on reminders")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)

                    Button("Not now") { finish() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Theme.Space.xl)
            .padding(.bottom, Theme.Space.xl)
        }
        .interactiveDismissDisabled()
    }

    private func finish() {
        app.preferences.hasCompletedOnboarding = true
        app.applyReschedule(reason: .startup)
        dismiss()
    }
}
