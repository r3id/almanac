import Foundation

/// A term, as your council publishes it: a name and two dates.
///
/// This is the only school structure you type in. The holidays between terms are
/// worked out from the gaps, because a gap between two terms *is* a holiday —
/// entering both would mean holding the same fact twice and keeping the two in
/// agreement forever.
///
/// Half terms and inset days still get entered separately, since they sit inside
/// a term and can't be derived from anything.
nonisolated struct SchoolTerm: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String = ""
    var start: Date = Date.now.startOfDay
    var end: Date = Date.now.startOfDay
    /// Nil on anything saved before schools existed; treated as the first school.
    var schoolID: UUID?

    func contains(_ day: Date) -> Bool {
        let key = day.startOfDay
        return key >= start.startOfDay && key <= end.startOfDay
    }

    var rangeLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM yyyy"
        return "\(formatter.string(from: start)) – \(formatter.string(from: end))"
    }

    init(
        id: UUID = UUID(),
        name: String = "",
        start: Date = Date.now.startOfDay,
        end: Date = Date.now.startOfDay,
        schoolID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.start = start.startOfDay
        self.end = end.startOfDay
        self.schoolID = schoolID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        start = try c.decodeIfPresent(Date.self, forKey: .start) ?? .now.startOfDay
        end = try c.decodeIfPresent(Date.self, forKey: .end) ?? start
        schoolID = try c.decodeIfPresent(UUID.self, forKey: .schoolID)
    }
}

extension SchoolTerm {
    /// Names the gap that *follows* a term from the month it starts in.
    ///
    /// A heuristic, and a UK-shaped one — but "Summer holidays" reads far better
    /// in a countdown than "School holidays", and the alternative was asking you
    /// to name something the app already worked out for itself.
    static func holidayName(startingIn date: Date) -> String {
        switch Calendar.current.component(.month, from: date) {
        case 12, 1:     return "Christmas holidays"
        case 2:         return "February holidays"
        case 3, 4:      return "Easter holidays"
        case 5:         return "May holidays"
        case 6:         return "June holidays"
        case 7, 8, 9:   return "Summer holidays"
        case 10, 11:    return "Autumn holidays"
        default:        return "School holidays"
        }
    }
}
