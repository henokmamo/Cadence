//
//  CalendarService.swift
//  Cadence
//
//  EventKit, read-only in v1.0.
//
//  We deliberately do NOT write events back to the user's calendar in v1 — importing
//  busy time is already a big win, and write-back is the kind of feature that needs its
//  own permission story, undo model and per-list opt-ins. Scheduled in the roadmap (1.5).
//
//  Requires Info.plist keys:
//    NSCalendarsFullAccessUsageDescription (iOS 17+)
//    NSCalendarsUsageDescription          (older fallback path)
//

import Foundation
import EventKit

@Observable
@MainActor
final class CalendarService {

    private let store = EKEventStore()

    private(set) var authorizationStatus: EKAuthorizationStatus
    private(set) var lastImportError: String?

    init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .fullAccess, .authorized: return true
        default: return false
        }
    }

    var isDenied: Bool {
        authorizationStatus == .denied || authorizationStatus == .restricted
    }

    // MARK: - Permission

    func requestAccess() async -> Bool {
        do {
            let granted = try await store.requestFullAccessToEvents()
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return granted
        } catch {
            lastImportError = error.localizedDescription
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            return false
        }
    }

    // MARK: - Calendars

    struct CalendarInfo: Identifiable, Hashable {
        let id: String
        let title: String
        let colorHex: String
        let accountTitle: String
    }

    func availableCalendars() -> [CalendarInfo] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event).map { calendar in
            CalendarInfo(
                id: calendar.calendarIdentifier,
                title: calendar.title,
                colorHex: calendar.cgColor.flatMap { ColorHex.string(from: $0) } ?? "#8E8E93",
                accountTitle: calendar.source?.title ?? "Calendar"
            )
        }
    }

    // MARK: - Busy time

    /// One importable calendar event. `id` is the EventKit event identifier plus the
    /// occurrence start, so recurring events produce distinct, stable rows.
    struct ImportedEvent: Identifiable, Hashable {
        let id: String
        let title: String
        let start: Date
        let end: Date
        let calendarTitle: String
    }

    /// Events the scheduler must plan around.
    ///
    /// Rules:
    ///   • All-day events are ignored — they are almost always context (holidays,
    ///     birthdays, travel days), not time you can't work. Callers can opt in later.
    ///   • Events you declined are ignored.
    ///   • Events explicitly marked "free" are ignored.
    func importedEvents(in range: DateInterval, excluding excludedCalendarIDs: Set<String>) -> [ImportedEvent] {
        guard isAuthorized else { return [] }
        let calendars = store.calendars(for: .event).filter { !excludedCalendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)
        let events = store.events(matching: predicate)

        return events.compactMap { event -> ImportedEvent? in
            guard !event.isAllDay else { return nil }
            guard event.availability != .free else { return nil }
            guard let start = event.startDate, let end = event.endDate, end > start else { return nil }
            if let attendees = event.attendees,
               attendees.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) {
                return nil
            }
            let occurrenceKey = "\(event.eventIdentifier ?? UUID().uuidString)@\(Int(start.timeIntervalSince1970))"
            return ImportedEvent(
                id: occurrenceKey,
                title: event.title ?? "Busy",
                start: start,
                end: end,
                calendarTitle: event.calendar?.title ?? "Calendar"
            )
        }
        .sorted { $0.start < $1.start }
    }

    /// Re-import trigger. EventKit posts this when the calendar database changes.
    func observeExternalChanges(_ handler: @escaping () -> Void) {
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { _ in handler() }
    }
}

// MARK: - CGColor → hex

import CoreGraphics

enum ColorHex {
    static func string(from cgColor: CGColor) -> String? {
        guard let components = cgColor.components else { return nil }
        switch components.count {
        case 3:
            return String(
                format: "#%02X%02X%02X",
                Int(components[0] * 255), Int(components[1] * 255), Int(components[2] * 255)
            )
        case 4:
            return String(
                format: "#%02X%02X%02X",
                Int(components[1] * 255), Int(components[2] * 255), Int(components[3] * 255)
            )
        default:
            return nil
        }
    }
}
