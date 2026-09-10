import Foundation

// MARK: - Kind

nonisolated enum ItemKind: String, Codable, CaseIterable, Hashable {
    case event
    case action
    case birthday

    var label: String {
        switch self {
        case .event:    return "Event"
        case .action:   return "Action"
        case .birthday: return "Birthday"
        }
    }
}

// MARK: - Travel

nonisolated enum TravelMode: String, Codable, CaseIterable, Hashable {
    case none, walk, cycle, drive, transit

    var label: String {
        switch self {
        case .none:    return "No travel"
        case .walk:    return "Walk"
        case .cycle:   return "Cycle"
        case .drive:   return "Drive"
        case .transit: return "Transit"
        }
    }

    /// Reads naturally inside "1h 58min. to drive so you should leave before 10:01 AM"
    var phrase: String {
        switch self {
        case .none:    return ""
        case .walk:    return "to walk"
        case .cycle:   return "to cycle"
        case .drive:   return "to drive"
        case .transit: return "on transit"
        }
    }

    var symbol: String {
        switch self {
        case .none:    return "circle"
        case .walk:    return "figure.walk"
        case .cycle:   return "bicycle"
        case .drive:   return "car.fill"
        case .transit: return "tram.fill"
        }
    }

    /// MapKit has no cycling directions, so cycling always uses the manual estimate.
    var supportsRouting: Bool {
        self == .walk || self == .drive || self == .transit
    }
}

// MARK: - Calendar tag

nonisolated struct CalendarTag: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var hex: String

    /// Only what a new install starts with. Rename them, recolour them, add your
    /// own — the set lives in the store, not in here.
    static let defaults: [CalendarTag] = [
        .init(id: "amber",   name: "Personal", hex: "E9A13B"),
        .init(id: "blue",    name: "Work",     hex: "2F6BBD"),
        .init(id: "crimson", name: "Social",   hex: "C9284D"),
        .init(id: "green",   name: "Health",   hex: "38A169"),
        .init(id: "plum",    name: "Family",   hex: "B56BBD")
    ]

    static let fallback = CalendarTag(id: "amber", name: "Personal", hex: "E9A13B")
}

// MARK: - Item

