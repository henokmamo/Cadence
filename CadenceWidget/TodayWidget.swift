//
//  TodayWidget.swift
//  CadenceWidget
//
//  Home-screen and lock-screen widgets driven entirely by the App Group snapshot.
//  No SwiftData container here on purpose (see WidgetSnapshot.swift).
//
//  Widgets answer exactly two questions — "what am I doing?" and "what's next?" —
//  and give the user the two actions they actually want from a glance:
//  Complete and Reschedule.
//

import SwiftUI
import WidgetKit
import AppIntents

// MARK: - Timeline

struct CadenceEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

struct CadenceTimelineProvider: TimelineProvider {

    func placeholder(in context: Context) -> CadenceEntry {
        CadenceEntry(date: .now, snapshot: .previewSample)
    }

    func getSnapshot(in context: Context, completion: @escaping (CadenceEntry) -> Void) {
        let snapshot = context.isPreview ? .previewSample : (WidgetSnapshotStore.load() ?? .empty)
        completion(CadenceEntry(date: .now, snapshot: snapshot))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CadenceEntry>) -> Void) {
        let now = Date.now
        let snapshot = WidgetSnapshotStore.load() ?? .empty

        // Refresh at each upcoming block boundary, and never leave the widget stale
        // for more than 15 minutes.
        var refreshDates: [Date] = [now.addingTimeInterval(15 * 60)]
        refreshDates.append(contentsOf: snapshot.todayBlocks.prefix(6).map { $0.start })
        refreshDates.append(contentsOf: snapshot.todayBlocks.prefix(6).map { $0.end })

        let next = refreshDates
            .filter { $0 > now.addingTimeInterval(30) }
            .min() ?? now.addingTimeInterval(15 * 60)

        let entries = [
            CadenceEntry(date: now, snapshot: snapshot),
            // A second entry so the widget is correct at the boundary even if iOS
            // decides not to wake us precisely on time.
            CadenceEntry(date: next, snapshot: snapshot)
        ]
        completion(Timeline(entries: entries, policy: .after(next.addingTimeInterval(60))))
    }
}

// MARK: - Widget definition

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CadenceTodayWidget", provider: CadenceTimelineProvider()) { entry in
            TodayWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Now & Next")
        .description("The block you're in, and what's coming up.")
        .supportedFamilies([.systemSmall, .systemMedium, .accessoryCircular, .accessoryRectangular])
    }
}

struct UpNextWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CadenceUpNextWidget", provider: CadenceTimelineProvider()) { entry in
            UpNextWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Up next")
        .description("Your next block with a one-tap complete.")
        .supportedFamilies([.systemMedium, .accessoryRectangular])
    }
}

// MARK: - Views

struct TodayWidgetView: View {

    let entry: CadenceEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: WidgetSnapshot { entry.snapshot }

    var body: some View {
        switch family {
        case .accessoryCircular: circular
        case .accessoryRectangular: rectangular
        case .systemSmall: small
        default: medium
        }
    }

    // MARK: Small

