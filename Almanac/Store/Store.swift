import Foundation
import Observation

@Observable
@MainActor
final class Store {

    // MARK: Persisted state

    private(set) var items: [Item] = []
    /// Hand-entered ranges: half terms, inset days, trips.
    private(set) var dayMarks: [DayMark] = []
    /// One timetable per school, keyed by its id.
    private(set) var timetables: [UUID: Timetable] = [:]
    /// Your calendars. Seeded with a starter set, then yours to rename, recolour
    /// and add to — the app shouldn't be picking your colours for you.
    private(set) var calendars: [CalendarTag] = CalendarTag.defaults
    /// One per child at a different school. Stays a single unnamed entry for
    /// almost everyone, and nothing in the UI mentions schools until there are two.
    private(set) var schools: [School] = []
    /// Term dates as your council publishes them. The holidays between them are
    /// derived, never typed.
    private(set) var schoolTerms: [SchoolTerm] = []

    var themeName: String = "Deep Teal" { didSet { persist() } }
    /// The place you set by hand. Stays put.
    var homeName: String = "" { didSet { persist() } }
    var homeLatitude: Double? { didSet { persist() } }
    var homeLongitude: Double? { didSet { persist() } }
    /// When on, weather and daylight follow you instead of home.
    var useCurrentLocation: Bool = false { didSet { persist() } }
    var workWeek = WorkWeek() { didSet { persist() } }
    var holidayRegion: HolidayRegion = .englandAndWales {
        didSet { persist(); Task { await refreshHolidays() } }
    }
    var showAlmanacLines: Bool = true { didSet { persist() } }
    /// Count in school days rather than calendar days. Off by default: a break
    /// three days away is three days away, whether or not two of them are the
    /// weekend.
    var countInSchoolDays: Bool = false { didSet { persist() } }
    /// Off until asked for. CloudKit aborts the whole process if the iCloud
    /// entitlement is missing, so nothing may touch a `CKContainer` before
    /// someone has deliberately turned sync on.
    var syncEnabled: Bool = false { didSet { persist() } }
    /// The two things the app can't work out for itself.
    var userName: String = "" { didSet { persist() } }
    var birthday: Date? { didSet { persist() } }
    var showSystemCalendars: Bool = false {
        didSet {
            guard !suppressCalendarSideEffects else { return }
            persist()
            Task { await refreshExternal() }
        }
    }

    // MARK: Runtime only

    /// Items mirrored in from Calendar.app. Read-only, never written to disk.
    private(set) var external: [Item] = []
    /// Bank holidays from gov.uk, refreshed on launch.
    private(set) var automaticMarks: [DayMark] = []
    /// Holidays worked out from the gaps between terms. Rebuilt whenever the
    /// terms change, rather than recomputed inside every calendar cell.
    private(set) var derivedHolidays: [DayMark] = []
    /// Where you are now. Runtime only — never written to disk.
    private(set) var currentName: String = ""
    private(set) var currentLatitude: Double?
    private(set) var currentLongitude: Double?

    var theme: Theme { Theme.named(themeName) }

    /// What the day view should actually use: current location when you've asked
    /// for it and it's available, home otherwise. Nil means neither is set.
    var activeLocation: (name: String, latitude: Double, longitude: Double)? {
        if useCurrentLocation, let lat = currentLatitude, let lon = currentLongitude {
            return (currentName.isEmpty ? "Current location" : currentName, lat, lon)
        }
        if let lat = homeLatitude, let lon = homeLongitude, !homeName.isEmpty {
            return (homeName, lat, lon)
        }
        return nil
    }

    var hasHome: Bool { homeLatitude != nil && homeLongitude != nil }

    /// Safe to talk to CloudKit: switched on, and not currently writing changes
    /// that came from CloudKit in the first place.
    var canSync: Bool { syncEnabled && !isApplyingRemote }

    // MARK: Calendars

    func tag(_ id: String) -> CalendarTag {
        calendars.first { $0.id == id } ?? calendars.first ?? .fallback
    }

    func tag(for item: Item) -> CalendarTag { tag(item.calendarID) }

    func saveCalendar(_ tag: CalendarTag) {
        if let index = calendars.firstIndex(where: { $0.id == tag.id }) {
            calendars[index] = tag
        } else {
            calendars.append(tag)
        }
        persist()
        if canSync { CloudSync.shared.recordChanged(.calendar, id: tag.id) }
    }

    /// Deleting moves anything using it onto the first remaining calendar, so no
    /// event is left pointing at something that no longer exists.
    func deleteCalendar(id: String) {
        guard calendars.count > 1 else { return }
        calendars.removeAll { $0.id == id }
        let fallbackID = calendars[0].id
        items = items.map { item in
            guard item.calendarID == id else { return item }
            var moved = item
            moved.calendarID = fallbackID
            return moved
        }
        persist()
    }

