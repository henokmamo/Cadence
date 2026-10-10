//
//  CalendarScreen.swift
//  Cadence
//
//  Day & week time-blocking grid.
//
//  Interaction model (deliberate, and different from a plain calendar):
//    • Dragging a block **pins** it. The scheduler then treats it as immovable and
//      plans the rest of the week around it. Long-press → "Return to auto" unpins.
//    • Dragging the bottom edge changes the duration, not just the display, because
//      in this app a block IS the estimate.
//    • The unscheduled tray at the bottom is the honest part: anything the engine
//      couldn't fit sits there with the reason why.
//

import SwiftUI
import SwiftData

struct CalendarScreen: View {

    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context

    @State private var mode: Mode = .day
    @State private var anchorDate: Date = Calendar.current.startOfDay(for: .now)
    @State private var now = Date.now
    @State private var selectedBlock: TimeBlock?

    @Query(sort: [SortDescriptor(\TimeBlock.start)]) private var allBlocks: [TimeBlock]
    @Query(
        filter: #Predicate<TaskItem> { $0.statusRaw == "open" && $0.isSoftDeleted == false },
        sort: [SortDescriptor(\TaskItem.createdAt)]
    )
    private var openTasks: [TaskItem]

    enum Mode: String, CaseIterable { case day = "Day", week = "Week" }

