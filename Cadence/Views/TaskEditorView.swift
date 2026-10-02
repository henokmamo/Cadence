//
//  TaskEditorView.swift
//  Cadence
//
//  The full task editor. The "Scheduling" section is the interesting part: it is
//  where a user tells the engine how much freedom it has — auto-place, pin to an
//  exact time, "anytime" (keep it out of the plan), or "not before".
//

import SwiftUI
import SwiftData

struct TaskEditorView: View {

    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// nil ⇒ creating a new task.
    let task: TaskItem?
    var presetList: TaskList?

    @State private var title = ""
    @State private var notes = ""
    @State private var estimateMinutes = 30
    @State private var priority: TaskPriority = .none
    @State private var hasDeadline = false
    @State private var deadline = Date.now.addingTimeInterval(24 * 3600)
    @State private var isHardDeadline = true
    @State private var selectedList: TaskList?
    @State private var schedulingMode: SchedulingMode = .auto
    @State private var pinnedStart = Date.now.addingTimeInterval(3600)
    @State private var notBefore: Date?
    @State private var allowsSplitting = true
    @State private var repeats = false
    @State private var repeatFrequency: RepeatFrequency = .weekly
    @State private var repeatInterval = 1
    @State private var repeatWeekdays: Set<Int> = []
    @State private var repeatHasEnd = false
    @State private var repeatEnd = Date.now.addingTimeInterval(30 * 24 * 3600)
    @State private var tagNames: [String] = []
    @State private var subtasks: [(id: UUID, title: String, isDone: Bool)] = []
    @State private var newSubtaskTitle = ""

    @Query(sort: [SortDescriptor(\TaskList.sortIndex)]) private var lists: [TaskList]
    @Query(sort: [SortDescriptor(\Tag.name)]) private var allTags: [Tag]

    @FocusState private var titleFocused: Bool

    private var calendar: Calendar { .current }
    private var isNew: Bool { task == nil }

