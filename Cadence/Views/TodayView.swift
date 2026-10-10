//
//  TodayView.swift
//  Cadence
//
//  The screen you open 40 times a day: what's happening now, what's next, what's
//  slipping, and a one-line capture field at the bottom.
//
//  Nothing here decides *when* things happen — that's the engine's job. This view
//  only reflects the plan and forwards intents to ScheduleCoordinator.
//

import SwiftUI
import SwiftData

struct TodayView: View {

    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context
    var onOpenCalendar: () -> Void = {}

    @State private var now = Date.now
    @State private var quickTitle = ""
    @State private var quickEstimate = 30
    @FocusState private var quickFieldFocused: Bool

    @Query(
        filter: #Predicate<TaskItem> { $0.statusRaw == "open" && $0.isSoftDeleted == false },
        sort: [SortDescriptor(\TaskItem.createdAt)]
    )
    private var openTasks: [TaskItem]

    @Query(sort: [SortDescriptor(\TimeBlock.start)])
    private var allBlocks: [TimeBlock]

    private let ticker = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    // MARK: - Derived

    private var todayBlocks: [TimeBlock] {
        let calendar = Calendar.current
        return allBlocks.filter {
            !$0.isSoftDeleted && calendar.isDate($0.start, inSameDayAs: now)
        }
    }

    private var currentBlock: TimeBlock? {
        todayBlocks.first { $0.contains(now) }
    }

    private var upcomingBlocks: [TimeBlock] {
        todayBlocks.filter { $0.start > now && $0.origin != .imported }
    }

    private var overdueTasks: [TaskItem] {
        openTasks.filter(\.isOverdue)
    }

    /// Tasks with a deadline that the engine could not fully place.
    private var atRiskTasks: [TaskItem] {
        openTasks.filter { task in
            guard let deadline = task.deadline, deadline > now else { return false }
            guard deadline.timeIntervalSince(now) < 72 * 3600 else { return false }
            return task.remainingMinutes > 0 && !task.isAnytime
        }
    }

    private var plannedMinutes: Int {
        todayBlocks.filter { $0.origin != .imported }.reduce(0) { $0 + $1.durationMinutes }
    }

    private var completedMinutes: Int {
        todayBlocks.filter { $0.task?.isCompleted == true }.reduce(0) { $0 + $1.durationMinutes }
    }

