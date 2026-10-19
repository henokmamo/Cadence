//
//  SettingsScreen.swift
//  Cadence
//
//  Everything that changes the scheduler's behaviour lives here, with plain-language
//  explanations — a scheduling rule the user doesn't understand is a scheduling rule
//  they'll end up fighting.
//

import SwiftUI
import SwiftData
import EventKit
import UserNotifications

struct SettingsScreen: View {

    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context

    @State private var showingHoursEditor = false
    @State private var showingReschedulePreview = false
    @State private var exportedURL: URL? = nil
    @State private var showingExport = false
    @State private var showingDeleteConfirm = false
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined

    @Query(sort: [SortDescriptor(\SchedulingLogEntry.placedAt, order: .reverse)])
    private var logEntries: [SchedulingLogEntry]

    init() {}

    var body: some View {
        let prefs = app.preferences

        Form {
            schedulingSection(prefs)
            workingHoursSection(prefs)
            notificationsSection(prefs)
            calendarSection(prefs)
            dataSection
            aboutSection
        }
        .navigationTitle("Settings")
        .sheet(isPresented: $showingHoursEditor) {
            WorkingHoursEditor()
        }
        .sheet(isPresented: $showingReschedulePreview) {
            SchedulingLogView(entries: Array(logEntries.prefix(40)))
        }
        .sheet(isPresented: $showingExport) {
            if let exportedURL {
                ShareLink(item: exportedURL) {
                    Label("Share Cadence export", systemImage: "square.and.arrow.up")
                }
                .padding()
                .presentationDetents([.medium])
            }
        }
        .confirmationDialog(
            "Delete all tasks and blocks?",
            isPresented: $showingDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete everything", role: .destructive, action: deleteEverything)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes tasks, blocks, lists and history from this device. It can't be undone.")
        }
        .task {
            notificationStatus = await NotificationScheduler().authorizationStatus()
        }
    }

    // MARK: - Scheduling

    private func schedulingSection(_ prefs: Preferences) -> some View {
        @Bindable var prefs = prefs

        return Section {
            Toggle("Deadlines first", isOn: $prefs.edfEnabled)
            Stepper("Buffer between blocks: \(prefs.bufferMinutes)m", value: $prefs.bufferMinutes, in: 0...60, step: 5)
            Stepper("Shortest block: \(prefs.minChunkMinutes)m", value: $prefs.minChunkMinutes, in: 5...60, step: 5)
            Stepper("Longest block: \(prefs.maxChunkMinutes)m", value: $prefs.maxChunkMinutes, in: 30...240, step: 15)
            Stepper("Max blocks per task: \(prefs.maxChunksPerTask)", value: $prefs.maxChunksPerTask, in: 1...10)
            Stepper("Daily auto-planned cap: \(prefs.dailyAutoMinutesCap.abbreviatedDuration)",
                    value: $prefs.dailyAutoMinutesCap, in: 60...720, step: 30)
            Stepper("Plan ahead: \(prefs.horizonDays) days", value: $prefs.horizonDays, in: 3...60, step: 1)

            Toggle("Pull the next block forward when I finish early",
                   isOn: $prefs.pullsBlocksForwardOnCompletion)

            Button {
                showingReschedulePreview = true
            } label: {
                Label("Why was it planned that way?", systemImage: "questionmark.circle")
            }
        } header: {
            Text("Scheduling")
        } footer: {
            Text("Deadlines first means a task due tomorrow outranks an undated task, even a high-priority one. Turn it off to schedule purely by priority. The daily cap is soft — Cadence will exceed it rather than leave work unplaced.\n\nWith pull-forward off (the default, “calm”), finishing early leaves the gap open and simply offers to move the next block up. With it on, Cadence compacts the rest of the day for you and offers an undo.")
        }
    }

    private func workingHoursSection(_ prefs: Preferences) -> some View {
        Section {
            Button {
                showingHoursEditor = true
            } label: {
                HStack {
                    Label("Working hours", systemImage: "clock")
                    Spacer()
                    Text(summary(of: prefs.workingWindows))
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
            }
        } header: {
            Text("When can work happen")
        } footer: {
            Text("Cadence only schedules inside these windows. Add several windows a day to keep a lunch break free.")
        }
    }

    private func summary(of windows: [WorkingWindow]) -> String {
        WorkingHours.summary(of: windows)
    }

    // MARK: - Notifications

    private func notificationsSection(_ prefs: Preferences) -> some View {
        @Bindable var prefs = prefs

        return Section {
            Toggle("Reminders", isOn: $prefs.notificationsAreOn)
                .onChange(of: prefs.notificationsAreOn) { _, isOn in
                    if isOn {
                        Task {
                            let granted = await NotificationScheduler().requestAuthorization()
                            prefs.notificationsAreOn = granted
                            notificationStatus = await NotificationScheduler().authorizationStatus()
                            app.coordinator.refreshDerivedState()
                        }
                    } else {
                        NotificationScheduler().refresh(preferences: prefs, context: context)
                    }
                }

            if notificationStatus == .denied {
                Label("Turned off in iOS Settings", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
            }

            Toggle("Tell me when a block starts", isOn: $prefs.blockStartNotifications)
            Toggle("Warn me about impossible deadlines", isOn: $prefs.deadlineWarningsEnabled)
            Toggle("Morning digest", isOn: $prefs.morningDigestEnabled)

            if prefs.morningDigestEnabled {
                DatePicker(
                    "Digest time",
                    selection: minutesBinding($prefs.digestMinutesFromMidnight),
                    displayedComponents: .hourAndMinute
                )
            }

            DatePicker(
                "Quiet hours start",
                selection: minutesBinding($prefs.quietHoursStartMinutes),
                displayedComponents: .hourAndMinute
            )
            DatePicker(
                "Quiet hours end",
                selection: minutesBinding($prefs.quietHoursEndMinutes),
                displayedComponents: .hourAndMinute
            )
        } header: {
            Text("Notifications")
        } footer: {
            Text("Block reminders are suppressed during quiet hours — deadline warnings never are.")
        }
    }

    /// Bridges "minutes from midnight" stored in Preferences to a DatePicker.
    private func minutesBinding(_ source: Binding<Int>) -> Binding<Date> {
        Binding(
            get: {
                let calendar = Calendar.current
                let start = calendar.startOfDay(for: .now)
                return calendar.date(byAdding: .minute, value: source.wrappedValue, to: start) ?? start
            },
            set: { newValue in
                let calendar = Calendar.current
                let components = calendar.dateComponents([.hour, .minute], from: newValue)
                source.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    // MARK: - Calendar

    private func calendarSection(_ prefs: Preferences) -> some View {
        @Bindable var prefs = prefs

        return Section {
            Toggle("Plan around my calendar", isOn: $prefs.importCalendarEnabled)
                .onChange(of: prefs.importCalendarEnabled) { _, isOn in
                    if isOn {
                        Task {
                            let granted = await app.calendarService.requestAccess()
                            prefs.importCalendarEnabled = granted
                            app.applyReschedule(reason: .taskChanged)
                        }
                    } else {
                        app.applyReschedule(reason: .taskChanged)
                    }
                }

            if app.calendarService.isAuthorized, prefs.importCalendarEnabled {
                ForEach(app.calendarService.availableCalendars()) { calendar in
                    Toggle(isOn: Binding(
                        get: { !prefs.excludedCalendarIDs.contains(calendar.id) },
                        set: { included in
                            if included {
                                prefs.excludedCalendarIDs.remove(calendar.id)
                            } else {
                                prefs.excludedCalendarIDs.insert(calendar.id)
                            }
                            app.applyReschedule(reason: .taskChanged)
                        }
                    )) {
                        HStack(spacing: Theme.Space.s) {
                            Circle().fill(Color(hex: calendar.colorHex)).frame(width: 10, height: 10)
                            VStack(alignment: .leading, spacing: 0) {
                                Text(calendar.title)
                                Text(calendar.accountTitle).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Read-only: Cadence looks at existing events to find honest free time. It never creates, moves or deletes events in your calendar.")
        }
    }

    // MARK: - Data

    private var dataSection: some View {
        Section {
            Button {
                exportJSON()
            } label: {
                Label("Export everything as JSON", systemImage: "square.and.arrow.up")
            }

            Button {
                app.applyReschedule(reason: .manual)
            } label: {
                Label("Reschedule the whole week", systemImage: "arrow.triangle.2.circlepath")
            }

            Button(role: .destructive) {
                showingDeleteConfirm = true
            } label: {
                Label("Delete all data", systemImage: "trash")
            }
        } header: {
            Text("Data")
        } footer: {
            Text("Everything currently lives on this device only. iCloud sync arrives in 1.3 — the data model is already shaped for it, so nothing will be lost when it lands.")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: "1.0.0 (1)")
            LabeledContent("Scheduling engine", value: "EDF-first, earliest-fit")
            LabeledContent("Blocks planned", value: "\(logEntries.count) decisions logged")
        } header: {
            Text("About")
        } footer: {
            Text("Cadence plans locally, offline and instantly. No account, no analytics, no network calls.")
        }
    }

    // MARK: - Data actions

    private func deleteEverything() {
        for entry in logEntries { context.delete(entry) }
        if let blocks = try? context.fetch(FetchDescriptor<TimeBlock>()) {
            blocks.forEach(context.delete)
        }
        if let tasks = try? context.fetch(FetchDescriptor<TaskItem>()) {
            tasks.forEach(context.delete)
        }
        if let lists = try? context.fetch(FetchDescriptor<TaskList>()) {
            lists.forEach(context.delete)
        }
        if let tags = try? context.fetch(FetchDescriptor<Tag>()) {
            tags.forEach(context.delete)
        }
        try? context.save()
        app.snapshotWriter.write(from: context)
    }

    private func exportJSON() {
        let exporter = DataExporter(context: context)
        exportedURL = exporter.writeTemporaryFile()
        showingExport = exportedURL != nil
    }
}

// MARK: - Working hours editor

struct WorkingHoursEditor: View {

    @Environment(AppEnvironment.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var windows: [WorkingWindow] = []

    init() {}

    var body: some View {
        NavigationStack {
            List {
                ForEach(RelativeDateFormatter.orderedWeekdaySymbols, id: \.index) { day in
                    Section(day.full) {
                        let dayWindows = windows.filter { $0.weekday == day.index + 1 }
                        if dayWindows.isEmpty {
                            Text("Closed").font(.caption).foregroundStyle(.secondary)
                        }
                        ForEach(dayWindows) { window in
                            HStack {
                                TimeOfDayPicker(minutes: binding(for: window.id, keyPath: \.startMinutes))
                                Text("–").foregroundStyle(.secondary)
                                TimeOfDayPicker(minutes: binding(for: window.id, keyPath: \.endMinutes))
                                Spacer()
                                Button {
                                    windows.removeAll { $0.id == window.id }
                                } label: {
                                    Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        Button {
                            addWindow(weekday: day.index + 1)
                        } label: {
                            Label("Add window", systemImage: "plus.circle")
                                .font(.subheadline)
                        }
                    }
                }

                Section {
                    Button("Reset to Mon–Fri 9–6") {
                        windows = WorkingHours.defaultWindows
                    }
                    Button("Copy Monday to all weekdays") {
                        copyFirstDayToAll()
                    }
                }
            }
            .navigationTitle("Working hours")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        app.preferences.workingWindows = windows.sorted {
                            ($0.weekday, $0.startMinutes) < ($1.weekday, $1.startMinutes)
                        }
                        app.applyReschedule(reason: .taskChanged)
                        dismiss()
                    }
                }
            }
            .onAppear { windows = app.preferences.workingWindows }
        }
    }

    private func binding(for id: UUID, keyPath: WritableKeyPath<WorkingWindow, Int>) -> Binding<Int> {
        Binding(
            get: { windows.first { $0.id == id }?[keyPath: keyPath] ?? 9 * 60 },
            set: { newValue in
                guard let index = windows.firstIndex(where: { $0.id == id }) else { return }
                windows[index][keyPath: keyPath] = newValue
            }
        )
    }

    private func addWindow(weekday: Int) {
        let existing = windows.filter { $0.weekday == weekday }
        let start = existing.last?.endMinutes ?? 9 * 60
        windows.append(WorkingWindow(weekday: weekday, startMinutes: min(start, 22 * 60), endMinutes: min(start + 240, 24 * 60)))
    }

    private func copyFirstDayToAll() {
        guard let weekday = windows.map(\.weekday).min() else { return }
        let templates = windows.filter { $0.weekday == weekday }
        guard !templates.isEmpty else { return }
        for day in 1...7 where day != weekday {
            windows.removeAll { $0.weekday == day }
            for template in templates {
                windows.append(
                    WorkingWindow(
                        weekday: day,
                        startMinutes: template.startMinutes,
                        endMinutes: template.endMinutes
                    )
                )
            }
        }
    }
}

/// Minutes-from-midnight ↔ DatePicker bridge.
struct TimeOfDayPicker: View {
    @Binding var minutes: Int

    var body: some View {
        DatePicker(
            "",
            selection: Binding(
                get: {
                    let calendar = Calendar.current
                    let start = calendar.startOfDay(for: .now)
                    return calendar.date(byAdding: .minute, value: minutes, to: start) ?? start
                },
                set: { newValue in
                    let calendar = Calendar.current
                    let components = calendar.dateComponents([.hour, .minute], from: newValue)
                    minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                }
            ),
            displayedComponents: .hourAndMinute
        )
        .labelsHidden()
        .frame(maxWidth: 110)
    }
}

// MARK: - Scheduling log ("why was it planned that way?")

struct SchedulingLogView: View {
    let entries: [SchedulingLogEntry]

    var body: some View {
        NavigationStack {
            List {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No decisions yet",
                        systemImage: "wand.and.stars",
                        description: Text("Once tasks are scheduled, this shows exactly why each one landed where it did.")
                    )
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.taskTitle).font(.subheadline.weight(.medium)).lineLimit(1)
                            Spacer()
                            Text(entry.outcomeRaw)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Text(entry.reason).font(.caption).foregroundStyle(.secondary)
                        Text(RelativeDateFormatter.stamp(entry.placedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .navigationTitle("Planning decisions")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Export

struct DataExporter {
    let context: ModelContext

    private struct ExportPayload: Codable {
        struct TaskDTO: Codable {
            var id: UUID
            var title: String
            var notes: String
            var estimateMinutes: Int
            var priority: String
            var status: String
            var deadline: Date?
            var list: String?
            var isPinned: Bool
            var tags: [String]
            var blocks: [BlockDTO]
        }
        struct BlockDTO: Codable {
            var start: Date
            var end: Date
            var origin: String
            var isPinned: Bool
        }
        var exportedAt: Date
        var tasks: [TaskDTO]
    }

    func writeTemporaryFile() -> URL? {
        let tasks = (try? context.fetch(FetchDescriptor<TaskItem>())) ?? []
        let payload = ExportPayload(
            exportedAt: .now,
            tasks: tasks.map { task in
                ExportPayload.TaskDTO(
                    id: task.id,
                    title: task.title,
                    notes: task.notes,
                    estimateMinutes: task.estimateMinutes,
                    priority: task.priority.label,
                    status: task.status.rawValue,
                    deadline: task.deadline,
                    list: task.list?.name,
                    isPinned: task.isPinned,
                    tags: task.tags.map(\.name),
                    blocks: task.orderedBlocks.map {
                        ExportPayload.BlockDTO(start: $0.start, end: $0.end, origin: $0.origin.rawValue, isPinned: $0.isPinned)
                    }
                )
            }
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payload) else { return nil }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cadence-export-\(Int(Date.now.timeIntervalSince1970)).json")
        try? data.write(to: url)
        return url
    }
}