/// A single thing on a day. Timed events, all-day events and untimed actions
/// are all the same type so a day can render them in one pass.
nonisolated struct Item: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var kind: ItemKind = .event
    var title: String = ""

    /// Always normalised to the start of the day.
    var day: Date = Calendar.current.startOfDay(for: .now)

    /// Minutes from midnight. Ignored for actions and all-day events.
    var start: Int = 9 * 60
    var end: Int? = 10 * 60

    var isAllDay: Bool = false
    var isDone: Bool = false

    var place: String = ""
    /// Full address from the place search, kept so routing can find the venue
    /// again without guessing which "The Crown" you meant.
    var placeAddress: String = ""
    var placeLatitude: Double?
    var placeLongitude: Double?

    var travel: TravelMode = .none
    /// Only used when there are no coordinates to route from.
    var travelMinutes: Int = 0

    var calendarID: String = "amber"

    /// Pinned as something to count down to — a holiday, a flight, a birthday.
    var countsDown: Bool = false

    var recurrence = Recurrence()

    /// One-off moves, keyed by the date the rule nominally produced.
    ///
    /// Some dates don't follow any rule. Employers pay early before Christmas
    /// because they decide to, not because a formula says so — no adjustment
    /// setting can predict the 20th. Rather than pretend otherwise, a single
    /// occurrence can be dragged somewhere else and the series carries on
    /// untouched around it.
    var movedOccurrences: [String: Date] = [:]

    /// Occurrences that simply don't happen — the week Arthur skips swimming.
    /// Keyed the same way as moves, so the series is untouched around them.
    var skippedOccurrences: Set<String> = []

    /// Birthdays store the actual date of birth, so the age falls out of the
    /// year rather than needing its own field to be kept in step. Turn this off
    /// when the year isn't known, or isn't yours to publish.
    var showsAge: Bool = true

    /// Minutes before the event to be told about it. For all-day items and
    /// birthdays the offset is measured from 9am on the day, since "0 minutes
    /// before an all-day event" would otherwise mean midnight.
    var alerts: [Int] = []

    /// Free text, and a link for the ones that happen somewhere online.
    var notes: String = ""
    var url: String = ""

    /// Set only on the copies the store generates for a repeat. Holds the day
    /// the series actually starts, so editing an occurrence edits the series
    /// instead of dragging the whole thing onto the day you happened to open.
    var seriesStart: Date?

    /// The date the rule nominally fell on, when an adjustment moved it. Lets
    /// the detail view say "moved from Sunday the 25th" rather than silently
    /// showing a different date than the one you set.
    var nominalDay: Date?

    /// True for items mirrored in from the system calendar. Never persisted,
    /// never editable — the source of truth stays in Calendar.app.
    var isExternal: Bool = false

    var isOccurrence: Bool { seriesStart != nil }

    /// The age being turned on this occurrence, or nil when it isn't a birthday,
    /// the year is hidden, or it's the birth date itself.
    var age: Int? {
        guard kind == .birthday, showsAge else { return nil }
        let calendar = Calendar.current
        let born = calendar.component(.year, from: seriesStart ?? day)
        let turning = calendar.component(.year, from: day) - born
        return turning > 0 ? turning : nil
    }

    /// Whether alerts are measured from 9am rather than from a start time.
    var alertsFromMorning: Bool { kind != .event || isAllDay }

    /// "Arthur turns 9" reads better on the day than "Arthur — 9".
    var birthdayLine: String {
        guard let age else { return title }
        return "\(title) turns \(age)"
    }

    /// The date the rule produced for whatever is on screen. Skips and moves are
    /// pinned to this, not to the day it ended up on.
    var nominalKey: String { (nominalDay ?? day).dayKey }

    /// Dates lifted out of the series, newest first, for the editor to list.
    var exceptions: [(key: String, date: Date, movedTo: Date?)] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let keys = Set(movedOccurrences.keys).union(skippedOccurrences)
        return keys.compactMap { key -> (String, Date, Date?)? in
            guard let date = formatter.date(from: key) else { return nil }
            return (key, date, movedOccurrences[key])
        }
        .sorted { $0.1 < $1.1 }
    }

    /// A URL only if it's one we can actually open.
    var link: URL? {
        let trimmed = url.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let direct = URL(string: trimmed), direct.scheme != nil { return direct }
        return URL(string: "https://\(trimmed)")
    }

    /// True once the location is a real pin rather than typed text, which is
    /// when travel time stops being an estimate.
    var hasResolvedPlace: Bool { placeLatitude != nil && placeLongitude != nil }

    /// The string routing should search for.
    var routeQuery: String {
        placeAddress.isEmpty ? place : "\(place), \(placeAddress)"
    }

    /// End used for layout and for "free afterwards" logic.
    var effectiveEnd: Int { max(end ?? (start + 60), start + 15) }

    /// Runs past midnight. Stored as minutes from the start day, so 11pm to
    /// midnight is 1380 to 1440 rather than a second date to keep in step.
    var endsNextDay: Bool { effectiveEnd > 24 * 60 }

    /// A new event at the next whole hour, running for an hour.
    ///
    /// A fixed 9am default meant almost every event needed both times changing.
    /// Rounding up to the next hour is what Apple's calendar does, and "add
    /// something" nearly always means soon.
    static func draft(on day: Date) -> Item {
        let calendar = Calendar.current
        let now = Date.now

        var hour = calendar.component(.hour, from: now)
        if calendar.component(.minute, from: now) > 0 { hour += 1 }

        // Past eleven at night there's no hour left to offer, and clamping back
        // to 10pm proposes a time that's already gone. Tomorrow morning is the
        // likelier intent, and it's visible rather than silent.
        if hour >= 23 {
            var item = Item(day: day.startOfDay.adding(days: 1))
            item.start = 9 * 60
            item.end = 10 * 60
            return item
        }

        var item = Item(day: day.startOfDay)
        item.start = hour * 60
        item.end = hour * 60 + 60
        return item
    }


    /// What the day grid can actually draw, which stops at midnight.
    var endWithinDay: Int { min(effectiveEnd, 24 * 60) }

    var timeLabel: String {
        if kind == .action { return "Action" }
        if kind == .birthday { return "Birthday" }
        if isAllDay { return "ALL DAY" }
        let s = Self.clock(start)
        guard let end else { return s }
        let label = "\(s) → \(Self.clock(end))"
        return endsNextDay ? label + " +1" : label
    }

    static func clock(_ minutes: Int) -> String {
        let m = ((minutes % 1440) + 1440) % 1440
        var hour = m / 60
        let suffix = hour >= 12 ? "PM" : "AM"
        hour = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", hour, m % 60, suffix)
    }

    /// Sort order within a day: all-day first, then by start time, then actions.
    static func daySort(_ a: Item, _ b: Item) -> Bool {
        func rank(_ i: Item) -> Int {
            switch i.kind {
            case .birthday: return 0
            case .action:   return 3
            case .event:    return i.isAllDay ? 1 : 2
            }
        }
        if rank(a) != rank(b) { return rank(a) < rank(b) }
        if rank(a) == 2 { return a.start < b.start }
        return a.title < b.title
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, day, start, end, isAllDay, isDone
        case place, placeAddress, placeLatitude, placeLongitude
        case travel, travelMinutes, calendarID, countsDown
        case recurrence, notes, url, movedOccurrences, skippedOccurrences
        case showsAge, alerts
    }

    init(
        id: UUID = UUID(),
        kind: ItemKind = .event,
        title: String = "",
        day: Date = Calendar.current.startOfDay(for: .now),
        start: Int = 9 * 60,
        end: Int? = 10 * 60,
        isAllDay: Bool = false,
        isDone: Bool = false,
        place: String = "",
        placeAddress: String = "",
        placeLatitude: Double? = nil,
        placeLongitude: Double? = nil,
        travel: TravelMode = .none,
        travelMinutes: Int = 0,
        calendarID: String = "amber",
        countsDown: Bool = false,
        recurrence: Recurrence = Recurrence(),
        movedOccurrences: [String: Date] = [:],
        skippedOccurrences: Set<String> = [],
        showsAge: Bool = true,
        alerts: [Int] = [],
        notes: String = "",
        url: String = "",
        seriesStart: Date? = nil,
        nominalDay: Date? = nil,
        isExternal: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.day = day
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.isDone = isDone
        self.place = place
        self.placeAddress = placeAddress
        self.placeLatitude = placeLatitude
        self.placeLongitude = placeLongitude
        self.travel = travel
        self.travelMinutes = travelMinutes
        self.calendarID = calendarID
        self.countsDown = countsDown
        self.recurrence = recurrence
        self.movedOccurrences = movedOccurrences
        self.skippedOccurrences = skippedOccurrences
        self.showsAge = showsAge
        self.alerts = alerts
        self.notes = notes
        self.url = url
        self.seriesStart = seriesStart
        self.nominalDay = nominalDay
        self.isExternal = isExternal
    }

    /// Decoded key by key so events saved by an earlier build survive a schema
    /// change instead of taking the whole file down with them.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        kind = ItemKind(rawValue: try c.decodeIfPresent(String.self, forKey: .kind) ?? "event") ?? .event
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        day = try c.decodeIfPresent(Date.self, forKey: .day) ?? Calendar.current.startOfDay(for: .now)
        start = try c.decodeIfPresent(Int.self, forKey: .start) ?? 9 * 60
        end = try c.decodeIfPresent(Int.self, forKey: .end)
        isAllDay = try c.decodeIfPresent(Bool.self, forKey: .isAllDay) ?? false
        isDone = try c.decodeIfPresent(Bool.self, forKey: .isDone) ?? false
        place = try c.decodeIfPresent(String.self, forKey: .place) ?? ""
        placeAddress = try c.decodeIfPresent(String.self, forKey: .placeAddress) ?? ""
        placeLatitude = try c.decodeIfPresent(Double.self, forKey: .placeLatitude)
        placeLongitude = try c.decodeIfPresent(Double.self, forKey: .placeLongitude)
        travel = TravelMode(rawValue: try c.decodeIfPresent(String.self, forKey: .travel) ?? "none") ?? .none
        travelMinutes = try c.decodeIfPresent(Int.self, forKey: .travelMinutes) ?? 0
        calendarID = try c.decodeIfPresent(String.self, forKey: .calendarID) ?? "amber"
        countsDown = try c.decodeIfPresent(Bool.self, forKey: .countsDown) ?? false
        recurrence = try c.decodeIfPresent(Recurrence.self, forKey: .recurrence) ?? Recurrence()
        movedOccurrences = try c.decodeIfPresent([String: Date].self, forKey: .movedOccurrences) ?? [:]
        skippedOccurrences = try c.decodeIfPresent(Set<String>.self, forKey: .skippedOccurrences) ?? []
        showsAge = try c.decodeIfPresent(Bool.self, forKey: .showsAge) ?? true
        alerts = try c.decodeIfPresent([Int].self, forKey: .alerts) ?? []
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        url = try c.decodeIfPresent(String.self, forKey: .url) ?? ""
        seriesStart = nil
        nominalDay = nil
        isExternal = false
    }
}

