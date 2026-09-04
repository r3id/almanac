import Foundation
import EventKit

/// Reads events out of Calendar.app and converts them to `Item`.
/// Deliberately one-way: Almanac never writes to the system calendar,
/// so nothing here can damage the user's real data.
struct CalendarBridge {

    private let eventStore = EKEventStore()

    func requestAccess() async -> Bool {
        do {
            if #available(iOS 17.0, *) {
                return try await eventStore.requestFullAccessToEvents()
            } else {
                return try await eventStore.requestAccess(to: .event)
            }
        } catch {
            return false
        }
    }

    func load(from start: Date, to end: Date, tags: [CalendarTag]) -> [Item] {
        let status = EKEventStore.authorizationStatus(for: .event)
        let allowed: Bool
        if #available(iOS 17.0, *) {
            allowed = status == .fullAccess
        } else {
            allowed = status == .authorized
        }
        guard allowed else { return [] }

        let predicate = eventStore.predicateForEvents(withStart: start, end: end, calendars: nil)
        let calendar = Calendar.current

        return eventStore.events(matching: predicate).compactMap { event -> Item? in
            guard let title = event.title, !title.isEmpty else { return nil }

            let startMinutes = calendar.component(.hour, from: event.startDate) * 60
                + calendar.component(.minute, from: event.startDate)

            var endMinutes: Int?
            if let endDate = event.endDate {
                // Clamp multi-day events to the end of their first day.
                if calendar.isDate(endDate, inSameDayAs: event.startDate) {
                    endMinutes = calendar.component(.hour, from: endDate) * 60
                        + calendar.component(.minute, from: endDate)
                } else {
                    endMinutes = 24 * 60 - 1
                }
            }

            var item = Item(
                kind: .event,
                title: title,
                day: event.startDate.startOfDay,
                start: startMinutes,
                end: endMinutes,
                isAllDay: event.isAllDay,
                place: event.location ?? "",
                calendarID: tagID(for: event.calendar, tags: tags)
            )
            item.isExternal = true
            return item
        }
    }

    /// Map the system calendar's own colour onto the closest Almanac tag,
    /// so mirrored events still read as a coherent palette.
    private func tagID(for calendar: EKCalendar?, tags: [CalendarTag]) -> String {
        guard let cgColor = calendar?.cgColor,
              let components = cgColor.components, components.count >= 3
        else { return tags.first?.id ?? CalendarTag.fallback.id }

        let r = Double(components[0]), g = Double(components[1]), b = Double(components[2])

        var best = tags.first ?? .fallback
        var bestDistance = Double.greatestFiniteMagnitude

        for tag in tags {
            var value: UInt64 = 0
            Scanner(string: tag.hex).scanHexInt64(&value)
            let tr = Double((value >> 16) & 0xFF) / 255
            let tg = Double((value >> 8) & 0xFF) / 255
            let tb = Double(value & 0xFF) / 255
            let distance = pow(r - tr, 2) + pow(g - tg, 2) + pow(b - tb, 2)
            if distance < bestDistance {
                bestDistance = distance
                best = tag
            }
        }
        return best.id
    }
}
