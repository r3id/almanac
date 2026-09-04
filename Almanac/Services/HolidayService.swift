import Foundation

/// UK bank holidays, straight from gov.uk. No key, no account, and it's the
/// authoritative list — it moves substitute days correctly when a holiday
/// lands on a weekend.
///
/// School holidays deliberately aren't fetched: England has no national dataset,
/// because term dates are set per local authority and per academy trust. Those
/// stay hand-entered in settings.
nonisolated enum HolidayRegion: String, Codable, CaseIterable, Identifiable {
    case englandAndWales = "england-and-wales"
    case scotland
    case northernIreland = "northern-ireland"
    case none

    var id: String { rawValue }

    var label: String {
        switch self {
        case .englandAndWales: return "England & Wales"
        case .scotland:        return "Scotland"
        case .northernIreland: return "Northern Ireland"
        case .none:            return "Don't show any"
        }
    }
}

actor HolidayService {
    static let shared = HolidayService()

    private var cache: [HolidayRegion: [DayMark]] = [:]

    func bankHolidays(for region: HolidayRegion) async -> [DayMark] {
        guard region != .none else { return [] }
        if let cached = cache[region] { return cached }

        guard let url = URL(string: "https://www.gov.uk/bank-holidays.json") else { return [] }

        struct Division: Decodable {
            struct Event: Decodable {
                let title: String
                let date: String
            }
            let events: [Event]
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode([String: Division].self, from: data)
            guard let division = decoded[region.rawValue] else { return [] }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"

            let marks = division.events.compactMap { event -> DayMark? in
                guard let date = formatter.date(from: event.date) else { return nil }
                return DayMark(
                    title: event.title,
                    kind: .bankHoliday,
                    start: date.startOfDay,
                    end: date.startOfDay,
                    isAutomatic: true
                )
            }

            cache[region] = marks
            return marks
        } catch {
            return []
        }
    }
}
