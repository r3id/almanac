import Foundation

/// Counting days, once.
///
/// This was written out five separate times — in the facts, the school
/// countdowns, the pinned countdowns, the day view and the relative day label —
/// and each had drifted into its own phrasing. "3 days", "in 3 days", "3 days
/// from today". One count, two ways of saying it.
nonisolated enum DayCount {

    /// Whole calendar days between two dates. Weekends and holidays included:
    /// a thing three days away is three days away regardless of what happens in
    /// between.
    static func between(_ from: Date, and to: Date) -> Int {
        Calendar.current.dateComponents(
            [.day], from: from.startOfDay, to: to.startOfDay
        ).day ?? 0
    }

    /// "today", "tomorrow", "9 days". For anything close enough to plan around.
    static func short(_ days: Int) -> String {
        switch days {
        case ..<0:  return "\(-days) days ago"
        case 0:     return "today"
        case 1:     return "tomorrow"
        default:    return "\(days) days"
        }
    }

    /// The same, but in weeks once the number stops meaning anything. Nobody
    /// reads 266 days as anything; 38 weeks they can picture.
    static func long(_ days: Int) -> String {
        guard days >= 14 else { return short(days) }
        let weeks = days / 7
        let rest = days % 7
        if rest == 0 { return "\(weeks) weeks" }
        return "\(weeks) weeks, \(rest) day\(rest == 1 ? "" : "s")"
    }

    /// "3 days until Christmas", "Christmas is tomorrow".
    static func until(_ days: Int, _ what: String) -> String {
        switch days {
        case 0: return "\(what) is today"
        case 1: return "\(what) is tomorrow"
        default: return "\(days) days until \(what)"
        }
    }
}

nonisolated extension String {
    /// "3 days" -> "3 days", "tomorrow" -> "Tomorrow".
    var capitalizedFirst: String {
        guard let first else { return self }
        return String(first).uppercased() + dropFirst()
    }
}