    /// Actions still outstanding: today's, plus anything left unticked behind you.
    ///
    /// An action that was due last Tuesday and never ticked currently just
    /// vanishes off the end of the calendar. Carrying it forward is the whole
    /// point of a to-do — it should keep asking until it's done or deleted.
    func outstandingActions(asOf day: Date = .now, lookingBack days: Int = 60) -> [Item] {
        let today = day.startOfDay
        var result: [Item] = []

        for offset in (-days)...0 {
            let probe = today.adding(days: offset)
            result.append(contentsOf: actions(on: probe).filter { !$0.isDone })
        }
        return result.sorted { $0.day > $1.day }
    }

    func isOverdue(_ item: Item, asOf day: Date = .now) -> Bool {
        item.kind == .action && !item.isDone && item.day.startOfDay < day.startOfDay
    }

    // MARK: Countdowns

    /// Everything pinned as a countdown that hasn't happened yet, nearest first.
    func countdowns(from day: Date) -> [(item: Item, days: Int)] {
        let base = day.startOfDay

        return items
            .filter(\.countsDown)
            .compactMap { item -> (item: Item, days: Int)? in
                // A repeating item counts to its *next* occurrence. Counting to
                // the series start would leave a weekly countdown stuck in the
                // past a week after you set it.
                guard let next = nextDate(of: item, after: base) else { return nil }
                let days = DayCount.between(base, and: next)
                var occurrence = item
                if !next.isSameDay(as: item.day) {
                    occurrence.day = next
                    occurrence.seriesStart = item.day
                }
                return (occurrence, days)
            }
            .sorted { $0.days < $1.days }
    }

    /// Asks the same question the calendar asks — "does this item appear on this
    /// day?" — so adjustments and repeats are handled in one place rather than
    /// two that can disagree.
    private func nextDate(of item: Item, after day: Date) -> Date? {
        var probe = day.adding(days: 1)
        for _ in 0..<800 {
            if occurrence(of: item, on: probe) != nil { return probe.startOfDay }
            probe = probe.adding(days: 1)
        }
        return nil
    }

    func refreshCurrentLocation() async {
        guard useCurrentLocation else {
            currentName = ""
            currentLatitude = nil
            currentLongitude = nil
            return
        }
        guard let place = await LocationService.shared.currentPlace() else { return }
        currentLatitude = place.latitude
        currentLongitude = place.longitude
        currentName = place.name
    }

    private let bridge = CalendarBridge()
    private var isLoading = false
    private var suppressCalendarSideEffects = false
    /// True while incoming records are being written, so they aren't sent back.
    private var isApplyingRemote = false

    // MARK: Init

    init() {
        load()
    }

    // MARK: Reading

    /// Own items plus, when enabled, mirrored system events — sorted for display.
    func items(on day: Date) -> [Item] {
        let key = day.startOfDay
        let mine = items.compactMap { occurrence(of: $0, on: key) }
        let theirs = showSystemCalendars ? external.filter { $0.day.isSameDay(as: key) } : []
        return (mine + theirs).sorted(by: Item.daySort)
    }

    func allDayItems(on day: Date) -> [Item] {
        items(on: day).filter { $0.kind == .event && $0.isAllDay }
    }

    func timedItems(on day: Date) -> [Item] {
        items(on: day).filter { $0.kind == .event && !$0.isAllDay }
    }

    func actions(on day: Date) -> [Item] {
        items(on: day).filter { $0.kind == .action }
    }

    func birthdays(on day: Date) -> [Item] {
        items(on: day).filter { $0.kind == .birthday }
    }

    /// Birthdays coming up, nearest first. Used for the day view's list so you
    /// get a few days' warning rather than finding out on the morning.
    func upcomingBirthdays(from day: Date, within days: Int = 30) -> [(item: Item, days: Int)] {
        let base = day.startOfDay
        var result: [(Item, Int)] = []

        for offset in 1...days {
            let probe = base.adding(days: offset)
            for birthday in birthdays(on: probe) {
                result.append((birthday, offset))
            }
        }
        return result.sorted { $0.1 < $1.1 }
    }

    func count(on day: Date) -> Int { items(on: day).count }

    /// Whether banks and payroll would treat this as a working day: a weekday
    /// that isn't a bank holiday.
    ///
    /// Deliberately not the user's own working week. A pay date moves because
    /// the banking calendar says so, not because someone works Tuesdays.
    func isBankWorkingDay(_ day: Date) -> Bool {
        let weekday = Calendar.current.component(.weekday, from: day)
        guard weekday != 1, weekday != 7 else { return false }
        return !automaticMarks.contains { $0.covers(day) }
    }

    /// Walks off a weekend or bank holiday in the requested direction.
    func adjustedDay(_ nominal: Date, using rule: Recurrence.DateAdjustment) -> Date {
        guard rule.adjusts else { return nominal.startOfDay }

        var probe = nominal.startOfDay
        var steps = 0
        while !isBankWorkingDay(probe), steps < 10 {
            probe = probe.adding(days: rule == .earlier ? -1 : 1)
            steps += 1
        }
        return probe
    }