    private let hourHeight: CGFloat = 62
    private var calendar: Calendar { .current }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            switch mode {
            case .day:
                DayGrid(
                    date: anchorDate,
                    blocks: blocks(on: anchorDate),
                    hourHeight: hourHeight,
                    now: now,
                    workingWindows: app.preferences.workingWindows,
                    onSelect: { selectedBlock = $0 },
                    onMove: { block, newStart, newDuration in
                        app.coordinator.move(block: block, to: newStart, durationMinutes: newDuration, now: now)
                    }
                )
            case .week:
                WeekGrid(
                    anchor: anchorDate,
                    blocks: allBlocks.filter { !$0.isSoftDeleted },
                    hourHeight: 34,
                    now: now,
                    onSelectDay: { date in
                        anchorDate = calendar.startOfDay(for: date)
                        mode = .day
                    }
                )
            }
            unscheduledTray
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle(mode == .day ? "Calendar" : "Week")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    app.applyReschedule(reason: .manual, now: now)
                } label: {
                    Label("Reschedule", systemImage: "arrow.triangle.2.circlepath")
                }
            }
        }
        .sheet(item: $selectedBlock) { block in
            BlockDetailSheet(block: block, now: now) {
                selectedBlock = nil
            }
        }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                step(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            .accessibilityLabel("Previous \(mode.rawValue.lowercased())")

            Spacer()

            VStack(spacing: 1) {
                Text(headerTitle)
                    .font(.headline)
                if !calendar.isDate(anchorDate, inSameDayAs: now) {
                    Button("Jump to today") {
                        anchorDate = calendar.startOfDay(for: now)
                    }
                    .font(.caption)
                } else {
                    Text("\(plannedMinutes(for: anchorDate).abbreviatedDuration) planned")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Button {
                step(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .accessibilityLabel("Next \(mode.rawValue.lowercased())")
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.s)
    }

    private var headerTitle: String {
        switch mode {
        case .day:
            return anchorDate.formatted(.dateTime.weekday(.wide).day().month(.abbreviated))
        case .week:
            let end = calendar.date(byAdding: .day, value: 6, to: anchorDate) ?? anchorDate
            return "\(anchorDate.formatted(.dateTime.day().month(.abbreviated))) – \(end.formatted(.dateTime.day().month(.abbreviated)))"
        }
    }

    private func step(_ direction: Int) {
        let unit: Calendar.Component = mode == .day ? .day : .weekOfYear
        if let next = calendar.date(byAdding: unit, value: direction, to: anchorDate) {
            withAnimation(.easeInOut(duration: 0.2)) { anchorDate = next }
        }
    }

    // MARK: - Data

    private func blocks(on date: Date) -> [TimeBlock] {
        allBlocks.filter { !$0.isSoftDeleted && calendar.isDate($0.start, inSameDayAs: date) }
    }

    private func plannedMinutes(for date: Date) -> Int {
        blocks(on: date).filter { $0.origin != .imported }.reduce(0) { $0 + $1.durationMinutes }
    }

    private var unscheduledTasks: [TaskItem] {
        openTasks.filter { !$0.isAnytime && $0.isPinned == false && $0.scheduledStart == nil }
    }

    // MARK: - Unscheduled tray

    private var unscheduledTray: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                SectionHeader(
                    title: "Unscheduled",
                    subtitle: unscheduledTasks.isEmpty ? "everything fits" : "\(unscheduledTasks.count) waiting",
                    systemImage: "tray.full",
                    tint: unscheduledTasks.isEmpty ? .secondary : Theme.warning
                )
                if !unscheduledTasks.isEmpty {
                    Button("Plan all") {
                        for task in unscheduledTasks { task.notBefore = now }
                        app.applyReschedule(reason: .manual, now: now)
                    }
                    .font(.caption.weight(.semibold))
                }
            }

            if unscheduledTasks.isEmpty {
                Text("Nothing waiting — the week is fully planned.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Theme.Space.s) {
                        ForEach(Array(unscheduledTasks.prefix(12))) { task in
                            Button {
                                task.notBefore = now
                                app.applyReschedule(reason: .taskChanged, now: now)
                            } label: {
                                UnscheduledCard(task: task)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .padding(.horizontal, Theme.Space.l)
        .padding(.vertical, Theme.Space.m)
        .background(.bar)
    }
}

// MARK: - Day grid

private struct DayGrid: View {

    let date: Date
    let blocks: [TimeBlock]
    let hourHeight: CGFloat
    let now: Date
    let workingWindows: [WorkingWindow]
    let onSelect: (TimeBlock) -> Void
    let onMove: (TimeBlock, Date, Int) -> Void

    @State private var dragState: DragState = .idle

    private var calendar: Calendar { .current }

    private enum DragState: Equatable {
        case idle
        case moving(blockID: UUID, offsetY: CGFloat)
        case resizing(blockID: UUID, heightDelta: CGFloat)

        var blockID: UUID? {
            switch self {
            case .idle: return nil
            case let .moving(id, _): return id
            case let .resizing(id, _): return id
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .topLeading) {
                    hourGrid
                    workingHoursShading
                    blocksLayer
                    if calendar.isDate(date, inSameDayAs: now) {
                        nowIndicator
                    }
                }
                .frame(height: hourHeight * 24)
                .padding(.horizontal, Theme.Space.l)
            }
            .onAppear {
                // Start the day view around the working day rather than at midnight.
                let firstHour = defaultFirstHour
                proxy.scrollTo(hourAnchorID(firstHour), anchor: .top)
            }
        }
    }

    private var defaultFirstHour: Int {
        let starts = workingWindows.map(\.startMinutes).min() ?? 9 * 60
        return max(0, starts / 60 - 1)
    }

    private func hourAnchorID(_ hour: Int) -> String { "hour-\(hour)" }

    private var hourGrid: some View {
        VStack(spacing: 0) {
            ForEach(0..<24, id: \.self) { hour in
                HStack(alignment: .top, spacing: Theme.Space.s) {
                    Text(RelativeDateFormatter.timeOfDay(minutesFromMidnight: hour * 60))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 46, alignment: .trailing)
                        .offset(y: -6)
                    Rectangle()
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 1)
                    Spacer(minLength: 0)
                }
                .frame(height: hourHeight, alignment: .top)
                .id(hourAnchorID(hour))
            }
        }
    }

    /// Shade the hours outside the user's working windows so it's obvious why the
    /// scheduler didn't use them.
    private var workingHoursShading: some View {
        let day = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: day)
        let rules = workingWindows.filter { $0.weekday == weekday && $0.isValid }
        return ZStack(alignment: .topLeading) {
            ForEach(0..<24, id: \.self) { hour in
                let covered = rules.contains { hour * 60 >= $0.startMinutes && hour * 60 < $0.endMinutes }
                if !covered {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.05))
                        .frame(height: hourHeight)
                        .offset(x: 58, y: CGFloat(hour) * hourHeight)
                }
            }
        }
        .allowsHitTesting(false)
    }

    private var blocksLayer: some View {
        ForEach(layout, id: \.block.id) { item in
            BlockView(
                block: item.block,
                hourHeight: hourHeight,
                laneIndex: item.lane,
                laneCount: item.laneCount,
                isDragging: dragState.blockID == item.block.id,
                dragOffsetY: offset(for: item.block.id),
                onTap: { onSelect(item.block) },
                onMoveGesture: { translation in
                    dragState = .moving(blockID: item.block.id, offsetY: translation)
                },
                onResizeGesture: { delta in
                    dragState = .resizing(blockID: item.block.id, heightDelta: delta)
                },
                onGestureEnd: { kind, value in
                    commit(kind: kind, block: item.block, value: value)
                    dragState = .idle
                }
            )
        }
    }

    private var nowIndicator: some View {
        let minutes = Double(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now))
        let y = CGFloat(minutes / 60) * hourHeight
        return HStack(spacing: 4) {
            Circle()
                .fill(Theme.danger)
                .frame(width: 7, height: 7)
            Rectangle()
                .fill(Theme.danger)
                .frame(height: 1)
        }
        .offset(x: 52, y: y)
        .allowsHitTesting(false)
    }

    // MARK: - Layout maths

    private struct LayoutItem {
        let block: TimeBlock
        let lane: Int
        let laneCount: Int
    }

    /// Simple lane packing so overlapping blocks sit side by side instead of on top.
    private var layout: [LayoutItem] {
        let sorted = blocks.sorted { $0.start < $1.start }
        var items: [LayoutItem] = []
        var cluster: [TimeBlock] = []
        var clusterEnd: Date = .distantPast

        func flush() {
            guard !cluster.isEmpty else { return }
            var laneEnds: [Date] = []
            var assignments: [(TimeBlock, Int)] = []
            for block in cluster {
                if let lane = laneEnds.firstIndex(where: { $0 <= block.start }) {
                    laneEnds[lane] = block.end
                    assignments.append((block, lane))
                } else {
                    laneEnds.append(block.end)
                    assignments.append((block, laneEnds.count - 1))
                }
            }
            let laneCount = max(1, laneEnds.count)
            items.append(contentsOf: assignments.map { LayoutItem(block: $0.0, lane: $0.1, laneCount: laneCount) })
            cluster = []
        }

        for block in sorted {
            if block.start >= clusterEnd && !cluster.isEmpty { flush() }
            cluster.append(block)
            clusterEnd = max(clusterEnd, block.end)
        }
        flush()
        return items
    }

    private func offset(for blockID: UUID) -> CGFloat {
        switch dragState {
        case .idle: return 0
        case let .moving(id, offsetY): return id == blockID ? offsetY : 0
        case let .resizing(id, heightDelta): return id == blockID ? heightDelta : 0
        }
    }

    // MARK: - Commit

    private func commit(kind: BlockView.GestureKind, block: TimeBlock, value: CGFloat) {
        switch kind {
        case .move:
            let minutes = snappedMinutes(fromDrag: value)
            guard minutes != 0 else { return }
            let newStart = block.start.addingTimeInterval(TimeInterval(minutes * 60))
            onMove(block, newStart, block.durationMinutes)
        case .resize:
            let extra = snappedMinutes(fromDrag: value, minimum: 15)
            onMove(block, block.start, max(15, block.durationMinutes + extra))
        }
    }

    private func snappedMinutes(fromDrag offsetY: CGFloat, minimum: Int = 5) -> Int {
        let raw = Double(offsetY / hourHeight) * 60
        let snapped = (raw / 5).rounded() * 5
        if abs(snapped) < Double(minimum) { return 0 }
        return Int(snapped)
    }
}