    private var freeMinutesToday: Int {
        let calendar = Calendar.current
        let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        let busy = todayBlocks.map(\.dateInterval).filter { $0.end > now }
        let windows = WorkingHours.windows(
            from: app.preferences.workingWindows,
            in: DateInterval(start: now, end: dayEnd)
        )
        let free = SchedulingEngine.subtract(busy: busy, from: windows)
        return free.reduce(0) { $0 + Int($1.duration / 60) }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.l) {
                dayHeader
                if let block = currentBlock, let task = block.task {
                    NowCard(
                        block: block,
                        task: task,
                        now: now,
                        onComplete: { app.complete(task: task, at: now) },
                        onSnooze: { app.coordinator.snoozeCurrentBlock(of: task, minutes: 15, now: now) },
                        onPushToTomorrow: { pushToTomorrow(task: task, block: block) }
                    )
                } else if let next = upcomingBlocks.first {
                    NextUpCard(block: next, now: now) {
                        app.coordinator.move(
                            block: next,
                            to: now.roundedDown(toMinutes: 5),
                            durationMinutes: next.durationMinutes,
                            now: now
                        )
                    }
                }

                if !overdueTasks.isEmpty {
                    section(
                        title: "Overdue",
                        systemImage: "exclamationmark.triangle.fill",
                        tint: Theme.danger,
                        subtitle: "\(overdueTasks.count)"
                    ) {
                        scheduleButton(for: overdueTasks)
                        ForEach(overdueTasks) { task in
                            TaskRow(task: task) { toggle(task) }
                        }
                    }
                }

                if !atRiskTasks.isEmpty {
                    section(
                        title: "Won't fit",
                        systemImage: "hourglass.bottomhalf.filled",
                        tint: Theme.warning,
                        subtitle: "needs attention"
                    ) {
                        ForEach(Array(atRiskTasks.prefix(4))) { task in
                            AtRiskRow(task: task, now: now)
                        }
                    }
                }

                section(
                    title: "Today's plan",
                    systemImage: "list.bullet.rectangle",
                    tint: .secondary,
                    subtitle: "\(plannedMinutes.abbreviatedDuration) planned · \(freeMinutesToday.abbreviatedDuration) free"
                ) {
                    if todayBlocks.isEmpty {
                        EmptyHint(
                            systemImage: "calendar.badge.plus",
                            title: "Nothing scheduled yet",
                            message: "Add a task below and Cadence will find a gap for it."
                        )
                    } else {
                        ForEach(todayBlocks) { block in
                            TimelineBlockRow(block: block, now: now) {
                                if let task = block.task { toggle(task) }
                            }
                        }
                    }
                }

                if !upcomingBlocks.isEmpty {
                    section(
                        title: "Rest of today",
                        systemImage: "arrow.right.circle",
                        tint: .secondary,
                        subtitle: "\(upcomingBlocks.count) upcoming"
                    ) {
                        ForEach(upcomingBlocks) { block in
                            TimelineBlockRow(block: block, now: now) {
                                if let task = block.task { toggle(task) }
                            }
                        }
                    }
                }

                Color.clear.frame(height: 76)   // room for the quick-add bar
            }
            .padding(.horizontal, Theme.Space.l)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Today")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button {
                    onOpenCalendar()
                } label: {
                    Label("Calendar", systemImage: "calendar")
                }
                .accessibilityLabel("Open calendar")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.applyReschedule(reason: .manual, now: now)
                } label: {
                    Label("Reschedule", systemImage: "arrow.triangle.2.circlepath")
                }
                .accessibilityLabel("Reschedule my day")
            }
        }
        .safeAreaInset(edge: .bottom) { quickAddBar }
        .onReceive(ticker) { date in
            now = date
        }
    }

    // MARK: - Pieces

    private var dayHeader: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                .font(.title2.bold())
            Text(summaryLine)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, Theme.Space.s)
    }

    private var summaryLine: String {
        if currentBlock != nil { return "In progress · \(freeMinutesToday.abbreviatedDuration) of open time left" }
        if let next = upcomingBlocks.first {
            return "Next: \(next.task?.displayTitle ?? "block") \(RelativeDateFormatter.compactRelative(from: now, to: next.start))"
        }
        return "Nothing scheduled — \(freeMinutesToday.abbreviatedDuration) of open time"
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        systemImage: String,
        tint: Color,
        subtitle: String?,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionHeader(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint)
            VStack(alignment: .leading, spacing: Theme.Space.m) {
                content()
            }
            .card(padding: Theme.Space.m)
        }
    }

    private func scheduleButton(for tasks: [TaskItem]) -> some View {
        Button {
            for task in tasks { task.notBefore = now }
            app.applyReschedule(reason: .taskChanged, now: now)
        } label: {
            Label("Reschedule \(tasks.count) overdue task\(tasks.count == 1 ? "" : "s")", systemImage: "wand.and.stars")
                .font(.subheadline)
        }
        .buttonStyle(.bordered)
    }

    private var quickAddBar: some View {
        VStack(spacing: Theme.Space.s) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "plus.circle.fill")
                    .foregroundStyle(Theme.accent)
                TextField("Add a task — Cadence finds the time", text: $quickTitle)
                    .focused($quickFieldFocused)
                    .submitLabel(.done)
                    .onSubmit(quickAdd)
                if !quickTitle.isEmpty {
                    Button("Add", action: quickAdd)
                        .font(.subheadline.weight(.semibold))
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                }
            }
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())

            DurationChipPicker(minutes: $quickEstimate)
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.bottom, Theme.Space.s)
        .background(.ultraThinMaterial)
    }

    // MARK: - Actions

    private func quickAdd() {
        let title = quickTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        app.actions.capture(title: title, estimateMinutes: quickEstimate, now: now)
        quickTitle = ""
        quickFieldFocused = false
    }

    private func toggle(_ task: TaskItem) {
        if task.isCompleted {
            task.reopen(now)
            try? context.save()
            app.applyReschedule(reason: .taskChanged, now: now)
        } else {
            app.complete(task: task, at: now)
        }
    }

    private func pushToTomorrow(task: TaskItem, block: TimeBlock) {
        let calendar = Calendar.current
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: block.start) else { return }
        app.coordinator.move(block: block, to: tomorrow, durationMinutes: block.durationMinutes, now: now)
    }
}

// MARK: - Now card