    /// Where a nominal date actually lands: a one-off move if there is one, the
    /// working-day adjustment otherwise.
    ///
    /// A move wins over the rule. If you've said this December's pay arrives on
    /// the 20th, no amount of weekend arithmetic should argue with you.
    func resolvedDay(for nominal: Date, of item: Item) -> Date {
        if let moved = item.movedOccurrences[nominal.dayKey] { return moved.startOfDay }
        return adjustedDay(nominal, using: item.recurrence.adjustment)
    }

    /// The item as it appears on this day: itself on its own day, a generated
    /// copy where a repeat lands, nothing otherwise.
    ///
    /// Once dates can move, this has to run backwards — "which nominal date,
    /// once resolved, would land here?" — because the day shown is no longer the
    /// day the rule produced. The search window only widens for items that
    /// actually have moves, so the common case stays cheap.
    private func occurrence(of item: Item, on day: Date) -> Item? {
        let shifts = item.recurrence.adjustment.adjusts || !item.movedOccurrences.isEmpty

        guard shifts else {
            guard !item.skippedOccurrences.contains(day.dayKey) else { return nil }
            if item.day.isSameDay(as: day) { return item }
            guard item.recurrence.falls(on: day, seriesStart: item.day) else { return nil }
            var copy = item
            copy.day = day.startOfDay
            copy.seriesStart = item.day
            copy.nominalDay = day.startOfDay
            return copy
        }

        let window = item.movedOccurrences.isEmpty ? 7 : 31

        for offset in -window...window {
            let nominal = day.adding(days: offset).startOfDay
            guard !item.skippedOccurrences.contains(nominal.dayKey) else { continue }
            let isNominal = item.day.isSameDay(as: nominal)
                || item.recurrence.falls(on: nominal, seriesStart: item.day)
            guard isNominal, resolvedDay(for: nominal, of: item).isSameDay(as: day) else { continue }

            var copy = item
            copy.day = day.startOfDay
            copy.nominalDay = nominal
            // Anything shown on a day other than its stored one needs the anchor,
            // or saving an edit would rewrite the series onto the shifted date.
            if !item.day.isSameDay(as: day) { copy.seriesStart = item.day }
            return copy
        }
        return nil
    }

    // MARK: Day marks    // MARK: Day marks    // MARK: Day marks

    /// Everything marking this day — fetched and hand-entered together, most
    /// specific first.
    ///
    /// Specificity is just length: an inset day inside a half term inside a
    /// longer break is one day, five days and thirty days. Sorting by marked
    /// length means the narrowest mark wins the line under the date, which is
    /// almost always the one you actually needed to know about.
    func marks(on day: Date) -> [DayMark] {
        (automaticMarks + derivedHolidays + dayMarks)
            .filter { $0.covers(day) }
            .sorted { lhs, rhs in
                if lhs.markedDayCount != rhs.markedDayCount {
                    return lhs.markedDayCount < rhs.markedDayCount
                }
                return lhs.title < rhs.title
            }
    }

    func isWorkday(_ day: Date) -> Bool {
        // A bank holiday is not a working day, whatever the weekday says.
        guard !marks(on: day).contains(where: { $0.kind == .bankHoliday }) else { return false }
        return workWeek.isWorkday(day)
    }

    func saveMark(_ mark: DayMark) {
        var normalised = mark
        // School-scoped kinds need an owner; bank holidays and personal ranges
        // don't belong to anyone's school.
        if normalised.schoolID == nil,
           [.schoolHoliday, .halfTerm, .insetDay].contains(normalised.kind) {
            normalised.schoolID = ensureSchool().id
        }
        normalised.start = min(mark.start, mark.end).startOfDay
        normalised.end = max(mark.start, mark.end).startOfDay
        if let index = dayMarks.firstIndex(where: { $0.id == mark.id }) {
            dayMarks[index] = normalised
        } else {
            dayMarks.append(normalised)
        }
        persist()
        if canSync { CloudSync.shared.recordChanged(.dayMark, id: normalised.id.uuidString) }
    }

    func deleteMark(id: UUID) {
        dayMarks.removeAll { $0.id == id }
        persist()
        if canSync { CloudSync.shared.recordDeleted(.dayMark, id: id.uuidString) }
    }

    // MARK: Timetables

    func timetable(for school: School) -> Timetable {
        timetables[school.id] ?? Timetable()
    }

    func saveTimetable(_ timetable: Timetable, for school: School) {
        timetables[school.id] = timetable
        persist()
        Task { await rescheduleKitReminders() }
    }

    /// Where the cycle counts from for this day.
    ///
    /// Continuous counts from the anchor week. Restarting each term counts from
    /// the term containing the day. Restarting after every break counts from the
    /// day school came back — found by walking backwards until three
    /// consecutive non-school days turn up, since a weekend is only two and
    /// shouldn't reset anything.
    func cycleReference(on day: Date, for school: School) -> Date {
        let table = timetable(for: school)

        switch table.reset {
        case .schoolWeeks, .continuous:
            return table.anchor

        case .eachTerm:
            let terms = terms(for: school).filter { $0.start.startOfDay <= day.startOfDay }
            return terms.max(by: { $0.start < $1.start })?.start ?? table.anchor

        case .eachBreak:
            var probe = day.startOfDay
            var lastSchoolDay = day.startOfDay
            var gap = 0

            for _ in 0..<220 {
                if isSchoolDay(probe, for: school) {
                    lastSchoolDay = probe
                    gap = 0
                } else {
                    gap += 1
                    if gap >= 3 { return lastSchoolDay }
                }
                probe = probe.adding(days: -1)
            }
            return table.anchor
        }
    }