// MARK: - Block view

private struct BlockView: View {

    enum GestureKind { case move, resize }

    let block: TimeBlock
    let hourHeight: CGFloat
    let laneIndex: Int
    let laneCount: Int
    let isDragging: Bool
    let dragOffsetY: CGFloat
    let onTap: () -> Void
    let onMoveGesture: (CGFloat) -> Void
    let onResizeGesture: (CGFloat) -> Void
    let onGestureEnd: (GestureKind, CGFloat) -> Void

    private var calendar: Calendar { .current }

    private var yPosition: CGFloat {
        let comps = calendar.dateComponents([.hour, .minute], from: block.start)
        let minutes = Double((comps.hour ?? 0) * 60 + (comps.minute ?? 0))
        return CGFloat(minutes / 60) * hourHeight
    }

    private var height: CGFloat {
        max(18, CGFloat(block.durationMinutes) / 60 * hourHeight)
    }

    private var color: Color {
        Theme.blockColor(
            for: block.origin,
            isPinned: block.isPinned,
            listColorHex: block.task?.list?.colorHex
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let availableWidth = proxy.size.width - 58
            let laneWidth = max(56, (availableWidth - CGFloat(laneCount - 1) * 6) / CGFloat(laneCount))

            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 3) {
                        Text(block.task?.displayTitle ?? "Busy")
                            .font(.caption.weight(.semibold))
                            .lineLimit(height > 40 ? 2 : 1)
                        if block.isPinned {
                            Image(systemName: "pin.fill").font(.system(size: 8))
                        }
                        if block.origin == .imported {
                            Image(systemName: "calendar").font(.system(size: 8))
                        }
                    }
                    if height > 34 {
                        Text(RelativeDateFormatter.timeRange(block.start, block.end))
                            .font(.system(size: 10))
                            .opacity(0.85)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.blockCornerRadius, style: .continuous)
                        .fill(color.opacity(block.origin == .imported ? 0.55 : 0.92))
                )
                .overlay(alignment: .bottom) {
                    if block.origin != .imported {
                        Rectangle()
                            .fill(Color.clear)
                            .frame(height: 12)
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 2)
                                    .onChanged { onResizeGesture($0.translation.height) }
                                    .onEnded { onGestureEnd(.resize, $0.translation.height) }
                            )
                            .accessibilityLabel("Resize block")
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(width: laneWidth, height: height, alignment: .top)
            .offset(
                x: 58 + CGFloat(laneIndex) * (laneWidth + 6),
                y: yPosition + (height > 24 ? dragOffsetY : 0)
            )
            .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.9), value: isDragging)
            .gesture(
                DragGesture(minimumDistance: 6)
                    .onChanged { onMoveGesture($0.translation.height) }
                    .onEnded { onGestureEnd(.move, $0.translation.height) }
            )
            .onTapGesture(perform: onTap)
            .contextMenu {
                Button {
                    onTap()
                } label: {
                    Label("Details", systemImage: "info.circle")
                }
            }
            .blockAccessibilityLabel(
                title: block.task?.displayTitle ?? "Busy",
                start: block.start,
                end: block.end,
                detail: block.isPinned ? "pinned" : block.origin.label
            )
        }
        .frame(height: hourHeight * 24, alignment: .top)
    }
}

