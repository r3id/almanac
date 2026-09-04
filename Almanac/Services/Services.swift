import Foundation
import MapKit
import UserNotifications

// MARK: - Travel

/// Real ETAs from MapKit. Free to use, no key, works with a personal team.
/// Cycling isn't a MapKit transport type, so it keeps the manual estimate.
actor TravelService {
    static let shared = TravelService()

    private var cache: [String: Int] = [:]

    /// Minutes to get there. Pass the stored coordinates when the event has a
    /// resolved place — biasing the search to a known point is what makes this
    /// reliable enough to replace the manual estimate.
    func minutes(
        to query: String,
        latitude: Double? = nil,
        longitude: Double? = nil,
        mode: TravelMode
    ) async -> Int? {
        guard mode.supportsRouting, !query.isEmpty else { return nil }

        let key = "\(query)|\(mode.rawValue)"
        if let cached = cache[key] { return cached }

        guard let destination = await findMapItem(query, latitude: latitude, longitude: longitude)
        else { return nil }

        let request = MKDirections.Request()
        request.source = MKMapItem.forCurrentLocation()
        request.destination = destination
        request.transportType = {
            switch mode {
            case .walk:    return .walking
            case .transit: return .transit
            default:       return .automobile
            }
        }()

        do {
            let response = try await MKDirections(request: request).calculateETA()
            let minutes = Int((response.expectedTravelTime / 60).rounded())
            cache[key] = minutes
            return minutes
        } catch {
            return nil
        }
    }

    /// Minutes between two places rather than from wherever you are.
    ///
    /// This is what answers "I'm at the range until eleven, karting is at twelve —
    /// do I make it?" A leg between two of your own events is a different
    /// question from a leg from home, and usually the one that matters.
    func minutes(
        fromQuery: String, fromLatitude: Double?, fromLongitude: Double?,
        toQuery: String, toLatitude: Double?, toLongitude: Double?,
        mode: TravelMode
    ) async -> Int? {
        guard mode.supportsRouting, !fromQuery.isEmpty, !toQuery.isEmpty else { return nil }

        let key = "\(fromQuery)→\(toQuery)|\(mode.rawValue)"
        if let cached = cache[key] { return cached }

        async let start = findMapItem(fromQuery, latitude: fromLatitude, longitude: fromLongitude)
        async let finish = findMapItem(toQuery, latitude: toLatitude, longitude: toLongitude)
        guard let source = await start, let destination = await finish else { return nil }

        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = {
            switch mode {
            case .walk:    return .walking
            case .transit: return .transit
            default:       return .automobile
            }
        }()

        do {
            let response = try await MKDirections(request: request).calculateETA()
            let minutes = Int((response.expectedTravelTime / 60).rounded())
            cache[key] = minutes
            return minutes
        } catch {
            return nil
        }
    }

    /// Returns the map item itself rather than a coordinate. MKPlacemark and
    /// MKMapItem.placemark are both deprecated as of iOS 26, and handing the
    /// search result straight to MKDirections avoids either of them while
    /// still building against iOS 17.
    private func findMapItem(
        _ place: String,
        latitude: Double?,
        longitude: Double?
    ) async -> MKMapItem? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = place
        if let latitude, let longitude {
            // A tight region around the saved pin, so "The Crown" resolves to
            // the one you actually picked.
            request.region = MKCoordinateRegion(
                center: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                latitudinalMeters: 2_000,
                longitudinalMeters: 2_000
            )
        }
        do {
            let response = try await MKLocalSearch(request: request).start()
            return response.mapItems.first
        } catch {
            return nil
        }
    }
}

// MARK: - On this day

nonisolated struct OnThisDayEntry {
    let year: Int
    let text: String
}

actor OnThisDayService {
    static let shared = OnThisDayService()

    private var cache: [String: OnThisDayEntry?] = [:]

    func entry(for date: Date) async -> OnThisDayEntry? {
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let key = "\(month)/\(day)"

        if let cached = cache[key] { return cached }

        let urlString = "https://api.wikimedia.org/feed/v1/wikipedia/en/onthisday/selected/\(month)/\(day)"
        guard let url = URL(string: urlString) else { return nil }

        struct Response: Decodable {
            struct Selected: Decodable {
                let year: Int
                let text: String
            }
            let selected: [Selected]?
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(Response.self, from: data)
            let entry = decoded.selected?.first.map { OnThisDayEntry(year: $0.year, text: $0.text) }
            cache[key] = entry
            return entry
        } catch {
            cache[key] = OnThisDayEntry?.none
            return nil
        }
    }
}

// MARK: - Notifications

