//
//  Components.swift
//  Cadence
//
//  Small shared views. Kept deliberately dumb — no data access, no scheduling logic —
//  so they can be previewed and reused across Today, Tasks, Calendar and the editor.
//

import SwiftUI

// MARK: - Completion circle

struct CompletionCircle: View {
    let isCompleted: Bool
    var color: Color = Theme.accent
    var size: CGFloat = 24

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(isCompleted ? color : Color.secondary.opacity(0.45), lineWidth: 1.8)
                .frame(width: size, height: size)
            if isCompleted {
                Circle().fill(color).frame(width: size, height: size)
                Image(systemName: "checkmark")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
        .contentShape(Rectangle())
    }
}

// MARK: - Progress ring (current block)

struct ProgressRing: View {
    /// 0…1
    let progress: Double
    var lineWidth: CGFloat = 6
    var color: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeInOut(duration: 0.3), value: progress)
    }
}

// MARK: - Duration chips

struct DurationChipPicker: View {
    @Binding var minutes: Int
    var presets: [Int] = [15, 30, 45, 60, 90, 120]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Space.s) {
                ForEach(presets, id: \.self) { preset in
                    Button {
                        minutes = preset
                    } label: {
                        Text(preset.abbreviatedDuration)
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, Theme.Space.m)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    minutes == preset
                                        ? Theme.accent.opacity(0.18)
                                        : Color(.secondarySystemFill)
                                )
                            )
                            .overlay(
                                Capsule().strokeBorder(
                                    minutes == preset ? Theme.accent : .clear,
                                    lineWidth: 1
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(preset) minutes")
                }
            }
            .padding(.vertical, 1)
        }
    }
}

// MARK: - Meta chips

struct MetaChip: View {
    let systemImage: String
    let text: String
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: systemImage).font(.caption2)
            Text(text).font(.caption)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
    }
}

struct PriorityBadge: View {
    let priority: TaskPriority

    var body: some View {
        if priority == .none {
            EmptyView()
        } else {
            Image(systemName: priority.symbolName)
                .font(.caption2.weight(.bold))
                .foregroundStyle(Theme.priorityColor(priority))
                .accessibilityLabel("\(priority.label) priority")
        }
    }
}

// MARK: - Section header

struct SectionHeader: View {
    let title: String
    var subtitle: String?
    var systemImage: String?
    var tint: Color = .secondary
    var trailing: AnyView?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.s) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tint)
            }
            Text(title.uppercased())
                .font(.footnote.weight(.semibold))
                .foregroundStyle(tint)
            if let subtitle {
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let trailing { trailing }
        }
        .padding(.top, Theme.Space.s)
    }
}

// MARK: - Task row

struct TaskRow: View {
    let task: TaskItem
    var showsScheduleInfo: Bool = true
    var onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.m) {
            Button(action: onToggle) {
                CompletionCircle(isCompleted: task.isCompleted)
                    .accessibilityLabel(task.isCompleted ? "Mark as not done" : "Mark as done")
            }
            .buttonStyle(.plain)
            .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: Theme.Space.s) {
                    Text(task.displayTitle)
                        .font(.body)
                        .strikethrough(task.isCompleted, color: .secondary)
                        .foregroundStyle(task.isCompleted ? .secondary : .primary)
                        .lineLimit(2)

                    PriorityBadge(priority: task.priority)
                }

                HStack(spacing: Theme.Space.s) {
                    if let list = task.list, !list.isInbox {
                        MetaChip(systemImage: list.symbolName, text: list.name, tint: Color(hex: list.colorHex))
                    }
                    if showsScheduleInfo {
                        scheduleChip
                    }
                    if let deadline = task.deadline {
                        MetaChip(
                            systemImage: task.isOverdue ? "exclamationmark.triangle" : "flag",
                            text: RelativeDateFormatter.deadlineStamp(deadline),
                            tint: task.isOverdue ? Theme.danger : .secondary
                        )
                    }
                    if task.isPinned {
                        MetaChip(systemImage: "pin.fill", text: "Pinned", tint: Theme.blockPinned)
                    }
                    if task.subtaskProgress.total > 0 {
                        MetaChip(
                            systemImage: "checklist",
                            text: "\(task.subtaskProgress.done)/\(task.subtaskProgress.total)",
                            tint: .secondary
                        )
                    }
                }
                .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var scheduleChip: some View {
        if let info = scheduleChipInfo {
            MetaChip(systemImage: info.icon, text: info.text, tint: info.tint)
        }
        if task.blocks.count > 1 {
            MetaChip(
                systemImage: "square.stack.3d.up",
                text: "\(task.blocks.count) blocks",
                tint: .secondary
            )
        }
    }

    /// One chip's worth of "when is this happening" — or nil when there's nothing
    /// honest to say (a completed task, for instance).
    private var scheduleChipInfo: (icon: String, text: String, tint: Color)? {
        if task.isAnytime {
            return ("infinity", "Anytime", .secondary)
        }
        if let start = task.scheduledStart {
            return (
                task.isPinned ? "pin.fill" : "clock",
                "\(RelativeDateFormatter.day(start)) \(RelativeDateFormatter.time(start))",
                task.isPinned ? Theme.blockPinned : Theme.accent
            )
        }
        if task.isOpen {
            return ("questionmark.circle", "Not placed yet", Theme.warning)
        }
        return nil
    }
}

// MARK: - Unscheduled tray row

struct UnscheduledTaskRow: View {
    let task: TaskItem
    var reason: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.Space.s) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.caption)
                    .foregroundStyle(Theme.warning)
                Text(task.displayTitle)
                    .font(.subheadline)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(task.estimateMinutes.abbreviatedDuration)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let reason {
                Text(reason)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Empty state

struct EmptyHint: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(title).font(.subheadline.weight(.semibold))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Theme.Space.l)
    }
}