    func week(on day: Date, for school: School) -> Int {
        let table = timetable(for: school)
        guard table.isCycled else { return 1 }

        guard table.reset == .schoolWeeks else {
            return table.week(for: day, countingFrom: cycleReference(on: day, for: school))
        }

        // Count only the weeks school was actually open. A week off doesn't
        // advance the cycle, so the pattern resumes where it left off rather
        // than jumping by however long the holiday was.
        let elapsed = schoolWeeks(from: table.anchor, to: day, for: school)
        return ((elapsed % table.cycleLength) + table.cycleLength) % table.cycleLength + 1
    }

    private func schoolWeeks(from: Date, to: Date, for school: School) -> Int {
        let start = min(from, to).startOfWeek
        let end = max(from, to).startOfWeek
        guard start != end else { return 0 }

        var count = 0
        var probe = start
        var guardRail = 0
        while probe < end, guardRail < 520 {
            if weekHasSchool(probe, for: school) { count += 1 }
            probe = probe.adding(days: 7)
            guardRail += 1
        }
        return to.startOfWeek >= from.startOfWeek ? count : -count
    }

    private func weekHasSchool(_ weekStart: Date, for school: School) -> Bool {
        (0..<5).contains { isSchoolDay(weekStart.adding(days: $0), for: school) }
    }

    /// Lessons on a day, per school. Nothing outside term — a timetable running
    /// through half term is worse than none.
    ///
    /// With no term dates entered there's nothing to be outside of, so weekdays
    /// count. Otherwise adding a timetable before the terms would silently show
    /// nothing at all.
    func lessons(on day: Date, for school: School) -> [Lesson] {
        let weekday = Calendar.current.component(.weekday, from: day)
        let hasTerms = !terms(for: school).isEmpty

        if hasTerms {
            guard isSchoolDay(day, for: school) else { return [] }
        } else {
            guard weekday != 1, weekday != 7 else { return [] }
        }

        let table = timetable(for: school)
        return table.lessons(on: day, week: table.isCycled ? week(on: day, for: school) : 0)
    }

    /// Every school with something on that day, in the order the schools were
    /// added, so two children always appear in the same order.
    func lessonsBySchool(on day: Date) -> [(school: School, week: Int, lessons: [Lesson])] {
        schools.compactMap { school in
            let lessons = lessons(on: day, for: school)
            guard !lessons.isEmpty else { return nil }
            return (school, week(on: day, for: school), lessons)
        }
    }

    /// Anything needing kit brought in tomorrow, for the evening reminder.
    func kitNeeded(on day: Date) -> [(school: School, lesson: Lesson)] {
        schools.flatMap { school in
            lessons(on: day, for: school)
                .filter { $0.needsKit && !$0.isBreak }
                .map { (school, $0) }
        }
    }

    // MARK: Schools

    var hasMultipleSchools: Bool { schools.count > 1 }

    /// Terms and marks saved before schools existed have no owner, so they fall
    /// to the first school rather than being stranded.
    func school(for id: UUID?) -> School? {
        guard let id else { return schools.first }
        return schools.first { $0.id == id } ?? schools.first
    }

    // Ownership is explicit — no "belongs to the first school if unset" rule.
    // That rule was fine for reading, but it meant deleting the first school
    // left ownerless terms behind to be adopted by the next one, which is the
    // silent merge the delete is meant to prevent. `adoptOrphans` settles
    // ownership once, on load, so these can match on id alone.

    func terms(for school: School) -> [SchoolTerm] {
        schoolTerms
            .filter { $0.schoolID == school.id }
            .sorted { $0.start < $1.start }
    }

    func marks(for school: School) -> [DayMark] {
        dayMarks
            .filter { $0.schoolID == school.id }
            .sorted { $0.start < $1.start }
    }

    /// Gives every school-scoped term and mark a definite owner. Runs once,
    /// after load, so nothing stays ambiguous long enough to be inherited.
    private func adoptOrphans() {
        guard let first = schools.first else { return }
        var changed = false

        schoolTerms = schoolTerms.map { term in
            guard term.schoolID == nil else { return term }
            changed = true
            var owned = term
            owned.schoolID = first.id
            return owned
        }

        dayMarks = dayMarks.map { mark in
            guard mark.schoolID == nil,
                  [.schoolHoliday, .halfTerm, .insetDay].contains(mark.kind)
            else { return mark }
            changed = true
            var owned = mark
            owned.schoolID = first.id
            return owned
        }

        guard changed else { return }
        rebuildDerivedHolidays()
        let wasLoading = isLoading
        isLoading = false
        persist()
        isLoading = wasLoading
    }