    private var small: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Cadence")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if snapshot.overdueCount > 0 {
                    Label("\(snapshot.overdueCount)", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption2)
                        .foregroundStyle(Theme.danger)
                }
            }

            if let current = snapshot.currentBlock(at: entry.date) {
                gauge(progress: progress(for: current))
                Text(current.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(minutesLeft(for: current)) left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let next = snapshot.nextBlock {
                gauge(progress: 0)
                    .opacity(0.5)
                Text(next.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("Starts \(RelativeDateFormatter.time(next.start))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Image(systemName: "checkmark.circle")
                    .font(.title)
                    .foregroundStyle(Theme.success)
                Text("Day is clear")
                    .font(.subheadline.weight(.semibold))
                Text("\(snapshot.openTaskCount) open tasks")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
    }

    // MARK: Medium

    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle().fill(Theme.accent).frame(width: 7, height: 7)
                Text(snapshot.currentBlock(at: entry.date) == nil ? "Up next" : "In progress")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(todaySummary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let block = snapshot.currentBlock(at: entry.date) ?? snapshot.nextBlock {
                HStack(alignment: .center, spacing: 10) {
                    gauge(progress: snapshot.currentBlock(at: entry.date) == nil ? 0 : progress(for: block))
                        .frame(width: 40, height: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(block.title)
                            .font(.headline)
                            .lineLimit(1)
                        Text("\(RelativeDateFormatter.timeRange(block.start, block.end)) · \(block.durationMinutes.abbreviatedDuration)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    Button(intent: CompleteTaskIntent(taskID: block.taskID)) {
                        Label("Complete", systemImage: "checkmark")
                            .font(.caption.weight(.semibold))
                    }
                    .tint(Theme.accent)

                    if let current = snapshot.currentBlock(at: entry.date) {
                        Button(intent: SnoozeBlockIntent(blockID: current.id, minutes: 15)) {
                            Label("Snooze", systemImage: "clock.arrow.circlepath")
                                .font(.caption)
                        }
                        .tint(.gray)
                    }

                    Button(intent: RescheduleDayIntent()) {
                        Label("Replan", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption)
                    }
                    .tint(.gray)
                }
            } else {
                Spacer()
                Text("Nothing left today — \(snapshot.completedMinutesToday.abbreviatedDuration) done.")
                    .font(.subheadline.weight(.medium))
                Spacer()
            }

            if !snapshot.atRiskTitles.isEmpty {
                Label("\(snapshot.atRiskTitles.count) won't fit: \(snapshot.atRiskTitles.joined(separator: ", "))",
                      systemImage: "hourglass")
                    .font(.caption2)
                    .foregroundStyle(Theme.warning)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Lock screen

    private var circular: some View {
        Gauge(value: gaugeValue) {
            Image(systemName: "clock")
        } currentValueLabel: {
            if let current = snapshot.currentBlock(at: entry.date) {
                Text("\(minutesLeft(for: current))m")
                    .font(.caption2)
            } else {
                Text("—")
                    .font(.caption2)
            }
        }
        .gaugeStyle(.accessoryCircular)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let current = snapshot.currentBlock(at: entry.date) {
                Text("Now · \(minutesLeft(for: current)) left")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(current.title).font(.headline).lineLimit(1)
                Text(RelativeDateFormatter.timeRange(current.start, current.end))
                    .font(.caption2).foregroundStyle(.secondary)
            } else if let next = snapshot.nextBlock {
                Text("Next · \(RelativeDateFormatter.time(next.start))")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(next.title).font(.headline).lineLimit(1)
                Text("\(next.durationMinutes.abbreviatedDuration) planned")
                    .font(.caption2).foregroundStyle(.secondary)
            } else {
                Text("Nothing scheduled").font(.headline)
                Text("\(snapshot.openTaskCount) open tasks").font(.caption2)
            }
        }
    }

    // MARK: Helpers

    private var todaySummary: String {
        let planned = snapshot.plannedMinutesToday.abbreviatedDuration
        let done = snapshot.completedMinutesToday.abbreviatedDuration
        return "\(done) done · \(planned) planned"
    }

    private var gaugeValue: Double {
        guard let current = snapshot.currentBlock(at: entry.date) else { return 0 }
        return progress(for: current)
    }

    private func progress(for block: WidgetBlockSnapshot) -> Double {
        let total = block.end.timeIntervalSince(block.start)
        guard total > 0 else { return 0 }
        return min(1, max(0, entry.date.timeIntervalSince(block.start) / total))
    }

    private func minutesLeft(for block: WidgetBlockSnapshot) -> Int {
        max(0, Int(block.end.timeIntervalSince(entry.date) / 60))
    }

    private func gauge(progress: Double) -> some View {
        Gauge(value: progress) { EmptyView() }
            .gaugeStyle(.accessoryLinearCapacity)
            .tint(Theme.accent)
    }
}

struct UpNextWidgetView: View {

    let entry: CadenceEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if family == .accessoryRectangular {
            VStack(alignment: .leading, spacing: 1) {
                Text("Cadence").font(.caption2).foregroundStyle(.secondary)
                Text(entry.snapshot.nextBlock?.title ?? "Nothing scheduled")
                    .font(.headline).lineLimit(1)
                if let next = entry.snapshot.nextBlock {
                    Text("\(RelativeDateFormatter.time(next.start)) · \(next.durationMinutes.abbreviatedDuration)")
                        .font(.caption2)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text("Coming up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach(Array(entry.snapshot.upcomingBlocks(after: entry.date).prefix(3))) { block in
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Theme.accent)
                            .frame(width: 3, height: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(block.title).font(.subheadline).lineLimit(1)
                            Text("\(RelativeDateFormatter.time(block.start)) · \(block.durationMinutes.abbreviatedDuration)")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }
                if entry.snapshot.upcomingBlocks(after: entry.date).isEmpty {
                    Text("Nothing left today")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Preview data

extension WidgetSnapshot {
    static var previewSample: WidgetSnapshot {
        let now = Date.now
        let current = WidgetBlockSnapshot(
            id: UUID(), taskID: UUID(), title: "Write the Q4 strategy memo",
            start: now.addingTimeInterval(-25 * 60), end: now.addingTimeInterval(35 * 60),
            isPinned: false, listColorHex: "#3B82F6"
        )
        let next = WidgetBlockSnapshot(
            id: UUID(), taskID: UUID(), title: "Send September invoices",
            start: now.addingTimeInterval(50 * 60), end: now.addingTimeInterval(95 * 60),
            isPinned: false, listColorHex: "#5A6CF3"
        )
        return WidgetSnapshot(
            generatedAt: now,
            todayBlocks: [current, next],
            nextBlock: next,
            overdueCount: 1,
            plannedMinutesToday: 210,
            completedMinutesToday: 60,
            atRiskTitles: ["Renew business licence"],
            openTaskCount: 14
        )
    }
}

#Preview(as: .systemMedium) {
    TodayWidget()
} timeline: {
    CadenceEntry(date: .now, snapshot: .previewSample)
}
