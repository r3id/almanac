import Foundation

/// A stretch of time off, and what it costs to get it.
nonisolated struct LeaveSuggestion: Identifiable, Hashable {
    /// The working days you'd actually book.
    var bookDates: [Date]
    /// The whole unbroken run away from work, weekends and holidays included.
    var breakStart: Date
    var breakEnd: Date
    /// What the break is built around, when there's a public holiday in it.
    var anchor: String?

    var id: String { "\(breakStart.dayKey)-\(breakEnd.dayKey)" }
    var cost: Int { bookDates.count }
    var length: Int {
        (Calendar.current.dateComponents([.day], from: breakStart, to: breakEnd).day ?? 0) + 1
    }
    /// Days off per day booked. The whole point of the exercise.
    var efficiency: Double { cost == 0 ? 0 : Double(length) / Double(cost) }

    var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return "\(formatter.string(from: breakStart)) – \(formatter.string(from: breakEnd))"
    }

    var bookLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM"
        guard let first = bookDates.first, let last = bookDates.last else { return "" }
        return cost == 1
            ? "Book \(formatter.string(from: first))"
            : "Book \(cost) days, \(formatter.string(from: first))–\(formatter.string(from: last))"
    }
}

nonisolated struct LeavePlan {
    var suggestions: [LeaveSuggestion] = []
    var allowance: Int = 0

    var leaveUsed: Int { suggestions.reduce(0) { $0 + $1.cost } }
    var totalDaysOff: Int { suggestions.reduce(0) { $0 + $1.length } }
    var leaveLeft: Int { max(allowance - leaveUsed, 0) }

    var headline: String {
        guard leaveUsed > 0 else { return "No useful stretches found in this window." }
        return "Turn \(leaveUsed) days of leave into \(totalDaysOff) days away from work."
    }
}

extension Store {

    /// Finds the cheapest ways to buy the longest breaks.
    ///
    /// The trick everyone knows by instinct — book the Tuesday to Friday after a
    /// bank holiday Monday — is just an efficiency ratio: days off divided by
    /// days booked. This enumerates every run that begins and ends on a day you
    /// already have off, scores it that way, and takes the best ones that don't
    /// overlap until the allowance runs out.
    func planLeave(
        allowance: Int,
        from start: Date,
        to end: Date,
        minimumBreak: Int = 4
    ) -> LeavePlan {
        guard allowance > 0 else { return LeavePlan(allowance: allowance) }

        let calendar = Calendar.current
        let first = max(start, .now).startOfDay
        let last = end.startOfDay
        guard first < last else { return LeavePlan(allowance: allowance) }

        // Search past the end date. A Christmas break booked in December runs
        // into January, and stopping dead on the 31st would either hide it or
        // report it clipped in half.
        let horizon = last.adding(days: 21)
        let span = (calendar.dateComponents([.day], from: first, to: horizon).day ?? 0) + 1
        guard span > 1, span < 1000 else { return LeavePlan(allowance: allowance) }

        let days = (0..<span).map { first.adding(days: $0) }

        // A day is already yours if you don't work it or the country is shut.
        var holidayName: [Int: String] = [:]
        for (index, day) in days.enumerated() {
            if let holiday = marks(on: day).first(where: { $0.kind == .bankHoliday }) {
                holidayName[index] = holiday.title
            }
        }
        let isFree = days.enumerated().map { index, day in
            !workWeek.isWorkday(day) || holidayName[index] != nil
        }

        // Running total of working days, so a run's cost is one subtraction.
        var workingBefore = [Int](repeating: 0, count: span + 1)
        for index in 0..<span {
            workingBefore[index + 1] = workingBefore[index] + (isFree[index] ? 0 : 1)
        }

        // Only runs bounded by days you already have off are worth scoring, and
        // requiring both neighbours to be working days makes each one maximal —
        // otherwise the same break appears at a dozen near-identical lengths.
        var startingAt = [[LeaveSuggestion]](repeating: [], count: span)
        let maxCost = min(allowance, 12)

        for startIndex in 0..<span where isFree[startIndex] {
            guard startIndex == 0 || !isFree[startIndex - 1] else { continue }
            // Breaks may run past the end date, but they have to start inside it.
            guard days[startIndex] <= last else { continue }

            for endIndex in startIndex..<min(startIndex + 45, span) where isFree[endIndex] {
                guard endIndex == span - 1 || !isFree[endIndex + 1] else { continue }

                let cost = workingBefore[endIndex + 1] - workingBefore[startIndex]
                let length = endIndex - startIndex + 1
                guard cost >= 1, cost <= maxCost, length >= minimumBreak else { continue }

                let bookDates = (startIndex...endIndex).filter { !isFree[$0] }.map { days[$0] }
                // The break may run past the end date, but every day booked has
                // to come out of this leave year. A Christmas break spilling into
                // January is fine; booking days in January to extend it is
                // spending next year's allowance.
                guard let lastBooked = bookDates.last, lastBooked <= last else { continue }

                startingAt[startIndex].append(
                    LeaveSuggestion(
                        bookDates: bookDates,
                        breakStart: days[startIndex],
                        breakEnd: days[endIndex],
                        anchor: (startIndex...endIndex).compactMap { holidayName[$0] }.first
                    )
                )
            }
        }

        let chosen = bestCombination(startingAt: startingAt, span: span, budget: allowance)
        return LeavePlan(
            suggestions: chosen.sorted { $0.breakStart < $1.breakStart },
            allowance: allowance
        )
    }

    /// Exact answer rather than a ranked guess.
    ///
    /// Picking greedily by value looks sensible and isn't: taking the best-rate
    /// break first can leave a budget that fits nothing good afterwards. This is
    /// a budgeted interval-scheduling problem, so it solves as one — for each
    /// day and each amount of leave left, the best total from there on. Roughly
    /// 400 days by 60 days of leave is a small table, and it can't be beaten.
    private func bestCombination(
        startingAt: [[LeaveSuggestion]],
        span: Int,
        budget: Int
    ) -> [LeaveSuggestion] {
        // best[index][remaining] = most days off obtainable from `index` onward.
        var best = [[Int]](repeating: [Int](repeating: 0, count: budget + 1), count: span + 1)
        // Which run to take there, or nil to move on a day.
        var take = [[Int?]](repeating: [Int?](repeating: nil, count: budget + 1), count: span + 1)

        for index in stride(from: span - 1, through: 0, by: -1) {
            for remaining in 0...budget {
                var bestValue = best[index + 1][remaining]
                var bestChoice: Int?

                for (offset, run) in startingAt[index].enumerated() where run.cost <= remaining {
                    let after = min(index + run.length, span)
                    let value = run.length + best[after][remaining - run.cost]
                    if value > bestValue {
                        bestValue = value
                        bestChoice = offset
                    }
                }

                best[index][remaining] = bestValue
                take[index][remaining] = bestChoice
            }
        }

        var result: [LeaveSuggestion] = []
        var index = 0
        var remaining = budget

        while index < span {
            guard let choice = take[index][remaining] else {
                index += 1
                continue
            }
            let run = startingAt[index][choice]
            result.append(run)
            remaining -= run.cost
            index = min(index + run.length, span)
        }
        return result
    }
}
