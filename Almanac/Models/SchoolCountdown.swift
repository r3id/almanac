import Foundation

/// "9 school days until half term."
///
/// Note that nothing here needs a "term time" range to exist. A term is just the
/// gap between two breaks, so the edges of the school holiday marks already
/// describe every boundary worth counting to. Adding term ranges would have meant
/// entering the same information twice and keeping the two in agreement.
nonisolated struct SchoolCountdown: Identifiable, Hashable {
    var id: UUID = UUID()
    /// Set only when there's more than one school to tell apart.
    var schoolName: String?
    var text: String
    /// True when the day itself falls in a break, which flips the phrasing from
    /// counting down to counting back.
    var isBreak: Bool
    /// True on the days either side of a change — the last school day, the night
    /// before, the day before term. The timeline shows only these, plus today,
    /// because printing "9 school days until half term" on nine rows in a row
    /// says it eight times too many.
    var isTransition: Bool = false
}

extension Store {

    /// Kinds that take a child out of school.
    private var schoolBreakKinds: Set<DayMarkKind> {
        [.schoolHoliday, .halfTerm, .insetDay]
    }

    /// Derived holidays count as breaks too, which is what lets "end of term"
    /// work without anyone entering a holiday by hand.
    private func schoolBreaks(for school: School) -> [DayMark] {
        (derivedHolidays + dayMarks).filter {
            schoolBreakKinds.contains($0.kind) && $0.schoolID == school.id
        }
    }

    /// One line per school. Almost always a single entry.
    func schoolCountdowns(on day: Date) -> [SchoolCountdown] {
        schools.compactMap { school in
            guard var countdown = schoolCountdown(on: day, for: school) else { return nil }
            countdown.schoolName = hasMultipleSchools ? school.name : nil
            return countdown
        }
    }

    /// A weekday inside a term that isn't a break or a bank holiday.
    ///
    /// No terms means no school days at all — not a school year in which every
    /// weekday counts. Plenty of people have no school run, and the whole feature
    /// should stay switched off for them rather than quietly asserting that
    /// today is term time.
    func isSchoolDay(_ day: Date, for school: School) -> Bool {
        let terms = terms(for: school)
        guard !terms.isEmpty else { return false }

        let weekday = Calendar.current.component(.weekday, from: day)
        guard weekday != 1, weekday != 7 else { return false }
        guard terms.contains(where: { $0.contains(day) }) else { return false }

        let breaks = schoolBreaks(for: school)
        if breaks.contains(where: { $0.covers(day) }) { return false }
        return !marks(on: day).contains { $0.kind == .bankHoliday }
    }

    /// True when it's a school day for anyone in the house — used by the working
    /// week shading, which doesn't care whose school it is.
    func isSchoolDay(_ day: Date) -> Bool {
        schools.contains { isSchoolDay(day, for: $0) }
    }

    /// Nil unless terms have been entered, so this stays completely invisible for
    /// anyone who doesn't have a school run.
    private func schoolCountdown(on day: Date, for school: School) -> SchoolCountdown? {
        let schoolTerms = terms(for: school)
        guard !schoolTerms.isEmpty else { return nil }
        let breaks = schoolBreaks(for: school)

        // Past every term we know about there's nothing honest to count, since
        // the next school year hasn't been entered yet.
        if let last = schoolTerms.map(\.end).max(), day.startOfDay > last.startOfDay {
            return nil
        }

        // Before a term starts — the summer before the year begins, or any gap
        // where no break has been entered — count to the term itself.
        if !schoolTerms.contains(where: { $0.contains(day) }),
           !breaks.contains(where: { $0.covers(day) }) {
            return countdownToTermStart(from: day, terms: schoolTerms)
        }

        if breaks.contains(where: { $0.covers(day) }) {
            return countdownBackToSchool(from: day, school: school)
        }

        // Anything left is inside a term — including Saturdays, Sundays and bank
        // holidays. Those aren't school days, but "9 school days until half term"
        // is exactly what you want to see on a Sunday night.
        return countdownToNextBreak(from: day, school: school, breaks: breaks)
    }

    /// Counts to the first day of the next term. Used when the day sits outside
    /// every term and outside every break — typically the run-up to a new school
    /// year, where there's a start date but nothing marking the days before it.
    private func countdownToTermStart(from day: Date, terms: [SchoolTerm]) -> SchoolCountdown? {
        guard let next = terms
            .filter({ $0.start.startOfDay > day.startOfDay })
            .min(by: { $0.start < $1.start })
        else { return nil }

        let days = DayCount.between(day, and: next.start)
        guard days > 0 else { return nil }
        let text = days == 1
            ? "\(next.name) starts tomorrow"
            : "\(next.name) starts in \(days) days"
        return SchoolCountdown(text: text, isBreak: true, isTransition: days <= 2)
    }

    private func countdownBackToSchool(from day: Date, school: School) -> SchoolCountdown? {
        var probe = day.adding(days: 1)
        var steps = 0
        while !isSchoolDay(probe, for: school), steps < 120 {
            probe = probe.adding(days: 1)
            steps += 1
        }
        guard steps < 120 else { return nil }

        let days = DayCount.between(day, and: probe)
        guard days > 0 else { return nil }
        let text = days == 1 ? "Back to school tomorrow" : "Back to school in \(days) days"
        return SchoolCountdown(text: text, isBreak: true, isTransition: days <= 2)
    }

    private func countdownToNextBreak(
        from day: Date, school: School, breaks: [DayMark]
    ) -> SchoolCountdown? {
        var best: (mark: DayMark, firstDay: Date)?

        for mark in breaks {
            guard let firstDay = firstCoveredDay(of: mark, after: day) else { continue }
            if best == nil || firstDay < best!.firstDay {
                best = (mark, firstDay)
            }
        }
        guard let best else { return nil }

        // School days strictly between today and the break starting.
        var remaining = 0
        var probe = day.adding(days: 1)
        while probe < best.firstDay {
            if isSchoolDay(probe, for: school) { remaining += 1 }
            probe = probe.adding(days: 1)
        }

        let calendarDays = DayCount.between(day, and: best.firstDay)

        let name = best.mark.title.isEmpty
            ? best.mark.kind.label.lowercased()
            : best.mark.title

        // The Friday before half term is worth calling out however you count —
        // it's the last day of school either way.
        let text: String
        if remaining == 0, isSchoolDay(day, for: school) {
            text = "Last school day before \(name)"
        } else if countInSchoolDays {
            text = remaining == 1
                ? "1 school day until \(name)"
                : "\(remaining) school days until \(name)"
        } else {
            guard calendarDays > 0 else { return nil }
            text = calendarDays == 1
                ? "\(name) starts tomorrow"
                : "\(calendarDays) days until \(name)"
        }
        // Worth showing in the timeline as well as on today: the last day
        // before a break, and the couple of days running up to it.
        let isTransition = (remaining == 0 && isSchoolDay(day, for: school)) || calendarDays <= 2
        return SchoolCountdown(text: text, isBreak: false, isTransition: isTransition)
    }

    private func firstCoveredDay(of mark: DayMark, after day: Date) -> Date? {
        let span = (Calendar.current.dateComponents(
            [.day], from: mark.start.startOfDay, to: mark.end.startOfDay
        ).day ?? 0) + 1
        guard span > 0 else { return nil }

        for offset in 0..<span {
            let candidate = mark.start.adding(days: offset)
            if candidate > day.startOfDay, mark.covers(candidate) { return candidate }
        }
        return nil
    }
}