// MARK: - Week grid

private struct WeekGrid: View {

    let anchor: Date
    let blocks: [TimeBlock]
    let hourHeight: CGFloat
    let now: Date
    let onSelectDay: (Date) -> Void

    private var calendar: Calendar { .current }

    private var days: [Date] {
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? anchor
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(days, id: \.self) { day in
                    Button {
                        onSelectDay(day)
                    } label: {
                        VStack(spacing: 2) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(day.formatted(.dateTime.day()))
                                .font(.callout.weight(calendar.isDate(day, inSameDayAs: now) ? .bold : .regular))
                                .foregroundStyle(calendar.isDate(day, inSameDayAs: now) ? Theme.accent : .primary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
            Divider()

            ScrollView {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(days, id: \.self) { day in
                        VStack(spacing: 0) {
                            ForEach(0..<24, id: \.self) { hour in
                                Rectangle()
                                    .fill(Color.primary.opacity(0.05))
                                    .frame(height: 1)
                                    .frame(maxHeight: .infinity, alignment: .top)
                                    .overlay(alignment: .topLeading) {
                                        ZStack(alignment: .topLeading) {
                                            ForEach(blocks(on: day).filter { isBlock($0, inHour: hour, of: day) }) { block in
                                                weekBlock(block)
                                            }
                                        }
                                    }
                                    .frame(height: hourHeight, alignment: .top)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .overlay(alignment: .top) {
                            if calendar.isDate(day, inSameDayAs: now) {
                                Rectangle()
                                    .fill(Theme.danger)
                                    .frame(height: 1)
                                    .offset(y: nowOffset)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { onSelectDay(day) }
                    }
                }
            }
        }
    }

    private var nowOffset: CGFloat {
        let minutes = Double(calendar.component(.hour, from: now) * 60 + calendar.component(.minute, from: now))
        return CGFloat(minutes / 60) * hourHeight
    }

    private func blocks(on day: Date) -> [TimeBlock] {
        blocks.filter { calendar.isDate($0.start, inSameDayAs: day) }
    }

    private func isBlock(_ block: TimeBlock, inHour hour: Int, of day: Date) -> Bool {
        guard let hourStart = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
              let hourEnd = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { return false }
        return block.start < hourEnd && hourStart < block.end
    }

    private func weekBlock(_ block: TimeBlock) -> some View {
        let color = Theme.blockColor(
            for: block.origin,
            isPinned: block.isPinned,
            listColorHex: block.task?.list?.colorHex
        )
        let height = max(6, CGFloat(block.durationMinutes) / 60 * hourHeight)
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(color.opacity(block.origin == .imported ? 0.5 : 0.9))
            .frame(height: height)
            .overlay(alignment: .topLeading) {
                if height > 26 {
                    Text(block.task?.displayTitle ?? "")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 1)
    }
}

// MARK: - Block detail sheet

struct BlockDetailSheet: View {

    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    let block: TimeBlock
    let now: Date
    let onClose: () -> Void

    @State private var showingEditor = false

    var body: some View {
        NavigationStack {
            List {
                if let task = block.task {
                    Section {
                        VStack(alignment: .leading, spacing: Theme.Space.s) {
                            Text(task.displayTitle)
                                .font(.headline)
                            if !task.notes.isEmpty {
                                Text(task.notes).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }
                    }

                    Section("Scheduled") {
                        LabeledContent("Start", value: RelativeDateFormatter.stamp(block.start))
                        LabeledContent("Duration", value: block.durationMinutes.abbreviatedDuration)
                        LabeledContent("Source", value: block.origin.label)
                        if let reason = task.lastScheduleReason {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Why here?").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                Text(reason).font(.footnote)
                            }
                        }
                    }

                    Section {
                        Button {
                            app.complete(task: task, at: now)
                            onClose()
                            dismiss()
                        } label: {
                            Label("Complete task", systemImage: "checkmark.circle")
                        }

                        Button {
                            app.coordinator.snoozeCurrentBlock(of: task, minutes: 15, now: now)
                            dismiss()
                        } label: {
                            Label("Snooze 15 minutes", systemImage: "clock.arrow.circlepath")
                        }

                        if task.isPinned {
                            Button {
                                app.coordinator.unpin(task: task, now: now)
                                dismiss()
                            } label: {
                                Label("Return to auto-scheduling", systemImage: "pin.slash")
                            }
                        } else {
                            Button {
                                app.coordinator.move(
                                    block: block,
                                    to: block.start,
                                    durationMinutes: block.durationMinutes,
                                    now: now
                                )
                                dismiss()
                            } label: {
                                Label("Pin this time", systemImage: "pin")
                            }
                        }

                        Button(role: .destructive) {
                            context.delete(block)
                            try? context.save()
                            app.applyReschedule(reason: .blockMoved, now: now)
                            onClose()
                            dismiss()
                        } label: {
                            Label("Remove this block", systemImage: "trash")
                        }
                    }

                    Section {
                        Button {
                            showingEditor = true
                        } label: {
                            Label("Edit task", systemImage: "square.and.pencil")
                        }
                    }
                } else {
                    ContentUnavailableView("Imported event", systemImage: "calendar",
                                           description: Text("From your iOS Calendar. Cadence plans around it and never changes it."))
                }
            }
            .navigationTitle("Block")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        onClose()
                        dismiss()
                    }
                }
            }
            .sheet(isPresented: $showingEditor) {
                if let task = block.task {
                    TaskEditorView(task: task)
                }
            }
        }
    }
}

// MARK: - Unscheduled card

private struct UnscheduledCard: View {
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: "plus.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Theme.accent)
                Text(task.estimateMinutes.abbreviatedDuration)
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text(task.displayTitle)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let deadline = task.deadline {
                Text("by \(RelativeDateFormatter.day(deadline))")
                    .font(.caption2)
                    .foregroundStyle(task.isOverdue ? Theme.danger : .secondary)
            }
        }
        .frame(width: 132, alignment: .leading)
        .padding(Theme.Space.s)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.06))
        )
    }
}
