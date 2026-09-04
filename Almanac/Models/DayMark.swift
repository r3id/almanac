import SwiftUI

/// A property of a *day*, not a thing happening on it.
///
/// Bank holidays, school holidays and inset days are facts about the shape of a
/// day. Most calendars import them as all-day events, which is why they push your
/// real plans down the page. Marks live in their own layer: they tint the date and
/// add a small label, and they never appear in the schedule.
nonisolated enum DayMarkKind: String, Codable, CaseIterable, Hashable {
    case bankHoliday
    case schoolHoliday
    case halfTerm
    case insetDay
    case termBoundary
    case custom

    var label: String {
        switch self {
        case .bankHoliday:   return "Bank holiday"
        case .schoolHoliday: return "School holiday"
        case .halfTerm:      return "Half term"
        case .insetDay:      return "Inset day"
        case .termBoundary:  return "Term boundary"
        case .custom:        return "Other"
        }
    }

    /// Muted on purpose. Marks are context, so they must never out-shout an event.
    var tint: Color {
        switch self {
        case .bankHoliday:   return Color(hex: "8FA0AE")
        case .schoolHoliday: return Color(hex: "7FA88C")
        case .halfTerm:      return Color(hex: "6FA8A0")
        case .insetDay:      return Color(hex: "C4A46A")
        case .termBoundary:  return Color(hex: "8AA6C4")
        case .custom:        return Color(hex: "9A9AA2")
        }
    }

    /// Weekends are already weekends. Nothing you mark needs to say so again, so
    /// this is on for everything you enter by hand — you switch it off for the
    /// rare range, like a trip, that genuinely runs through a Saturday.
    ///
    /// Bank holidays are the exception: gov.uk is authoritative and its
    /// substitute days are always weekdays, so there is nothing to filter and
    /// filtering could only ever hide a real one.
    var defaultWeekdaysOnly: Bool {
        self != .bankHoliday && self != .termBoundary
    }

    /// Single-day marks can't sensibly be stretched, so the editor hides the
    /// end date for them.
    var isSingleDay: Bool { self == .insetDay || self == .bankHoliday || self == .termBoundary }
}

nonisolated struct DayMark: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var title: String = ""
    var kind: DayMarkKind = .custom

    /// Both ends inclusive, both normalised to the start of the day.
    var start: Date = Date.now.startOfDay
    var end: Date = Date.now.startOfDay

    /// When true the mark skips Saturdays and Sundays inside its range.
    var weekdaysOnly: Bool = true

    /// Which school this belongs to. Nil for bank holidays and for anything
    /// that predates schools.
    var schoolID: UUID?

    /// True for anything fetched rather than typed, so a refresh can replace it
    /// without touching the ranges you entered by hand.
    var isAutomatic: Bool = false

    func covers(_ day: Date) -> Bool {
        let key = day.startOfDay
        guard key >= start.startOfDay, key <= end.startOfDay else { return false }
        if weekdaysOnly {
            let weekday = Calendar.current.component(.weekday, from: key)
            if weekday == 1 || weekday == 7 { return false }
        }
        return true
    }

    /// True on the first day the mark actually shows, so the timeline can label
    /// a range once instead of on all fourteen days of it.
    ///
    /// Looks back three days rather than one, because with weekends filtered out
    /// a fortnight's holiday is two separate runs of weekdays and would otherwise
    /// print its name twice.
    func isFirstVisibleDay(_ day: Date) -> Bool {
        guard covers(day) else { return false }
        for back in 1...3 where covers(day.adding(days: -back)) { return false }
        return true
    }

    /// True on the last day a range shows, so a run can be closed off as well as
    /// opened. Looks ahead three days for the same reason the opening check looks
    /// back three: weekends split a range into separate runs of weekdays.
    func isLastVisibleDay(_ day: Date) -> Bool {
        guard covers(day) else { return false }
        for ahead in 1...3 where covers(day.adding(days: ahead)) { return false }
        return true
    }

    /// Days actually marked, which is not the same as days spanned.
    var markedDayCount: Int {
        let span = (Calendar.current.dateComponents([.day], from: start.startOfDay, to: end.startOfDay).day ?? 0) + 1
        guard span > 0 else { return 0 }
        return (0..<span).filter { covers(start.adding(days: $0)) }.count
    }

    var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        if start.isSameDay(as: end) { return formatter.string(from: start) }
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    // Tolerate marks written by older builds — "term" no longer exists as a kind.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        let raw = try c.decodeIfPresent(String.self, forKey: .kind) ?? "custom"
        let known = DayMarkKind(rawValue: raw)
        kind = known ?? .custom
        start = try c.decodeIfPresent(Date.self, forKey: .start) ?? .now.startOfDay
        end = try c.decodeIfPresent(Date.self, forKey: .end) ?? start
        // An unrecognised kind means this was written before the kind existed or
        // after it was removed. Either way it predates the weekdaysOnly flag, so
        // it gets the safe answer rather than the old behaviour.
        weekdaysOnly = try c.decodeIfPresent(Bool.self, forKey: .weekdaysOnly)
            ?? (known?.defaultWeekdaysOnly ?? true)
        schoolID = try c.decodeIfPresent(UUID.self, forKey: .schoolID)
        isAutomatic = try c.decodeIfPresent(Bool.self, forKey: .isAutomatic) ?? false
    }

    init(
        id: UUID = UUID(),
        title: String = "",
        kind: DayMarkKind = .custom,
        start: Date = Date.now.startOfDay,
        end: Date = Date.now.startOfDay,
        weekdaysOnly: Bool? = nil,
        schoolID: UUID? = nil,
        isAutomatic: Bool = false
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.start = start
        self.end = end
        self.weekdaysOnly = weekdaysOnly ?? kind.defaultWeekdaysOnly
        self.schoolID = schoolID
        self.isAutomatic = isAutomatic
    }
}

// MARK: - Working week

/// Which weekdays count as working days. Stored as `Calendar` weekday numbers,
/// where Sunday is 1 — the same convention `Calendar.component(.weekday:)` returns.
nonisolated struct WorkWeek: Codable, Hashable {
    var days: Set<Int> = [2, 3, 4, 5, 6]
    var isHighlighted: Bool = false

    func isWorkday(_ date: Date) -> Bool {
        days.contains(Calendar.current.component(.weekday, from: date))
    }

    static let weekdayNames: [(number: Int, name: String)] = [
        (2, "Monday"), (3, "Tuesday"), (4, "Wednesday"), (5, "Thursday"),
        (6, "Friday"), (7, "Saturday"), (1, "Sunday")
    ]
}
