import Foundation

nonisolated struct DayFact: Hashable {
    var text: String
    var symbol: String
    /// Today is the thing itself, not a countdown to it.
    var isCelebration: Bool = false
}

/// The small line of context on the Today screen.
///
/// Some of it is arithmetic anyone could do and nobody bothers to — how much of
/// the year is left, when the clocks go back. The rest needs a name and a
/// birthday, which is why those live in settings: the app can work out the
/// solstice on its own, but it can't guess when you were born.
extension Store {

    func fact(on day: Date) -> DayFact? {
        let today = day.startOfDay

        // The day itself always wins over any countdown to something else.
        if let birthday, sameDayAndMonth(birthday, today) {
            return DayFact(
                text: birthdayGreeting(for: birthday, on: today),
                symbol: "birthday.cake",
                isCelebration: true
            )
        }
        if isChristmas(today) {
            return DayFact(text: "Happy Christmas.", symbol: "gift", isCelebration: true)
        }
        if isNewYear(today) {
            let year = Calendar.current.component(.year, from: today)
            return DayFact(text: "Happy new year — welcome to \(year).", symbol: "sparkles", isCelebration: true)
        }

        let candidates = facts(from: today)

        // Anything within a week is more interesting than a general fact.
        if let imminent = candidates
            .filter({ $0.days <= 7 })
            .min(by: { $0.days < $1.days }) {
            return imminent.fact
        }

        // Otherwise rotate, so the same line isn't there every morning.
        guard !candidates.isEmpty else { return nil }
        let index = Calendar.current.ordinality(of: .day, in: .year, for: today) ?? 0
        return candidates[index % candidates.count].fact
    }

    // MARK: Candidates

    private func facts(from today: Date) -> [(days: Int, fact: DayFact)] {
        var result: [(Int, DayFact)] = []

        func add(_ target: Date?, _ symbol: String, _ phrase: (Int) -> String) {
            guard let target else { return }
            let days = DayCount.between(today, and: target)
            guard days > 0 else { return }
            result.append((days, DayFact(text: phrase(days), symbol: symbol)))
        }

        add(nextChristmas(after: today), "gift") { DayCount.until($0, "Christmas") + "." }
        add(birthday.flatMap { nextAnniversary(of: $0, after: today) }, "birthday.cake") { days in
            DayCount.until(days, "your birthday") + "."
        }
        add(nextClockChange(after: today).date, "clock.arrow.circlepath") { [self] days in
            let forward = nextClockChange(after: today).forward
            return DayCount.until(days, forward ? "the clocks going forward" : "the clocks going back") + "."
        }
        add(nextSeasonMarker(after: today).date, "sun.max") { [self] days in
            DayCount.until(days, nextSeasonMarker(after: today).name) + "."
        }
        add(nextBankHoliday(after: today)?.start, "flag") { [self] days in
            let name = nextBankHoliday(after: today)?.title ?? "the next bank holiday"
            return DayCount.until(days, name) + "."
        }

        // Always available, and quietly the most sobering of the lot.
        let left = DayCount.between(today, and: endOfYear(for: today))
        if left > 0 {
            let year = Calendar.current.component(.year, from: today)
            result.append((left, DayFact(text: "\(left) days left of \(year).", symbol: "calendar")))
        }

        return result.map { (days: $0.0, fact: $0.1) }
    }

    // MARK: Dates worth knowing

    private func sameDayAndMonth(_ a: Date, _ b: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.component(.day, from: a) == calendar.component(.day, from: b)
            && calendar.component(.month, from: a) == calendar.component(.month, from: b)
    }

    private func birthdayGreeting(for birthday: Date, on today: Date) -> String {
        let calendar = Calendar.current
        let born = calendar.component(.year, from: birthday)
        let age = calendar.component(.year, from: today) - born
        let name = userName.isEmpty ? "" : ", \(userName)"

        // A birthday date entered with this year's year isn't a birth year, so
        // don't announce an age of nought.
        guard age > 0 else { return "Happy birthday\(name)." }
        return "Happy birthday\(name) — \(age) today."
    }

    private func isChristmas(_ day: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.component(.month, from: day) == 12
            && calendar.component(.day, from: day) == 25
    }

    private func isNewYear(_ day: Date) -> Bool {
        let calendar = Calendar.current
        return calendar.component(.month, from: day) == 1
            && calendar.component(.day, from: day) == 1
    }

    private func nextChristmas(after day: Date) -> Date? {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: day)
        let thisYear = calendar.date(from: DateComponents(year: year, month: 12, day: 25))
        if let thisYear, thisYear.startOfDay > day.startOfDay { return thisYear }
        return calendar.date(from: DateComponents(year: year + 1, month: 12, day: 25))
    }

    private func nextAnniversary(of date: Date, after day: Date) -> Date? {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: day)
        let month = calendar.component(.month, from: date)
        let dayOfMonth = calendar.component(.day, from: date)

        let thisYear = calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))
        if let thisYear, thisYear.startOfDay > day.startOfDay { return thisYear }
        return calendar.date(from: DateComponents(year: year + 1, month: month, day: dayOfMonth))
    }

    private func endOfYear(for day: Date) -> Date {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: day)
        return calendar.date(from: DateComponents(year: year, month: 12, day: 31)) ?? day
    }

    /// British Summer Time: forward on the last Sunday in March, back on the
    /// last Sunday in October.
    private func nextClockChange(after day: Date) -> (date: Date?, forward: Bool) {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: day)

        let march = lastSunday(month: 3, year: year)
        let october = lastSunday(month: 10, year: year)

        if let march, march.startOfDay > day.startOfDay { return (march, true) }
        if let october, october.startOfDay > day.startOfDay { return (october, false) }
        return (lastSunday(month: 3, year: year + 1), true)
    }

    private func lastSunday(month: Int, year: Int) -> Date? {
        let calendar = Calendar.current
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let length = calendar.range(of: .day, in: .month, for: first)?.count
        else { return nil }

        for offset in stride(from: length, through: 1, by: -1) {
            if let candidate = calendar.date(from: DateComponents(year: year, month: month, day: offset)),
               calendar.component(.weekday, from: candidate) == 1 {
                return candidate
            }
        }
        return nil
    }

    /// Solstices and equinoxes, to the day. They wander by one either way, which
    /// is close enough for a line of small print.
    private func nextSeasonMarker(after day: Date) -> (date: Date?, name: String) {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: day)
        let markers: [(month: Int, day: Int, name: String)] = [
            (3, 20, "the spring equinox"),
            (6, 21, "the longest day"),
            (9, 22, "the autumn equinox"),
            (12, 21, "the shortest day")
        ]

        for marker in markers {
            if let date = calendar.date(from: DateComponents(year: year, month: marker.month, day: marker.day)),
               date.startOfDay > day.startOfDay {
                return (date, marker.name)
            }
        }
        return (calendar.date(from: DateComponents(year: year + 1, month: 3, day: 20)), "the spring equinox")
    }

    private func nextBankHoliday(after day: Date) -> DayMark? {
        automaticMarks
            .filter { $0.start.startOfDay > day.startOfDay }
            .min { $0.start < $1.start }
    }
}
