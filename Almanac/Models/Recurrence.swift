import Foundation

/// How an event repeats. Deliberately the handful of patterns people actually
/// use rather than a full RFC 5545 rule — no "third Tuesday", no exception
/// dates, because each of those needs its own editing UI to be worth having.
nonisolated struct Recurrence: Codable, Hashable {

    enum Frequency: String, Codable, CaseIterable, Hashable {
        case never, daily, weekly, fortnightly, monthly, yearly

        var label: String {
            switch self {
            case .never:       return "Never"
            case .daily:       return "Every day"
            case .weekly:      return "Every week"
            case .fortnightly: return "Every 2 weeks"
            case .monthly:     return "Every month"
            case .yearly:      return "Every year"
            }
        }

        var shortLabel: String {
            switch self {
            case .never:       return ""
            case .daily:       return "Daily"
            case .weekly:      return "Weekly"
            case .fortnightly: return "Fortnightly"
            case .monthly:     return "Monthly"
            case .yearly:      return "Yearly"
            }
        }
    }

    /// What to do when a date lands on a weekend or bank holiday.
    ///
    /// Pay dates, direct debits and rent all shift like this — the nominal date
    /// stays the 25th, but the money actually moves on the working day either
    /// side of it. Keeping the nominal date and adjusting only where it lands
    /// means the rule stays true every month rather than drifting.
    enum DateAdjustment: String, Codable, CaseIterable, Hashable {
        case keep, earlier, later

        var label: String {
            switch self {
            case .keep:    return "Keep the date"
            case .earlier: return "Working day before"
            case .later:   return "Working day after"
            }
        }

        var adjusts: Bool { self != .keep }
    }

    var frequency: Frequency = .never
    var adjustment: DateAdjustment = .keep
    /// The last day the event can fall on. Nil means it runs indefinitely.
    var until: Date?

    var repeats: Bool { frequency != .never }

    private enum CodingKeys: String, CodingKey { case frequency, adjustment, until }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        frequency = try c.decodeIfPresent(Frequency.self, forKey: .frequency) ?? .never
        adjustment = try c.decodeIfPresent(DateAdjustment.self, forKey: .adjustment) ?? .keep
        until = try c.decodeIfPresent(Date.self, forKey: .until)
    }

    /// Whether a repeat lands on this day, given the day the series starts.
    func falls(on day: Date, seriesStart: Date) -> Bool {
        guard repeats else { return false }

        let calendar = Calendar.current
        let start = seriesStart.startOfDay
        let target = day.startOfDay

        guard target > start else { return false }
        if let until, target > until.startOfDay { return false }

        switch frequency {
        case .never:
            return false

        case .daily:
            return true

        case .weekly, .fortnightly:
            guard calendar.component(.weekday, from: target) == calendar.component(.weekday, from: start)
            else { return false }
            guard frequency == .fortnightly else { return true }
            let days = calendar.dateComponents([.day], from: start, to: target).day ?? 0
            return (days / 7).isMultiple(of: 2)

        case .monthly:
            // Clamped, so a series starting on the 31st still lands in February
            // rather than skipping the short months entirely.
            let wanted = calendar.component(.day, from: start)
            let actual = calendar.component(.day, from: target)
            let lengthOfMonth = calendar.range(of: .day, in: .month, for: target)?.count ?? 31
            return actual == min(wanted, lengthOfMonth)

        case .yearly:
            return calendar.component(.month, from: target) == calendar.component(.month, from: start)
                && calendar.component(.day, from: target) == calendar.component(.day, from: start)
        }
    }

    /// "Every week until 25 Dec", for the detail view.
    func summary(from seriesStart: Date) -> String? {
        guard repeats else { return nil }
        guard let until else { return frequency.label }

        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return "\(frequency.label) until \(formatter.string(from: until))"
    }
}