private struct NowCard: View {
    let block: TimeBlock
    let task: TaskItem
    let now: Date
    let onComplete: () -> Void
    let onSnooze: () -> Void
    let onPushToTomorrow: () -> Void

    private var progress: Double {
        let total = block.end.timeIntervalSince(block.start)
        guard total > 0 else { return 0 }
        return now.timeIntervalSince(block.start) / total
    }

    private var remaining: String {
        let minutes = Int(block.end.timeIntervalSince(now) / 60)
        return minutes > 0 ? "\(minutes.abbreviatedDuration) left" : "finishing up"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            HStack(spacing: Theme.Space.l) {
                ProgressRing(progress: progress, lineWidth: 7, color: Theme.blockColor(
                    for: block.origin,
                    isPinned: block.isPinned,
                    listColorHex: task.list?.colorHex
                ))
                .frame(width: 52, height: 52)
                .overlay {
                    Text(remaining)
                        .font(.caption2.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .frame(width: 46)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Happening now")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    Text(task.displayTitle)
                        .font(.headline)
                        .lineLimit(2)
                    Text("\(RelativeDateFormatter.timeRange(block.start, block.end)) · \(block.durationMinutes.abbreviatedDuration)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            if !task.notes.isEmpty {
                Text(task.notes)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack(spacing: Theme.Space.s) {
                Button(action: onComplete) {
                    Label("Complete", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button(action: onSnooze) {
                    Label("15m", systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: onPushToTomorrow) {
                    Image(systemName: "arrow.right.to.line")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .accessibilityLabel("Push to tomorrow")
            }
        }
        .card()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Next up card

private struct NextUpCard: View {
    let block: TimeBlock
    let now: Date
    let onStartNow: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.m) {
            Image(systemName: "arrow.forward.circle.fill")
                .font(.title2)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("Up next")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(block.task?.displayTitle ?? "Block")
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text("\(RelativeDateFormatter.time(block.start)) · \(RelativeDateFormatter.compactRelative(from: now, to: block.start))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Start now", action: onStartNow)
                .font(.subheadline)
                .buttonStyle(.bordered)
        }
        .card(padding: Theme.Space.m)
    }
}

// MARK: - Timeline row

private struct TimelineBlockRow: View {
    let block: TimeBlock
    let now: Date
    let onToggle: () -> Void

    private var isPast: Bool { block.end < now }
    private var isImported: Bool { block.origin == .imported }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(RelativeDateFormatter.time(block.start))
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(isPast ? .secondary : .primary)
                Text(block.durationMinutes.abbreviatedDuration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .frame(width: 58, alignment: .trailing)

            RoundedRectangle(cornerRadius: 2)
                .fill(barColor)
                .frame(width: 3, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Theme.Space.s) {
                    Text(block.task?.displayTitle ?? "Busy")
                        .font(.subheadline.weight(.medium))
                        .strikethrough(block.task?.isCompleted == true, color: .secondary)
                        .foregroundStyle(isPast && !isImported ? .secondary : .primary)
                        .lineLimit(2)
                    if block.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(Theme.blockPinned)
                    }
                }
                if isImported {
                    Text("From your calendar")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else if let reason = block.task?.lastScheduleReason, block.task?.blocks.count == 1 {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            if !isImported, let task = block.task {
                Button(action: onToggle) {
                    CompletionCircle(isCompleted: task.isCompleted, size: 22)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(task.isCompleted ? "Mark as not done" : "Mark \(task.displayTitle) done")
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .opacity(isPast ? 0.55 : 1)
        .blockAccessibilityLabel(
            title: block.task?.displayTitle ?? "Busy",
            start: block.start,
            end: block.end,
            detail: isPast ? "earlier today" : RelativeDateFormatter.compactRelative(from: now, to: block.start)
        )
    }

    private var barColor: Color {
        guard let task = block.task else { return Theme.blockImported }
        return Theme.blockColor(for: block.origin, isPinned: block.isPinned, listColorHex: task.list?.colorHex)
    }
}

// MARK: - At risk row

private struct AtRiskRow: View {
    let task: TaskItem
    let now: Date

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Image(systemName: "hourglass")
                .font(.caption)
                .foregroundStyle(Theme.warning)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(task.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                if let deadline = task.deadline {
                    Text("Needs \(task.remainingMinutes.abbreviatedDuration) before \(RelativeDateFormatter.deadlineStamp(deadline))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let reason = task.lastScheduleReason {
                    Text(reason)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