/// Schedules one "time to leave" alert per event that has travel attached.
@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private let center = UNUserNotificationCenter.current()

    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound])
    }

    /// Schedules every alert for the next few occurrences of an item, plus a
    /// leave-time alert where there's travel attached.
    ///
    /// Everything for an item is cancelled first and rebuilt. Trying to
    /// reconcile individual requests against a changed repeat rule is far more
    /// error-prone than starting again with twelve of them.
    func reschedule(for item: Item, on dates: [Date]) async {
        await cancelAll(for: item.id)

        guard !item.isDone else { return }
        let calendar = Calendar.current

        for (index, day) in dates.enumerated() {
            // Where the alert counts back from: the start time, or 9am for
            // all-day items and birthdays.
            let anchorMinutes = item.alertsFromMorning ? 9 * 60 : item.start
            guard let anchor = calendar.date(
                bySettingHour: anchorMinutes / 60,
                minute: anchorMinutes % 60,
                second: 0,
                of: day
            ) else { continue }

            for minutes in item.alerts {
                let fireDate = anchor.addingTimeInterval(-Double(minutes) * 60)
                guard fireDate > .now else { continue }

                let content = UNMutableNotificationContent()
                content.title = item.kind == .birthday ? item.birthdayLine : item.title
                content.body = alertBody(for: item, minutes: minutes, on: day)
                content.sound = .default

                await add(
                    identifier: "item-\(item.id.uuidString)-\(index)-\(minutes)",
                    content: content,
                    fireDate: fireDate
                )
            }

            // Leave-time, only for the next occurrence — a live route estimate
            // isn't worth much three months out.
            guard index == 0, item.kind == .event, !item.isAllDay, item.travel != .none
            else { continue }

            let routed = await TravelService.shared.minutes(
                to: item.routeQuery,
                latitude: item.placeLatitude,
                longitude: item.placeLongitude,
                mode: item.travel
            )
            let travelMinutes = routed ?? item.travelMinutes
            guard travelMinutes > 0 else { continue }

            let leaveDate = anchor.addingTimeInterval(-Double(travelMinutes) * 60)
            guard leaveDate > .now else { continue }

            let content = UNMutableNotificationContent()
            content.title = "Time to leave"
            content.body = item.place.isEmpty
                ? "\(item.title) starts in \(travelMinutes) min."
                : "\(travelMinutes) min \(item.travel.phrase) to \(item.place) for \(item.title)."
            content.sound = .default

            await add(
                identifier: "leave-\(item.id.uuidString)",
                content: content,
                fireDate: leaveDate
            )
        }
    }

    private func alertBody(for item: Item, minutes: Int, on day: Date) -> String {
        let offset = AlertOption.label(minutes, fromMorning: item.alertsFromMorning)
        if item.kind == .birthday { return offset }
        if item.alertsFromMorning { return offset }
        return minutes == 0
            ? "Starting now"
            : "\(offset), at \(Item.clock(item.start))"
    }

    private func add(identifier: String, content: UNMutableNotificationContent, fireDate: Date) async {
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: fireDate
            ),
            repeats: false
        )
        try? await center.add(
            UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)
        )
    }

    private func cancelAll(for id: UUID) async {
        let pending = await center.pendingNotificationRequests()
        let mine = pending
            .map(\.identifier)
            .filter { $0.hasPrefix("item-\(id.uuidString)") || $0 == "leave-\(id.uuidString)" }
        center.removePendingNotificationRequests(withIdentifiers: mine)
    }

    /// "PE tomorrow — kit and trainers." Fires at six the evening before, which
    /// is late enough to be the right day and early enough to find the kit.
    func scheduleKitReminder(school: String, lessons: [Lesson], forDay day: Date) async {
        let subjects = lessons.map(\.subject).filter { !$0.isEmpty }
        guard !subjects.isEmpty else { return }

        let calendar = Calendar.current
        let evening = day.adding(days: -1)
        var components = calendar.dateComponents([.year, .month, .day], from: evening)
        components.hour = 18
        components.minute = 0

        guard let fireDate = calendar.date(from: components), fireDate > .now else { return }

        let list = subjects.count == 1
            ? subjects[0]
            : subjects.dropLast().joined(separator: ", ") + " and " + subjects[subjects.count - 1]

        let notes = lessons.map(\.note).filter { !$0.isEmpty }

        let content = UNMutableNotificationContent()
        content.title = school.isEmpty ? "\(list) tomorrow" : "\(school) — \(list) tomorrow"
        content.body = notes.isEmpty
            ? "Get what's needed ready tonight."
            : notes.joined(separator: " · ")
        content.sound = .default

        await add(
            identifier: "kit-\(school)-\(day.dayKey)",
            content: content,
            fireDate: fireDate
        )
    }

    func cancelKitReminders() async {
        let pending = await center.pendingNotificationRequests()
        let mine = pending.map(\.identifier).filter { $0.hasPrefix("kit-") }
        center.removePendingNotificationRequests(withIdentifiers: mine)
    }

    func cancel(id: UUID) {
        Task { await cancelAll(for: id) }
    }
}