    @discardableResult
    func ensureSchool() -> School {
        if let first = schools.first { return first }
        let school = School(name: "School")
        schools.append(school)
        adoptOrphans()
        persist()
        return school
    }

    func saveSchool(_ school: School) {
        if let index = schools.firstIndex(where: { $0.id == school.id }) {
            schools[index] = school
        } else {
            schools.append(school)
        }
        rebuildDerivedHolidays()
        persist()
        if canSync { CloudSync.shared.recordChanged(.school, id: school.id.uuidString) }
    }

    /// Removing a school takes its terms and breaks with it — leaving them would
    /// silently fold one child's dates into another's.
    func deleteSchool(id: UUID) {
        schools.removeAll { $0.id == id }
        schoolTerms.removeAll { $0.schoolID == id }
        dayMarks.removeAll { $0.schoolID == id }
        rebuildDerivedHolidays()
        persist()
    }

    /// Prefixes a mark with whose it is, but only once that's ambiguous.
    func label(for mark: DayMark) -> String {
        guard hasMultipleSchools,
              let id = mark.schoolID,
              let owner = schools.first(where: { $0.id == id }),
              !owner.name.isEmpty
        else { return mark.title }
        return "\(owner.name) · \(mark.title)"
    }

    // MARK: School terms

    func saveTerm(_ term: SchoolTerm) {
        let owner = ensureSchool()
        var normalised = term
        if normalised.schoolID == nil { normalised.schoolID = owner.id }
        normalised.start = min(term.start, term.end).startOfDay
        normalised.end = max(term.start, term.end).startOfDay
        if let index = schoolTerms.firstIndex(where: { $0.id == term.id }) {
            schoolTerms[index] = normalised
        } else {
            schoolTerms.append(normalised)
        }
        rebuildDerivedHolidays()
        persist()
        if canSync { CloudSync.shared.recordChanged(.schoolTerm, id: normalised.id.uuidString) }
    }

    func deleteTerm(id: UUID) {
        schoolTerms.removeAll { $0.id == id }
        rebuildDerivedHolidays()
        persist()
        if canSync { CloudSync.shared.recordDeleted(.schoolTerm, id: id.uuidString) }
    }

    /// Every gap between two consecutive terms becomes a holiday. Nothing outside
    /// the first and last term is assumed either way — the app simply doesn't
    /// know yet, and guessing would be worse than saying nothing.
    func rebuildDerivedHolidays() {
        guard !schoolTerms.isEmpty else {
            derivedHolidays = []
            return
        }
        if schools.isEmpty { schools = [School(name: "School")] }

        // Grouped by school before anything is derived. Sorting every term
        // together and taking the gaps between neighbours produces overlapping
        // nonsense the moment two children are at schools with different dates.
        var result: [DayMark] = []
        for school in schools {
            result.append(contentsOf: derived(for: school))
        }
        derivedHolidays = result
    }

    private func derived(for school: School) -> [DayMark] {
        let sorted = terms(for: school)
        guard !sorted.isEmpty else { return [] }

        var result: [DayMark] = []

        for (index, term) in sorted.enumerated() where index + 1 < sorted.count {
            let next = sorted[index + 1]
            let gapStart = term.end.adding(days: 1)
            let gapEnd = next.start.adding(days: -1)
            guard gapStart <= gapEnd else { continue }

            result.append(
                DayMark(
                    title: SchoolTerm.holidayName(startingIn: gapStart),
                    kind: .schoolHoliday,
                    start: gapStart,
                    end: gapEnd,
                    weekdaysOnly: true,
                    schoolID: school.id,
                    isAutomatic: true
                )
            )
        }

        // A single-day flag on the first and last day of each term. These are
        // school days, not breaks, so they never affect a countdown.
        for term in sorted {
            result.append(
                DayMark(
                    title: "\(term.name) starts",
                    kind: .termBoundary,
                    start: term.start,
                    end: term.start,
                    weekdaysOnly: false,
                    schoolID: school.id,
                    isAutomatic: true
                )
            )
            guard !term.end.isSameDay(as: term.start) else { continue }
            result.append(
                DayMark(
                    title: "\(term.name) ends",
                    kind: .termBoundary,
                    start: term.end,
                    end: term.end,
                    weekdaysOnly: false,
                    schoolID: school.id,
                    isAutomatic: true
                )
            )
        }

        // Coming back after a half term. A break between terms is already
        // bracketed by "term ends" and "term starts", but a half term sits
        // inside one, so nothing marked the day school picked up again.
        //
        // Inset days are deliberately excluded. A single day out doesn't
        // interrupt a term, and flagging the morning after every one of them
        // would turn a useful signal into wallpaper.
        let ownMarks = marks(for: school)
        let gaps = result.filter { $0.kind == .schoolHoliday }

        func teaches(on day: Date) -> Bool {
            let weekday = Calendar.current.component(.weekday, from: day)
            guard weekday != 1, weekday != 7 else { return false }
            guard sorted.contains(where: { $0.contains(day) }) else { return false }
            if ownMarks.contains(where: { $0.covers(day) }) { return false }
            if gaps.contains(where: { $0.covers(day) }) { return false }
            return !automaticMarks.contains { $0.covers(day) }
        }

        for half in ownMarks where half.kind == .halfTerm {
            var probe = half.end.adding(days: 1)
            var steps = 0
            while !teaches(on: probe), steps < 21 {
                probe = probe.adding(days: 1)
                steps += 1
            }
            guard steps < 21,
                  let term = sorted.first(where: { $0.contains(probe) }),
                  !result.contains(where: { $0.kind == .termBoundary && $0.start.isSameDay(as: probe) })
            else { continue }

            result.append(
                DayMark(
                    title: "\(term.name) resumes",
                    kind: .termBoundary,
                    start: probe,
                    end: probe,
                    weekdaysOnly: false,
                    schoolID: school.id,
                    isAutomatic: true
                )
            )
        }

        return result
    }

