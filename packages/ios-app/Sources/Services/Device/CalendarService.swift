import EventKit
import Foundation

/// Handles calendar-related device requests using EventKit.
///
/// Supports listing, searching, creating, deleting events, and finding free slots.
/// All operations require calendar authorization, which is requested on first use.
final class CalendarService: @unchecked Sendable {
    static let shared = CalendarService()

    private nonisolated(unsafe) let store = EKEventStore()

    private init() {}

    // MARK: - Request Routing

    func handle(action: String, params: [String: AnyCodable]?) async throws -> [String: AnyCodable] {
        try await requestAccess()

        switch action {
        case "list":
            return try listEvents(params: params)
        case "search":
            return try searchEvents(params: params)
        case "freeSlots":
            return try findFreeSlots(params: params)
        case "create":
            return try createEvent(params: params)
        case "delete":
            return try deleteEvent(params: params)
        default:
            throw DeviceRequestError.unknownMethod("calendar.\(action)")
        }
    }

    // MARK: - Authorization

    func requestPermission() async -> Bool {
        do {
            return try await store.requestFullAccessToEvents()
        } catch {
            return false
        }
    }

    private func requestAccess() async throws {
        let granted = try await store.requestFullAccessToEvents()
        guard granted else {
            throw DeviceRequestError.permissionDenied("Calendar access denied")
        }
    }

    // MARK: - Actions

    private func listEvents(params: [String: AnyCodable]?) throws -> [String: AnyCodable] {
        let range = parseDateRange(params: params)
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        let events = store.events(matching: predicate)
        return ["events": AnyCodable(events.map { formatEvent($0) })]
    }

    private func searchEvents(params: [String: AnyCodable]?) throws -> [String: AnyCodable] {
        let query = (params?["query"]?.value as? String) ?? ""
        let range = parseDateRange(params: params)
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { event in
                event.title?.localizedCaseInsensitiveContains(query) == true ||
                event.location?.localizedCaseInsensitiveContains(query) == true ||
                event.notes?.localizedCaseInsensitiveContains(query) == true
            }
        return ["events": AnyCodable(events.map { formatEvent($0) })]
    }

    private func findFreeSlots(params: [String: AnyCodable]?) throws -> [String: AnyCodable] {
        let range = parseDateRange(params: params)
        let duration = TimeInterval((params?["duration"]?.value as? Int) ?? 30) * 60
        let predicate = store.predicateForEvents(withStart: range.start, end: range.end, calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .sorted { $0.startDate < $1.startDate }

        var slots: [[String: String]] = []
        var current = range.start

        for event in events {
            if event.startDate.timeIntervalSince(current) >= duration {
                slots.append([
                    "from": DateParser.toISO8601(current),
                    "to": DateParser.toISO8601(event.startDate)
                ])
            }
            if event.endDate > current {
                current = event.endDate
            }
        }

        if range.end.timeIntervalSince(current) >= duration {
            slots.append([
                "from": DateParser.toISO8601(current),
                "to": DateParser.toISO8601(range.end)
            ])
        }

        return ["slots": AnyCodable(slots)]
    }

    private func createEvent(params: [String: AnyCodable]?) throws -> [String: AnyCodable] {
        guard let params else { throw DeviceRequestError.unknownMethod("calendar.create: missing params") }

        let event = EKEvent(eventStore: store)
        event.title = params["title"]?.value as? String ?? "Untitled"

        if let startStr = params["startDate"]?.value as? String {
            event.startDate = DateParser.parse(startStr) ?? Date()
        } else {
            event.startDate = Date()
        }

        if let endStr = params["endDate"]?.value as? String {
            event.endDate = DateParser.parse(endStr) ?? event.startDate.addingTimeInterval(3600)
        } else {
            event.endDate = event.startDate.addingTimeInterval(3600)
        }

        event.location = params["location"]?.value as? String
        event.notes = params["notes"]?.value as? String
        event.calendar = store.defaultCalendarForNewEvents

        try store.save(event, span: .thisEvent)

        return [
            "id": AnyCodable(event.eventIdentifier ?? ""),
            "title": AnyCodable(event.title ?? ""),
            "startDate": AnyCodable(DateParser.toISO8601(event.startDate)),
            "endDate": AnyCodable(DateParser.toISO8601(event.endDate))
        ]
    }

    private func deleteEvent(params: [String: AnyCodable]?) throws -> [String: AnyCodable] {
        guard let eventId = params?["eventId"]?.value as? String else {
            throw DeviceRequestError.unknownMethod("calendar.delete: missing eventId")
        }
        guard let event = store.event(withIdentifier: eventId) else {
            return ["success": AnyCodable(false), "error": AnyCodable("Event not found")]
        }

        try store.remove(event, span: .thisEvent)
        return ["success": AnyCodable(true)]
    }

    // MARK: - Helpers

    private func parseDateRange(params: [String: AnyCodable]?) -> (start: Date, end: Date) {
        let dateRange = params?["dateRange"]?.value as? [String: Any]
        let start: Date
        var end: Date

        if let fromStr = dateRange?["from"] as? String,
           let parsed = DateParser.parse(fromStr) {
            start = parsed
        } else {
            start = Calendar.current.startOfDay(for: Date())
        }

        if let toStr = dateRange?["to"] as? String,
           let parsed = DateParser.parse(toStr) {
            end = parsed
        } else {
            end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        }

        // When from == to (date-only strings like "2026-03-10"), extend to end of day
        if end <= start {
            end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start
        }

        return (start, end)
    }

    private func formatEvent(_ event: EKEvent) -> [String: Any] {
        var dict: [String: Any] = [
            "id": event.eventIdentifier ?? "",
            "title": event.title ?? "",
            "startDate": DateParser.toISO8601(event.startDate),
            "endDate": DateParser.toISO8601(event.endDate),
            "allDay": event.isAllDay,
            "calendar": event.calendar?.title ?? ""
        ]
        if let location = event.location { dict["location"] = location }
        if let notes = event.notes { dict["notes"] = notes }
        return dict
    }
}