// MARK: - Day helpers

nonisolated extension Date {
    var startOfDay: Date { Calendar.current.startOfDay(for: self) }

    /// Stable key for a calendar day, used to pin one-off moves to the date the
    /// rule produced rather than to an index that shifts as a series changes.
    var dayKey: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: self)
    }

    func adding(days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }

    func isSameDay(as other: Date) -> Bool {
        Calendar.current.isDate(self, inSameDayAs: other)
    }

    var weekOfYear: Int {
        Calendar.current.component(.weekOfYear, from: self)
    }

    /// "TODAY", "3 DAYS FROM TODAY", "2 DAYS AGO"
    /// "13 DAYS FROM TODAY". Shares the counting with everything else but keeps
    /// its own phrasing — a bare "13 DAYS" under a date reads as a duration.
    var relativeLabel: String {
        let days = DayCount.between(.now, and: self)
        switch days {
        case 0:    return "TODAY"
        case 1:    return "TOMORROW"
        case -1:   return "YESTERDAY"
        case ..<0: return "\(-days) DAYS AGO"
        default:   return "\(days) DAYS FROM TODAY"
        }
    }

}

/// Wrapper so a Date can drive `.fullScreenCover(item:)`.
nonisolated struct DayRef: Identifiable, Hashable {
    let date: Date
    var id: TimeInterval { date.timeIntervalSince1970 }
}

/// A resolved journey to an event: how long, by what means, and from where.
nonisolated struct TravelLeg: Hashable {
    var minutes: Int
    var mode: TravelMode
    /// The event this leg starts from, when it isn't just "from wherever you are".
    var fromTitle: String?

    var durationLabel: String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)m" : "\(minutes) min"
    }
}

/// The alert offsets offered in the editor. Deliberately a short list — a free
/// number field invites fiddling and produces "37 minutes before".
nonisolated enum AlertOption {
    static let timed: [Int] = [0, 5, 15, 30, 60, 120, 1440]
    static let allDay: [Int] = [0, 1440, 2880, 10080]

    static func label(_ minutes: Int, fromMorning: Bool) -> String {
        if fromMorning {
            switch minutes {
            case 0:     return "On the day, 9am"
            case 1440:  return "The day before, 9am"
            case 2880:  return "Two days before"
            case 10080: return "A week before"
            default:    return "\(minutes / 1440) days before"
            }
        }
        switch minutes {
        case 0:    return "At the time"
        case 60:   return "1 hour before"
        case 120:  return "2 hours before"
        case 1440: return "1 day before"
        default:   return "\(minutes) minutes before"
        }
    }
}