    enum SchedulingMode: String, CaseIterable, Identifiable {
        case auto, pinned, anytime
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Auto"
            case .pinned: return "Pinned"
            case .anytime: return "Anytime"
            }
        }
        var explanation: String {
            switch self {
            case .auto: return "Cadence finds the earliest free time and may split this across blocks."
            case .pinned: return "Kept exactly where you put it. The rest of the week plans around it."
            case .anytime: return "Not scheduled at all — it stays in your list until you ask for it."
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                detailsSection
                schedulingSection
                estimateSection
                organisationSection
                repeatSection
                subtasksSection
                if !isNew {
                    destructiveSection
                }
            }
            .navigationTitle(isNew ? "New task" : "Edit task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .onAppear(perform: load)
        }
    }

    // MARK: - Sections

    private var detailsSection: some View {
        Section {
            TextField("What needs doing?", text: $title, axis: .vertical)
                .lineLimit(1...3)
                .focused($titleFocused)
            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(2...6)
            Picker("Priority", selection: $priority) {
                ForEach(TaskPriority.allCases) { value in
                    Label(value.label, systemImage: value.symbolName).tag(value)
                }
            }
        }
    }

    private var schedulingSection: some View {
        Section {
            Picker("Mode", selection: $schedulingMode) {
                ForEach(SchedulingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Text(schedulingMode.explanation)
                .font(.caption)
                .foregroundStyle(.secondary)

            if schedulingMode == .pinned {
                DatePicker("Starts", selection: $pinnedStart, displayedComponents: [.date, .hourAndMinute])
            }

            Toggle("Only after a date", isOn: Binding(
                get: { notBefore != nil },
                set: { notBefore = $0 ? Date.now.addingTimeInterval(24 * 3600) : nil }
            ))
            if let value = notBefore {
                DatePicker("Not before", selection: Binding(
                    get: { value },
                    set: { notBefore = $0 }
                ), displayedComponents: [.date, .hourAndMinute])
            }

            Toggle("Can be split across blocks", isOn: $allowsSplitting)
                .disabled(schedulingMode == .anytime)
        } header: {
            Text("Scheduling")
        } footer: {
            if let reason = task?.lastScheduleReason {
                Text("Last decision: \(reason)")
            } else {
                Text("Deadlines are always respected when Cadence can manage it.")
            }
        }
    }

    private var estimateSection: some View {
        Section("Estimate") {
            DurationChipPicker(minutes: $estimateMinutes)
            Stepper(
                "\(estimateMinutes.abbreviatedDuration)",
                value: $estimateMinutes,
                in: 5...960,
                step: 5
            )
        }
    }

    private var organisationSection: some View {
        Section("Organise") {
            Picker("List", selection: $selectedList) {
                Text("None").tag(TaskList?.none)
                ForEach(lists) { list in
                    Label(list.name, systemImage: list.symbolName).tag(TaskList?.some(list))
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.s) {
                Text("Tags").font(.caption).foregroundStyle(.secondary)
                FlowChips(items: allTags.map(\.name), selected: $tagNames)
            }
        }
    }

    private var repeatSection: some View {
        Section {
            Toggle("Repeat", isOn: $repeats)
            if repeats {
                Picker("Frequency", selection: $repeatFrequency) {
                    ForEach(RepeatFrequency.allCases) { frequency in
                        Text(frequency.label).tag(frequency)
                    }
                }
                Stepper("Every \(repeatInterval) \(repeatFrequency.label.lowercased())",
                        value: $repeatInterval, in: 1...30)

                if repeatFrequency == .weekly {
                    WeekdayPicker(selected: $repeatWeekdays)
                }

                Toggle("Ends on a date", isOn: $repeatHasEnd)
                if repeatHasEnd {
                    DatePicker("Ends", selection: $repeatEnd, displayedComponents: [.date])
                }
            }
        } header: {
            Text("Repeat")
        } footer: {
            Text("Completing a repeating task books the next occurrence in automatically.")
        }
    }

    private var subtasksSection: some View {
        Section("Subtasks") {
            ForEach(subtasks, id: \.id) { item in
                HStack(spacing: Theme.Space.s) {
                    Button {
                        toggleSubtask(item.id)
                    } label: {
                        CompletionCircle(isCompleted: item.isDone, size: 20)
                    }
                    .buttonStyle(.plain)
                    Text(item.title)
                        .strikethrough(item.isDone)
                    Spacer()
                    Button {
                        subtasks.removeAll { $0.id == item.id }
                    } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                TextField("Add a step", text: $newSubtaskTitle)
                    .onSubmit(addSubtask)
                Button {
                    addSubtask()
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.plain)
                .disabled(newSubtaskTitle.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var destructiveSection: some View {
        Section {
            Button(role: .destructive) {
                if let task {
                    context.delete(task)
                    try? context.save()
                    app.applyReschedule(reason: .taskChanged, silent: true)
                }
                dismiss()
            } label: {
                Label("Delete task", systemImage: "trash")
            }
        }
    }

    // MARK: - Load / save

    private func load() {
        guard let task else {
            selectedList = presetList ?? lists.first(where: \.isInbox)
            if repeatWeekdays.isEmpty {
                repeatWeekdays = [calendar.component(.weekday, from: .now) - 1]
            }
            return
        }
        title = task.title
        notes = task.notes
        estimateMinutes = task.estimateMinutes
        priority = task.priority
        hasDeadline = task.deadline != nil
        deadline = task.deadline ?? deadline
        isHardDeadline = task.isHardDeadline
        selectedList = task.list
        schedulingMode = task.isAnytime ? .anytime : (task.isPinned ? .pinned : .auto)
        pinnedStart = task.scheduledStart ?? pinnedStart
        notBefore = task.notBefore
        allowsSplitting = task.allowsSplitting
        repeats = task.isRecurring
        repeatFrequency = task.repeatFrequency ?? .weekly
        repeatInterval = task.repeatInterval
        repeatWeekdays = Set(task.repeatDaysOfWeek.map { $0 })
        repeatHasEnd = task.repeatEndDate != nil
        repeatEnd = task.repeatEndDate ?? repeatEnd
        tagNames = task.tags.map(\.name)
        subtasks = task.subtasks
            .sorted { $0.sortIndex < $1.sortIndex }
            .map { (id: $0.id, title: $0.title, isDone: $0.isDone) }
    }

    private func save() {
        let target: TaskItem
        if let task {
            target = task
        } else {
            target = TaskItem(title: title, estimateMinutes: estimateMinutes, list: selectedList)
            context.insert(target)
        }

        target.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        target.notes = notes
        target.estimateMinutes = max(5, estimateMinutes)
        target.priority = priority
        target.deadline = hasDeadline ? deadline : nil
        target.isHardDeadline = isHardDeadline
        target.list = selectedList ?? lists.first(where: \.isInbox)
        target.allowsSplitting = allowsSplitting
        target.notBefore = notBefore
        target.isAnytime = (schedulingMode == .anytime)

        switch schedulingMode {
        case .pinned:
            target.isPinned = true
            target.scheduledStart = pinnedStart
            target.scheduledEnd = pinnedStart.addingTimeInterval(TimeInterval(max(5, estimateMinutes) * 60))
            for block in target.blocks where block.isEngineOwned { context.delete(block) }
            let block = TimeBlock(start: pinnedStart, end: target.scheduledEnd!, origin: .user, isPinned: true, task: target)
            context.insert(block)
        case .auto:
            if target.isPinned {
                target.isPinned = false
                for block in target.blocks where block.origin == .user {
                    block.isPinned = false
                    block.origin = .auto
                    block.isUserCreated = false
                }
            }
        case .anytime:
            target.isPinned = false
            for block in target.blocks where block.isEngineOwned { context.delete(block) }
            target.scheduledStart = nil
            target.scheduledEnd = nil
        }

        if repeats {
            target.repeatFrequency = repeatFrequency
            target.repeatInterval = repeatInterval
            target.repeatDaysOfWeekMask = RecurrenceRule.mask(fromIndices: repeatWeekdays)
            target.repeatEndDate = repeatHasEnd ? repeatEnd : nil
        } else {
            target.repeatFrequency = nil
        }

        applyTags(to: target)
        applySubtasks(to: target)
        target.touch()
        try? context.save()

        app.applyReschedule(reason: .taskChanged)
        dismiss()
    }

    private func applyTags(to target: TaskItem) {
        var resolved: [Tag] = []
        for name in tagNames {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let existing = allTags.first(where: { $0.name.localizedCaseInsensitiveCompare(trimmed) == .orderedSame }) {
                resolved.append(existing)
            } else {
                let tag = Tag(name: trimmed)
                context.insert(tag)
                resolved.append(tag)
            }
        }
        target.tags = resolved
    }

    private func applySubtasks(to target: TaskItem) {
        // Replace the set: simple, and cheap at this scale.
        for existing in target.subtasks { context.delete(existing) }
        target.subtasks = subtasks.enumerated().map { index, item in
            Subtask(title: item.title, isDone: item.isDone, sortIndex: Double(index))
        }
    }

    private func addSubtask() {
        let trimmed = newSubtaskTitle.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        subtasks.append((id: UUID(), title: trimmed, isDone: false))
        newSubtaskTitle = ""
    }

    private func toggleSubtask(_ id: UUID) {
        guard let index = subtasks.firstIndex(where: { $0.id == id }) else { return }
        subtasks[index].isDone.toggle()
    }
}

// MARK: - Weekday picker

struct WeekdayPicker: View {
    @Binding var selected: Set<Int>

    var body: some View {
        HStack(spacing: 6) {
            ForEach(RelativeDateFormatter.orderedWeekdaySymbols, id: \.index) { day in
                Button {
                    if selected.contains(day.index) {
                        selected.remove(day.index)
                    } else {
                        selected.insert(day.index)
                    }
                } label: {
                    Text(day.short)
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(selected.contains(day.index) ? Theme.accent : Color(.secondarySystemFill))
                        )
                        .foregroundStyle(selected.contains(day.index) ? .white : .primary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(day.full)
                .accessibilityAddTraits(selected.contains(day.index) ? .isSelected : [])
            }
        }
    }
}

// MARK: - Tiny flow layout for tag chips

struct FlowChips: View {
    let items: [String]
    @Binding var selected: [String]
    @State private var newTag = ""

    private var allItems: [String] {
        var result = items
        for tag in selected where !result.contains(tag) { result.append(tag) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            HStack {
                TextField("Add tag", text: $newTag)
                    .font(.subheadline)
                    .onSubmit(add)
                Button("Add", action: add)
                    .font(.caption)
                    .disabled(newTag.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if !allItems.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(allItems, id: \.self) { item in
                            Button {
                                toggle(item)
                            } label: {
                                Text(item)
                                    .font(.caption)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(
                                        Capsule().fill(selected.contains(item) ? Theme.accent.opacity(0.2) : Color(.secondarySystemFill))
                                    )
                                    .overlay(
                                        Capsule().strokeBorder(selected.contains(item) ? Theme.accent : .clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func add() {
        let trimmed = newTag.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        if !selected.contains(trimmed) { selected.append(trimmed) }
        newTag = ""
    }

    private func toggle(_ item: String) {
        if let index = selected.firstIndex(of: item) {
            selected.remove(at: index)
        } else {
            selected.append(item)
        }
    }
}
