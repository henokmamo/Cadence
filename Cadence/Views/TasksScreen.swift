//
//  TasksScreen.swift
//  Cadence
//
//  Everything you own, organised by smart lists and your own lists.
//  Bulk actions live here (select many → schedule now / move / delete) because
//  that is the fastest way to recover from a week that got away from you.
//

import SwiftUI
import SwiftData

struct TasksScreen: View {

    @Environment(AppEnvironment.self) private var app
    @Environment(\.modelContext) private var context

    @State private var selection: TasksFilter = .today
    @State private var searchText = ""
    @State private var editorTarget: EditorTarget?
    @State private var editMode: EditMode = .inactive
    @State private var selectedTaskIDs: Set<UUID> = []

    @Query(sort: [SortDescriptor(\TaskItem.createdAt)]) private var allTasks: [TaskItem]
    @Query(sort: [SortDescriptor(\TaskList.sortIndex)]) private var lists: [TaskList]

    private var calendar: Calendar { .current }

    var body: some View {
        List(selection: $selectedTaskIDs) {
            Section {
                Picker("Filter", selection: $selection) {
                    ForEach(TasksFilter.allCases) { filter in
                        Text(filter.title).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .listRowInsets(EdgeInsets(top: 8, leading: 12, bottom: 8, trailing: 12))
                .listRowBackground(Color.clear)
            }

            if filteredTasks.isEmpty {
                Section {
                    EmptyHint(
                        systemImage: searchText.isEmpty ? "tray" : "magnifyingglass",
                        title: searchText.isEmpty ? "Nothing here" : "No matches",
                        message: searchText.isEmpty
                            ? "Add a task and Cadence will slot it into your week."
                            : "Try a different search."
                    )
                    .listRowBackground(Color.clear)
                }
            } else {
                Section {
                    ForEach(filteredTasks) { task in
                        Button {
                            editorTarget = .existing(task)
                        } label: {
                            TaskRow(task: task) { toggle(task) }
                        }
                        .buttonStyle(.plain)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) {
                                    delete(task)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                Button {
                                    task.notBefore = .now
                                    app.applyReschedule(reason: .taskChanged)
                                } label: {
                                    Label("Schedule now", systemImage: "wand.and.stars")
                                }
                                .tint(Theme.accent)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    adjustDeadline(task, by: 1)
                                } label: {
                                    Label("+1 day", systemImage: "calendar.badge.plus")
                                }
                                .tint(Theme.warning)
                            }
                            .tag(task.id)
                    }
                } header: {
                    HStack {
                        Text(selection.title)
                        Spacer()
                        Text("\(filteredTasks.count)")
                    }
                } footer: {
                    Text(footerText)
                }
            }

            if !lists.isEmpty, searchText.isEmpty {
                Section("Lists") {
                    ForEach(lists) { list in
                        Button {
                            editorTarget = .new(preferredList: list)
                        } label: {
                            HStack(spacing: Theme.Space.m) {
                                Image(systemName: list.symbolName)
                                    .foregroundStyle(Color(hex: list.colorHex))
                                    .frame(width: 22)
                                Text(list.name)
                                Spacer()
                                Text("\(list.openTasks.count)")
                                    .foregroundStyle(.secondary)
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "Search tasks")
        .environment(\.editMode, $editMode)
        .navigationTitle("Tasks")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                EditButton()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        editorTarget = .new(preferredList: lists.first(where: \.isInbox))
                    } label: {
                        Label("New task", systemImage: "plus")
                    }
                    Button {
                        createList()
                    } label: {
                        Label("New list", systemImage: "folder.badge.plus")
                    }
                    Divider()
                    Button {
                        app.applyReschedule(reason: .manual)
                    } label: {
                        Label("Reschedule everything", systemImage: "arrow.triangle.2.circlepath")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            if editMode == .active {
                ToolbarItem(placement: .bottomBar) {
                    bulkActions
                }
            }
        }
        .sheet(item: $editorTarget) { target in
            switch target {
            case .existing(let task):
                TaskEditorView(task: task)
            case .new(let preferredList):
                TaskEditorView(task: nil, presetList: preferredList)
            }
        }
        .overlay(alignment: .bottom) {
            if editMode == .inactive {
                Button {
                    editorTarget = .new(preferredList: lists.first(where: \.isInbox))
                } label: {
                    Label("New task", systemImage: "plus")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Theme.Space.l)
                        .padding(.vertical, 10)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundStyle(.white)
                        .shadow(color: Theme.accent.opacity(0.3), radius: 8, y: 3)
                }
                .padding(.bottom, Theme.Space.l)
            }
        }
    }

    // MARK: - Bulk actions

    @ViewBuilder
    private var bulkActions: some View {
        HStack {
            Button {
                bulkSchedule()
            } label: {
                Label("Schedule", systemImage: "wand.and.stars")
            }
            .disabled(selectedTaskIDs.isEmpty)
            Spacer()
            Menu {
                ForEach(lists) { list in
                    Button(list.name) { bulkMove(to: list) }
                }
            } label: {
                Label("Move", systemImage: "folder")
            }
            .disabled(selectedTaskIDs.isEmpty || lists.isEmpty)
            Spacer()
            Button(role: .destructive) {
                bulkDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .disabled(selectedTaskIDs.isEmpty)
        }
    }

    // MARK: - Filtering

    private var filteredTasks: [TaskItem] {
        let base = allTasks.filter { !$0.isSoftDeleted }
        let searched: [TaskItem]
        if searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            searched = base
        } else {
            searched = base.filter { task in
                task.title.localizedCaseInsensitiveContains(searchText)
                    || task.notes.localizedCaseInsensitiveContains(searchText)
                    || task.tags.contains { $0.name.localizedCaseInsensitiveContains(searchText) }
            }
        }

        switch selection {
        case .today:
            return searched.filter { task in
                guard task.isOpen else { return false }
                guard let start = task.scheduledStart else { return task.isOverdue }
                return calendar.isDate(start, inSameDayAs: .now)
            }
        case .upcoming:
            return searched.filter { task in
                guard task.isOpen, let start = task.scheduledStart else { return false }
                return start > .now && !calendar.isDate(start, inSameDayAs: .now)
            }
        case .anytime:
            return searched.filter { $0.isOpen && ($0.isAnytime || $0.scheduledStart == nil) }
        case .all:
            return searched.filter(\.isOpen)
        case .completed:
            return searched.filter(\.isCompleted).sorted { ($0.completedAt ?? .distantPast) > ($1.completedAt ?? .distantPast) }
        }
    }

    private var footerText: String {
        let tasks = filteredTasks
        guard !tasks.isEmpty else { return "" }
        let minutes = tasks.reduce(0) { $0 + $1.estimateMinutes }
        let unscheduled = tasks.filter { $0.scheduledStart == nil && !$0.isCompleted }.count
        if selection == .completed {
            return "\(tasks.count) completed."
        }
        return "\(minutes.abbreviatedDuration) of work · \(unscheduled) not placed yet"
    }

    // MARK: - Actions

    private func toggle(_ task: TaskItem) {
        if task.isCompleted {
            task.reopen()
            try? context.save()
            app.applyReschedule(reason: .taskChanged)
        } else {
            app.complete(task: task)
        }
    }

    private func delete(_ task: TaskItem) {
        context.delete(task)
        try? context.save()
        app.applyReschedule(reason: .taskChanged, silent: true)
    }

    private func adjustDeadline(_ task: TaskItem, by days: Int) {
        let anchor = task.deadline ?? .now
        task.deadline = calendar.date(byAdding: .day, value: days, to: anchor)
        task.touch()
        try? context.save()
        app.applyReschedule(reason: .taskChanged, silent: true)
    }

    private func createList() {
        let palette = ["#5A6CF3", "#3B82F6", "#10B981", "#F59E0B", "#EF4444", "#8B5CF6"]
        let list = TaskList(
            name: "New list",
            colorHex: palette[lists.count % palette.count],
            symbolName: "folder",
            sortIndex: Double(lists.count)
        )
        context.insert(list)
        try? context.save()
    }

    private func bulkSchedule() {
        for task in allTasks where selectedTaskIDs.contains(task.id) {
            task.notBefore = .now
        }
        try? context.save()
        app.applyReschedule(reason: .taskChanged)
        selectedTaskIDs.removeAll()
    }

    private func bulkMove(to list: TaskList) {
        for task in allTasks where selectedTaskIDs.contains(task.id) {
            task.list = list
            task.touch()
        }
        try? context.save()
        selectedTaskIDs.removeAll()
    }

    private func bulkDelete() {
        for task in allTasks where selectedTaskIDs.contains(task.id) {
            context.delete(task)
        }
        try? context.save()
        selectedTaskIDs.removeAll()
        app.applyReschedule(reason: .taskChanged, silent: true)
    }
}

// MARK: - Editor presentation

private enum EditorTarget: Identifiable {
    case new(preferredList: TaskList?)
    case existing(TaskItem)

    var id: String {
        switch self {
        case .new: return "new-task"
        case .existing(let task): return task.id.uuidString
        }
    }
}

// MARK: - Filters

enum TasksFilter: String, CaseIterable, Identifiable {
    case today, upcoming, anytime, all, completed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .today: return "Today"
        case .upcoming: return "Upcoming"
        case .anytime: return "Anytime"
        case .all: return "Open"
        case .completed: return "Done"
        }
    }
}
