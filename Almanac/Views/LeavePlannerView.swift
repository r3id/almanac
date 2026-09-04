import SwiftUI

struct LeavePlannerView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    @State private var allowance = 25
    // A leave year, not a rolling twelve months — an allowance is granted per
    // year and doesn't carry, so the year is the window that matters.
    @State private var from = LeavePlannerView.yearStart(0)
    @State private var to = LeavePlannerView.yearEnd(0)
    @State private var minimumBreak = 4
    @State private var calendarID: String = ""
    @State private var title = "Annual leave"

    private let breakOptions = [4, 7, 9, 14]

    /// This year and the next two. Bank holidays are published years ahead, so
    /// planning early is the whole point — the good dates go first.
    private var yearOptions: [Int] {
        let thisYear = Calendar.current.component(.year, from: .now)
        return [thisYear, thisYear + 1, thisYear + 2]
    }

    private static func yearStart(_ offset: Int) -> Date {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: .now) + offset
        return calendar.date(from: DateComponents(year: year, month: 1, day: 1))?.startOfDay
            ?? Date.now.startOfDay
    }

    private static func yearEnd(_ offset: Int) -> Date {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: .now) + offset
        return calendar.date(from: DateComponents(year: year, month: 12, day: 31))?.startOfDay
            ?? Date.now.startOfDay
    }

    private var plan: LeavePlan {
        store.planLeave(allowance: allowance, from: from, to: to, minimumBreak: minimumBreak)
    }

    var body: some View {
        Form {
            Section {
                Stepper("Days of leave: \(allowance)", value: $allowance, in: 1...60)
                DatePicker("From", selection: $from, displayedComponents: .date)
                DatePicker("To", selection: $to, in: from..., displayedComponents: .date)

                Picker("Leave year", selection: Binding(
                    get: { Calendar.current.component(.year, from: from) },
                    set: { year in
                        let offset = year - Calendar.current.component(.year, from: .now)
                        from = LeavePlannerView.yearStart(offset)
                        to = LeavePlannerView.yearEnd(offset)
                    }
                )) {
                    ForEach(yearOptions, id: \.self) { year in
                        Text(String(year)).tag(year)
                    }
                }
                .pickerStyle(.segmented)

                Picker("Shortest break worth taking", selection: $minimumBreak) {
                    ForEach(breakOptions, id: \.self) { days in
                        Text("\(days) days").tag(days)
                    }
                }

                Picker("Add to", selection: $calendarID) {
                    ForEach(store.calendars) { tag in
                        Text(tag.name).tag(tag.id)
                    }
                }

                TextField("Title for booked days", text: $title)
            } footer: {
                // Naming the region matters here: Scotland has no Easter Monday
                // but does have 2 January and St Andrew's Day, which changes the
                // answer entirely.
                Text(store.automaticMarks.isEmpty
                     ? "No bank holidays loaded. Choose a region under School to fetch them from gov.uk."
                     : "Using \(store.holidayRegion.label) — \(store.automaticMarks.count) bank holidays from gov.uk — and your working week. Days already gone are skipped, so a part-finished year plans from today.")
            }

            Section {
                Text(plan.headline)
                    .font(.system(size: 17, weight: .medium))
                if plan.leaveUsed > 0 {
                    Text("\(plan.suggestions.count) breaks. Raise the shortest break for fewer, longer holidays — you'll lose a day or two overall.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if plan.leaveLeft > 0 && plan.leaveUsed > 0 {
                    Text("\(plan.leaveLeft) day\(plan.leaveLeft == 1 ? "" : "s") left over for whatever comes up.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(plan.suggestions) { suggestion in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(suggestion.rangeLabel)
                            .font(.system(size: 16, weight: .medium))
                        HStack(spacing: 6) {
                            Text("\(suggestion.length) days off")
                            Text("·")
                            Text("\(suggestion.cost) booked")
                            if let anchor = suggestion.anchor {
                                Text("·")
                                Text(anchor)
                            }
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }

                    let added = isBooked(suggestion)
                    Button {
                        added ? unbook(suggestion) : book(suggestion)
                    } label: {
                        Label(
                            added ? "In your calendar — tap to remove" : suggestion.bookLabel,
                            systemImage: added ? "checkmark.circle.fill" : "plus"
                        )
                    }
                    .foregroundStyle(added ? .secondary : Color.accentColor)
                }
            }

            if plan.suggestions.isEmpty {
                Section {
                    Text("Nothing to suggest. Try a wider date range, or check your working week is set correctly under Appearance.")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Holiday planner")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaPadding(.bottom, 70)
        .tint(theme.accent)
        .onAppear {
            if calendarID.isEmpty { calendarID = store.calendars.first?.id ?? "amber" }
        }
    }

    /// Read from the calendar rather than remembered in the view, so a plan you
    /// booked last month still shows as booked when you come back to it.
    private func isBooked(_ suggestion: LeaveSuggestion) -> Bool {
        suggestion.bookDates.allSatisfy { day in
            store.items(on: day).contains { $0.isAllDay && $0.title == title }
        }
    }

    /// One all-day entry per booked day, so the calendar shows exactly what you
    /// asked work for rather than a single block that spans the weekend too.
    private func book(_ suggestion: LeaveSuggestion) {
        for day in suggestion.bookDates {
            guard !store.items(on: day).contains(where: { $0.isAllDay && $0.title == title })
            else { continue }
            store.save(
                Item(
                    kind: .event,
                    title: title,
                    day: day,
                    isAllDay: true,
                    calendarID: calendarID.isEmpty ? (store.calendars.first?.id ?? "amber") : calendarID
                )
            )
        }
    }

    private func unbook(_ suggestion: LeaveSuggestion) {
        for day in suggestion.bookDates {
            for item in store.items(on: day) where item.isAllDay && item.title == title {
                store.delete(id: item.id)
            }
        }
    }
}