    func refreshHolidays() async {
        automaticMarks = await HolidayService.shared.bankHolidays(for: holidayRegion)
    }

    func item(id: UUID) -> Item? {
        items.first { $0.id == id } ?? external.first { $0.id == id }
    }

    /// The next thing starting after this one finishes, used for "free afterwards".
    func nextItem(after item: Item) -> Item? {
        timedItems(on: item.day)
            .filter { $0.id != item.id && $0.start >= item.effectiveEnd }
            .min { $0.start < $1.start }
    }

    // MARK: Writing

    func save(_ item: Item) {
        guard !item.isExternal else { return }

        // An occurrence carries the day you were looking at, not the day the
        // series starts. Saving it as-is would drag the whole repeat forward to
        // whichever Tuesday you happened to open.
        var item = item
        if let start = item.seriesStart {
            item.day = start
            item.seriesStart = nil
        }

        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        persist()
        if canSync { CloudSync.shared.recordChanged(.item, id: item.id.uuidString) }
        Task { await rescheduleNotifications(for: item) }
    }

    // MARK: Sync

    /// Everything that should exist in CloudKit, by type and id.
    func syncableIDs() -> [(type: SyncType, id: String)] {
        items.map { (.item, $0.id.uuidString) }
            + dayMarks.map { (.dayMark, $0.id.uuidString) }
            + schoolTerms.map { (.schoolTerm, $0.id.uuidString) }
            + schools.map { (.school, $0.id.uuidString) }
            + calendars.map { (.calendar, $0.id) }
    }

    /// The JSON that goes in the record's single payload field.
    func payload(for type: SyncType, id: String) -> Data? {
        let encoder = JSONEncoder()
        switch type {
        case .item:       return items.first { $0.id.uuidString == id }.flatMap { try? encoder.encode($0) }
        case .dayMark:    return dayMarks.first { $0.id.uuidString == id }.flatMap { try? encoder.encode($0) }
        case .schoolTerm: return schoolTerms.first { $0.id.uuidString == id }.flatMap { try? encoder.encode($0) }
        case .school:     return schools.first { $0.id.uuidString == id }.flatMap { try? encoder.encode($0) }
        case .calendar:   return calendars.first { $0.id == id }.flatMap { try? encoder.encode($0) }
        }
    }

    /// Applies a record that arrived from someone else's device.
    ///
    /// Last writer wins, per record. For a household calendar that's the right
    /// trade: the alternative is merge dialogs for the case where two people
    /// edited the same event in the same few seconds, which is rare and not
    /// worth the interface it would cost. Because records are per-event, editing
    /// *different* events at the same time never conflicts at all.
    func applyRemote(type: SyncType, id: String, payload: Data) {
        let decoder = JSONDecoder()
        switch type {
        case .item:
            guard let value = try? decoder.decode(Item.self, from: payload) else { return }
            if let index = items.firstIndex(where: { $0.id == value.id }) { items[index] = value }
            else { items.append(value) }

        case .dayMark:
            guard let value = try? decoder.decode(DayMark.self, from: payload) else { return }
            if let index = dayMarks.firstIndex(where: { $0.id == value.id }) { dayMarks[index] = value }
            else { dayMarks.append(value) }

        case .schoolTerm:
            guard let value = try? decoder.decode(SchoolTerm.self, from: payload) else { return }
            if let index = schoolTerms.firstIndex(where: { $0.id == value.id }) { schoolTerms[index] = value }
            else { schoolTerms.append(value) }
            rebuildDerivedHolidays()

        case .school:
            guard let value = try? decoder.decode(School.self, from: payload) else { return }
            if let index = schools.firstIndex(where: { $0.id == value.id }) { schools[index] = value }
            else { schools.append(value) }
            rebuildDerivedHolidays()

        case .calendar:
            guard let value = try? decoder.decode(CalendarTag.self, from: payload) else { return }
            if let index = calendars.firstIndex(where: { $0.id == value.id }) { calendars[index] = value }
            else { calendars.append(value) }
        }
        persistWithoutSyncing()
    }

