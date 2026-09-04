import Foundation

/// A lesson that happens on the same day every week, or every other week.
nonisolated struct Lesson: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var subject: String = ""
    /// `Calendar` weekday, Sunday is 1.
    var weekday: Int = 2
    /// 0 means every week; otherwise the week of the cycle it falls in.
    var week: Int = 0
    /// Which lesson of the day, 1-based. The time comes from the timetable's
    /// period list, so setting 09:10 once covers every period 1 of the year.
    var period: Int = 1
    /// Room, teacher, set code — whatever's worth having. One free field rather
    /// than three, because most people won't fill in three.
    var detail: String = ""
    /// Overrides the period's time on the rare lesson that doesn't fit the grid.
    var start: Int?
    /// Lunch, break, form time — a slot that isn't a lesson. Still shown, so
    /// the day reads in order, but quietly and never with a kit reminder.
    var isBreak: Bool = false
    /// Needs something brought in, and so worth a reminder the night before.
    var needsKit: Bool = false
    /// "Kit and trainers", "swimming bag", "wellies" — what the reminder says.
    var note: String = ""



    init(
        id: UUID = UUID(),
        subject: String = "",
        weekday: Int = 2,
        week: Int = 0,
        period: Int = 1,
        detail: String = "",
        start: Int? = nil,
        isBreak: Bool = false,
        needsKit: Bool = false,
        note: String = ""
    ) {
        self.id = id
        self.subject = subject
        self.weekday = weekday
        self.week = week
        self.period = period
        self.detail = detail
        self.start = start
        self.isBreak = isBreak
        self.needsKit = needsKit
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        subject = try c.decodeIfPresent(String.self, forKey: .subject) ?? ""
        weekday = try c.decodeIfPresent(Int.self, forKey: .weekday) ?? 2
        week = try c.decodeIfPresent(Int.self, forKey: .week) ?? 0
        period = try c.decodeIfPresent(Int.self, forKey: .period) ?? 1
        detail = try c.decodeIfPresent(String.self, forKey: .detail) ?? ""
        start = try c.decodeIfPresent(Int.self, forKey: .start)
        isBreak = try c.decodeIfPresent(Bool.self, forKey: .isBreak) ?? false
        needsKit = try c.decodeIfPresent(Bool.self, forKey: .needsKit) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
    }
}

/// One school's week, and where in the cycle we currently are.
///
/// The cycle is counted straight from an anchor week rather than from term
/// dates, because schools don't agree on what happens over a holiday — some
/// carry on, some resume where they left off. Counting calendar weeks and
/// letting you re-anchor with one tap is simpler than being wrong in a way
/// that's hard to correct.
/// When the week 1 / week 2 cycle restarts. Schools don't agree, so this asks
/// rather than assumes — and the wrong answer here puts every lesson in the
/// wrong week, which is worse than no timetable at all.
nonisolated enum CycleReset: String, Codable, CaseIterable, Hashable {
    /// Advances only on weeks that contain a school day, so a holiday week
    /// doesn't move the cycle on. This is what Linslade does, and it's why
    /// counting calendar weeks drifts a week out after every half term.
    case schoolWeeks
    /// Counts straight through, holidays included.
    case continuous
    /// Week 1 on the first day of each term.
    case eachTerm
    /// Week 1 whenever school comes back — after half terms too.
    case eachBreak

    var label: String {
        switch self {
        case .schoolWeeks: return "Skips holiday weeks"
        case .continuous:  return "Counts through holidays"
        case .eachTerm:   return "Restarts each term"
        case .eachBreak:  return "Restarts after every break"
        }
    }
}

nonisolated struct Timetable: Codable, Hashable {
    /// 1 for a plain weekly timetable, 2 for the week 1 / week 2 pattern.
    var cycleLength: Int = 1
    /// Six at Linslade, eight elsewhere. Drives the grid you type into.
    var periodsPerDay: Int = 6
    /// Start time of each period, index 0 being period 1. Set once, not per
    /// lesson — the whole point of periods is that the times don't move.
    var periodStarts: [Int?] = []
    /// The Monday of a week known to be week 1. Only used when the cycle runs
    /// continuously; otherwise the term or the break sets the reference.
    var anchor: Date = Date.now.startOfWeek
    var reset: CycleReset = .schoolWeeks
    var lessons: [Lesson] = []

    var isCycled: Bool { cycleLength > 1 }

    init(
        cycleLength: Int = 1,
        periodsPerDay: Int = 6,
        periodStarts: [Int?] = [],
        anchor: Date = Date.now.startOfWeek,
        reset: CycleReset = .schoolWeeks,
        lessons: [Lesson] = []
    ) {
        self.cycleLength = cycleLength
        self.periodsPerDay = periodsPerDay
        self.periodStarts = periodStarts
        self.anchor = anchor
        self.reset = reset
        self.lessons = lessons
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cycleLength = try c.decodeIfPresent(Int.self, forKey: .cycleLength) ?? 1
        periodsPerDay = try c.decodeIfPresent(Int.self, forKey: .periodsPerDay) ?? 6
        periodStarts = try c.decodeIfPresent([Int?].self, forKey: .periodStarts) ?? []
        anchor = try c.decodeIfPresent(Date.self, forKey: .anchor) ?? Date.now.startOfWeek
        reset = try c.decodeIfPresent(CycleReset.self, forKey: .reset) ?? .schoolWeeks
        lessons = try c.decodeIfPresent([Lesson].self, forKey: .lessons) ?? []
    }

    /// Weeks elapsed from a reference Monday, folded into the cycle.
    func week(for day: Date, countingFrom reference: Date) -> Int {
        guard isCycled else { return 1 }
        let weeks = Calendar.current.dateComponents(
            [.weekOfYear], from: reference.startOfWeek, to: day.startOfWeek
        ).weekOfYear ?? 0
        return ((weeks % cycleLength) + cycleLength) % cycleLength + 1
    }

    func lessons(on day: Date, week: Int) -> [Lesson] {
        let weekday = Calendar.current.component(.weekday, from: day)
        return lessons
            .filter { $0.weekday == weekday && ($0.week == 0 || $0.week == week) }
            .sorted { $0.period < $1.period }
    }

    /// The lessons on one day of the grid, whatever the current date.
    func lessons(weekday: Int, week: Int) -> [Lesson] {
        lessons
            .filter { $0.weekday == weekday && $0.week == week }
            .sorted { $0.period < $1.period }
    }

    func start(ofPeriod period: Int) -> Int? {
        guard period >= 1, period <= periodStarts.count else { return nil }
        return periodStarts[period - 1]
    }

    func timeLabel(for lesson: Lesson) -> String? {
        if let start = lesson.start { return Item.clock(start) }
        return start(ofPeriod: lesson.period).map { Item.clock($0) }
    }
}

nonisolated extension Date {
    /// The Monday of this date's week, whatever the locale's first weekday is —
    /// a school week starts on Monday.
    var startOfWeek: Date {
        let calendar = Calendar.current
        let weekday = calendar.component(.weekday, from: self)
        let offset = (weekday + 5) % 7
        return adding(days: -offset).startOfDay
    }
}

nonisolated enum Weekday {
    /// Monday first, as a school week runs.
    static let all: [(number: Int, name: String, short: String)] = [
        (2, "Monday", "Mon"), (3, "Tuesday", "Tue"), (4, "Wednesday", "Wed"),
        (5, "Thursday", "Thu"), (6, "Friday", "Fri"),
        (7, "Saturday", "Sat"), (1, "Sunday", "Sun")
    ]

    static func name(_ number: Int) -> String {
        all.first { $0.number == number }?.name ?? ""
    }
}