    func applyRemoteDelete(type: SyncType, id: String) {
        switch type {
        case .item:       items.removeAll { $0.id.uuidString == id }
        case .dayMark:    dayMarks.removeAll { $0.id.uuidString == id }
        case .schoolTerm: schoolTerms.removeAll { $0.id.uuidString == id }; rebuildDerivedHolidays()
        case .school:     schools.removeAll { $0.id.uuidString == id }; rebuildDerivedHolidays()
        case .calendar:   if calendars.count > 1 { calendars.removeAll { $0.id == id } }
        }
        persistWithoutSyncing()
    }

    /// Saves to disk without echoing the change straight back to CloudKit.
    private func persistWithoutSyncing() {
        isApplyingRemote = true
        persist()
        isApplyingRemote = false
    }

    // MARK: Notifications

    /// The next few dates this item actually falls on, respecting repeats,
    /// skips, moves and working-day adjustments.
    func upcomingDates(of item: Item, limit: Int = 12, within days: Int = 200) -> [Date] {
        var found: [Date] = []
        var probe = Date.now.startOfDay

        for _ in 0...days {
            if occurrence(of: item, on: probe) != nil {
                found.append(probe)
                if found.count >= limit { break }
            }
            probe = probe.adding(days: 1)
        }
        return found
    }

    func rescheduleNotifications(for item: Item) async {
        let dates = upcomingDates(of: item)
        await NotificationService.shared.reschedule(for: item, on: dates)
    }

    /// Repeats can't be scheduled once and forgotten — iOS caps pending
    /// notifications at 64, so only a window of them exists at any time. Running
    /// this at launch keeps that window rolling forward.
    /// One reminder the evening before, per school, listing what's needed.
    ///
    /// Grouped rather than one alert per lesson: "PE and swimming tomorrow" is
    /// one thing to act on, and two notifications for the same bag is noise.
    func rescheduleKitReminders() async {
        await NotificationService.shared.cancelKitReminders()
        guard !schools.isEmpty else { return }

        for offset in 0..<21 {
            let day = Date.now.startOfDay.adding(days: offset + 1)
            let needed = kitNeeded(on: day)
            guard !needed.isEmpty else { continue }

            for school in schools {
                let mine = needed.filter { $0.school.id == school.id }
                guard !mine.isEmpty else { continue }
                await NotificationService.shared.scheduleKitReminder(
                    school: hasMultipleSchools ? school.name : "",
                    lessons: mine.map(\.lesson),
                    forDay: day
                )
            }
        }
    }

    func rescheduleAllNotifications() async {
        for item in items where !item.alerts.isEmpty || item.travel != .none {
            await rescheduleNotifications(for: item)
        }
        await rescheduleKitReminders()
    }

    /// Lifts one occurrence out of a series without touching the rest.
    func skipOccurrence(of item: Item) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        let key = item.nominalKey
        items[index].skippedOccurrences.insert(key)
        // A skipped date can't also be a moved one.
        items[index].movedOccurrences.removeValue(forKey: key)
        persist()
    }

    /// Puts a skipped or moved date back into the series.
    func restoreOccurrence(of id: UUID, key: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].skippedOccurrences.remove(key)
        items[index].movedOccurrences.removeValue(forKey: key)
        persist()
    }

    func delete(id: UUID) {
        items.removeAll { $0.id == id }
        persist()
        if canSync { CloudSync.shared.recordDeleted(.item, id: id.uuidString) }
        NotificationService.shared.cancel(id: id)
    }

    func toggleDone(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone.toggle()
        persist()
    }

    // MARK: System calendars

    func refreshExternal() async {
        guard showSystemCalendars else {
            external = []
            return
        }
        let granted = await bridge.requestAccess()
        guard granted else {
            // Access refused — turn the toggle back off without re-entering this method.
            external = []
            suppressCalendarSideEffects = true
            showSystemCalendars = false
            suppressCalendarSideEffects = false
            persist()
            return
        }
        external = bridge.load(from: .now.adding(days: -30), to: .now.adding(days: 120), tags: calendars)
    }

    // MARK: Persistence

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("almanac.json")
    }

    private struct Snapshot: Codable {
        /// Bumped when saved data needs repairing rather than just extending.
        var schemaVersion: Int = 2
        var items: [Item] = []
        var dayMarks: [DayMark] = []
        var schoolTerms: [SchoolTerm] = []
        var schools: [School] = []
        var calendars: [CalendarTag] = CalendarTag.defaults
        var timetables: [UUID: Timetable] = [:]
        var themeName: String = "Deep Teal"
        var homeName: String = ""
        var homeLatitude: Double?
        var homeLongitude: Double?
        var useCurrentLocation: Bool = false
        var showSystemCalendars: Bool = false
        var workWeek = WorkWeek()
        var holidayRegion: HolidayRegion = .englandAndWales
        var showAlmanacLines: Bool = true
        var countInSchoolDays: Bool = false
        var syncEnabled: Bool = false
        var userName: String = ""
        var birthday: Date?

        init() {}

        /// Decoded key by key so a save written by an earlier build still loads.
        /// A missing field takes its default instead of throwing away the file.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
            items = try c.decodeIfPresent([Item].self, forKey: .items) ?? []
            dayMarks = try c.decodeIfPresent([DayMark].self, forKey: .dayMarks) ?? []
            schoolTerms = try c.decodeIfPresent([SchoolTerm].self, forKey: .schoolTerms) ?? []
            schools = try c.decodeIfPresent([School].self, forKey: .schools) ?? []
            calendars = try c.decodeIfPresent([CalendarTag].self, forKey: .calendars) ?? CalendarTag.defaults
            timetables = try c.decodeIfPresent([UUID: Timetable].self, forKey: .timetables) ?? [:]
            themeName = try c.decodeIfPresent(String.self, forKey: .themeName) ?? "Deep Teal"
            homeName = try c.decodeIfPresent(String.self, forKey: .homeName) ?? ""
            homeLatitude = try c.decodeIfPresent(Double.self, forKey: .homeLatitude)
            homeLongitude = try c.decodeIfPresent(Double.self, forKey: .homeLongitude)
            useCurrentLocation = try c.decodeIfPresent(Bool.self, forKey: .useCurrentLocation) ?? false
            showSystemCalendars = try c.decodeIfPresent(Bool.self, forKey: .showSystemCalendars) ?? false
            workWeek = try c.decodeIfPresent(WorkWeek.self, forKey: .workWeek) ?? WorkWeek()
            holidayRegion = try c.decodeIfPresent(HolidayRegion.self, forKey: .holidayRegion) ?? .englandAndWales
            showAlmanacLines = try c.decodeIfPresent(Bool.self, forKey: .showAlmanacLines) ?? true
            countInSchoolDays = try c.decodeIfPresent(Bool.self, forKey: .countInSchoolDays) ?? false
            syncEnabled = try c.decodeIfPresent(Bool.self, forKey: .syncEnabled) ?? false
            userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? ""
            birthday = try c.decodeIfPresent(Date.self, forKey: .birthday)
        }

        init(_ store: Store) {
            schemaVersion = 2
            items = store.items
            dayMarks = store.dayMarks
            schoolTerms = store.schoolTerms
            schools = store.schools
            calendars = store.calendars
            timetables = store.timetables
            themeName = store.themeName
            homeName = store.homeName
            homeLatitude = store.homeLatitude
            homeLongitude = store.homeLongitude
            useCurrentLocation = store.useCurrentLocation
            showSystemCalendars = store.showSystemCalendars
            workWeek = store.workWeek
            holidayRegion = store.holidayRegion
            showAlmanacLines = store.showAlmanacLines
            countInSchoolDays = store.countInSchoolDays
            syncEnabled = store.syncEnabled
            userName = store.userName
            birthday = store.birthday
        }
    }

    private func persist() {
        guard !isLoading else { return }
        // Encode here, on the actor that owns the state. Only the file write
        // goes off-thread — Data is Sendable, Snapshot is not.
        let snapshot = Snapshot(self)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let url = fileURL
        Task.detached(priority: .background) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private func load() {
        isLoading = true
        defer { isLoading = false }
        guard
            let data = try? Data(contentsOf: fileURL),
            let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }
        items = snapshot.items
        dayMarks = snapshot.dayMarks
        schoolTerms = snapshot.schoolTerms
        schools = snapshot.schools
        calendars = snapshot.calendars.isEmpty ? CalendarTag.defaults : snapshot.calendars
        timetables = snapshot.timetables
        rebuildDerivedHolidays()
        themeName = snapshot.themeName
        homeName = snapshot.homeName
        homeLatitude = snapshot.homeLatitude
        homeLongitude = snapshot.homeLongitude
        useCurrentLocation = snapshot.useCurrentLocation
        showSystemCalendars = snapshot.showSystemCalendars
        workWeek = snapshot.workWeek
        holidayRegion = snapshot.holidayRegion
        showAlmanacLines = snapshot.showAlmanacLines
        countInSchoolDays = snapshot.countInSchoolDays
        syncEnabled = snapshot.syncEnabled
        userName = snapshot.userName
        birthday = snapshot.birthday

        if snapshot.schemaVersion < 2 { migrateToVersion2() }
        adoptOrphans()
    }

    /// Version 1 had a "term time" kind and let hand-entered ranges cover
    /// weekends. Both were wrong: a weekend is already a weekend, and marking
    /// every weekday as term time marks nothing. Old ranges decode as "Other",
    /// and this pins them to weekdays so they stop painting Saturdays.
    private func migrateToVersion2() {
        dayMarks = dayMarks.map { mark in
            guard mark.kind != .bankHoliday else { return mark }
            var repaired = mark
            repaired.weekdaysOnly = true
            return repaired
        }
        isLoading = false
        persist()
        isLoading = true
    }

}
