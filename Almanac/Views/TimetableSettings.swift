import SwiftUI

struct TimetableSettings: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    let school: School

    private var timetable: Timetable { store.timetable(for: school) }

    var body: some View {
        Form {
            cycleSection
            periodsSection
            daysSection
        }
        .navigationTitle(school.name.isEmpty ? "Timetable" : school.name)
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaPadding(.bottom, 70)
        .tint(theme.accent)
    }

    // MARK: Cycle

    private var cycleSection: some View {
        Section {
            Picker("Week cycle", selection: binding(\.cycleLength)) {
                Text("Every week").tag(1)
                Text("Week 1 and 2").tag(2)
            }

            if timetable.isCycled {
                Picker("Cycle", selection: binding(\.reset)) {
                    ForEach(CycleReset.allCases, id: \.self) { option in
                        Text(option.label).tag(option)
                    }
                }

                HStack {
                    Text("This week")
                    Spacer()
                    Text("Week \(store.week(on: .now, for: school))")
                        .foregroundStyle(.secondary)
                }

                Button("This week is Week 1") {
                    update { $0.anchor = Date.now.startOfWeek }
                }
                Button("This week is Week 2") {
                    update { $0.anchor = Date.now.startOfWeek.adding(days: -7) }
                }
            }
        } header: {
            Text("Cycle")
        } footer: {
            Text(cycleFooter)
        }
    }

    private var cycleFooter: String {
        guard timetable.isCycled else {
            return "Switch this on if the timetable alternates between two weeks."
        }
        switch timetable.reset {
        case .schoolWeeks:
            return "A holiday week doesn't advance the cycle, so the pattern picks up where it left off. Counting calendar weeks instead drifts a week out after every half term."
        case .continuous:
            return "Counts straight through, holidays included."
        case .eachTerm:
            return "Week 1 starts on the first day of each term."
        case .eachBreak:
            return "Week 1 whenever school comes back, half terms included."
        }
    }

    // MARK: Periods

    private var periodsSection: some View {
        Section {
            Stepper("\(timetable.periodsPerDay) lessons a day", value: periodCountBinding, in: 1...12)

            ForEach(1...max(timetable.periodsPerDay, 1), id: \.self) { period in
                DatePicker(
                    "Lesson \(period)",
                    selection: periodTimeBinding(period),
                    displayedComponents: .hourAndMinute
                )
            }
        } header: {
            Text("Times")
        } footer: {
            Text("Set once. Every lesson in that slot uses it, so you only type subjects into the grid below.")
        }
    }

    private var periodCountBinding: Binding<Int> {
        Binding(
            get: { timetable.periodsPerDay },
            set: { value in update { $0.periodsPerDay = value } }
        )
    }

    /// Times are stored per period, so the array has to grow with the count.
    private func periodTimeBinding(_ period: Int) -> Binding<Date> {
        Binding(
            get: {
                let minutes = timetable.start(ofPeriod: period) ?? (8 * 60 + 30 + (period - 1) * 60)
                return Calendar.current.date(
                    bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now
                ) ?? .now
            },
            set: { date in
                let minutes = Calendar.current.component(.hour, from: date) * 60
                    + Calendar.current.component(.minute, from: date)
                update { table in
                    while table.periodStarts.count < table.periodsPerDay {
                        table.periodStarts.append(nil)
                    }
                    table.periodStarts[period - 1] = minutes
                }
            }
        )
    }

    // MARK: Days

    private var daysSection: some View {
        ForEach(weekOptions, id: \.self) { week in
            Section(timetable.isCycled ? "Week \(week)" : "Every week") {
                ForEach(Weekday.all.prefix(5), id: \.number) { weekday in
                    NavigationLink {
                        DayGridEditor(school: school, weekday: weekday.number, week: week)
                            .environment(store)
                            .environment(\.theme, theme)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(weekday.name)
                            Text(summary(weekday: weekday.number, week: week))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
    }

    private var weekOptions: [Int] {
        timetable.isCycled ? [1, 2] : [0]
    }

    private func summary(weekday: Int, week: Int) -> String {
        let lessons = timetable.lessons(weekday: weekday, week: week)
            .filter { !$0.subject.isEmpty && !$0.isBreak }
        guard !lessons.isEmpty else { return "Nothing set" }
        return lessons.map(\.subject).joined(separator: ", ")
    }

    // MARK: Editing

    private func binding<Value>(_ path: WritableKeyPath<Timetable, Value>) -> Binding<Value> {
        Binding(
            get: { timetable[keyPath: path] },
            set: { value in update { $0[keyPath: path] = value } }
        )
    }

    private func update(_ change: (inout Timetable) -> Void) {
        var copy = timetable
        change(&copy)
        store.saveTimetable(copy, for: school)
    }
}

// MARK: - A day, one field per lesson

/// The whole point: type six subjects down a column rather than opening a form
/// six times. Sixty entries for a two-week timetable is only bearable if each
/// one is a tap and a word.
struct DayGridEditor: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    let school: School
    let weekday: Int
    let week: Int

    private var timetable: Timetable { store.timetable(for: school) }

    var body: some View {
        Form {
            Section {
                ForEach(1...max(timetable.periodsPerDay, 1), id: \.self) { period in
                    row(period)
                }
            } header: {
                Text(timetable.isCycled ? "\(Weekday.name(weekday)) · Week \(week)" : Weekday.name(weekday))
            } footer: {
                Text("Leave a slot empty for a free period. The cup marks lunch, break or form time, which show quietly and never ask for kit. The bag marks anything needing kit brought in — you'll get a reminder the evening before.")
            }

            if timetable.isCycled, week == 2 {
                Section {
                    Button("Copy Week 1's \(Weekday.name(weekday))") { copyOtherWeek(from: 1) }
                }
            }
            if timetable.isCycled, week == 1 {
                Section {
                    Button("Copy Week 2's \(Weekday.name(weekday))") { copyOtherWeek(from: 2) }
                }
            }
        }
        .navigationTitle(Weekday.name(weekday))
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaPadding(.bottom, 70)
        .tint(theme.accent)
    }

    private func row(_ period: Int) -> some View {
        let lesson = existing(period)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("\(period)")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)

                TextField("Free", text: subjectBinding(period))
                    .font(.system(size: 16, weight: .medium))

                if let time = timetable.start(ofPeriod: period) {
                    Text(Item.clock(time))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Button {
                    toggleBreak(period)
                } label: {
                    Image(systemName: lesson?.isBreak == true ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundStyle(lesson?.isBreak == true ? theme.accent : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(lesson == nil)

                Button {
                    toggleKit(period)
                } label: {
                    Image(systemName: lesson?.needsKit == true ? "bag.fill" : "bag")
                        .foregroundStyle(lesson?.needsKit == true ? theme.accent : .secondary)
                }
                .buttonStyle(.plain)
                .disabled(lesson == nil || lesson?.isBreak == true)
            }

            if let lesson, !lesson.subject.isEmpty {
                TextField("Room, teacher — optional", text: detailBinding(period))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)

                if lesson.needsKit {
                    TextField("What to bring", text: noteBinding(period))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 30)
                }
            }
        }
    }

    // MARK: Bindings

    private func existing(_ period: Int) -> Lesson? {
        timetable.lessons.first {
            $0.weekday == weekday && $0.week == week && $0.period == period
        }
    }

    private func subjectBinding(_ period: Int) -> Binding<String> {
        Binding(
            get: { existing(period)?.subject ?? "" },
            set: { value in
                let trimmed = value.trimmingCharacters(in: .whitespaces)
                update { table in
                    if let index = index(in: table, period: period) {
                        // Clearing the field removes the lesson rather than
                        // leaving an empty one behind.
                        if trimmed.isEmpty {
                            table.lessons.remove(at: index)
                        } else {
                            table.lessons[index].subject = value
                        }
                    } else if !trimmed.isEmpty {
                        table.lessons.append(
                            Lesson(subject: value, weekday: weekday, week: week, period: period)
                        )
                    }
                }
            }
        )
    }

    private func detailBinding(_ period: Int) -> Binding<String> {
        Binding(
            get: { existing(period)?.detail ?? "" },
            set: { value in
                update { table in
                    if let index = index(in: table, period: period) {
                        table.lessons[index].detail = value
                    }
                }
            }
        )
    }

    private func noteBinding(_ period: Int) -> Binding<String> {
        Binding(
            get: { existing(period)?.note ?? "" },
            set: { value in
                update { table in
                    if let index = index(in: table, period: period) {
                        table.lessons[index].note = value
                    }
                }
            }
        )
    }

    /// Marking a slot as a break clears any kit on it — lunch never needs a bag.
    private func toggleBreak(_ period: Int) {
        update { table in
            if let index = index(in: table, period: period) {
                table.lessons[index].isBreak.toggle()
                if table.lessons[index].isBreak {
                    table.lessons[index].needsKit = false
                    table.lessons[index].note = ""
                }
            }
        }
    }

    private func toggleKit(_ period: Int) {
        update { table in
            if let index = index(in: table, period: period) {
                table.lessons[index].needsKit.toggle()
            }
        }
    }

    private func copyOtherWeek(from week: Int) {
        update { table in
            let source = table.lessons.filter { $0.weekday == weekday && $0.week == week }
            table.lessons.removeAll { $0.weekday == weekday && $0.week == self.week }
            for lesson in source {
                var copy = lesson
                copy.id = UUID()
                copy.week = self.week
                table.lessons.append(copy)
            }
        }
    }

    private func index(in table: Timetable, period: Int) -> Int? {
        table.lessons.firstIndex {
            $0.weekday == weekday && $0.week == week && $0.period == period
        }
    }

    private func update(_ change: (inout Timetable) -> Void) {
        var copy = timetable
        change(&copy)
        store.saveTimetable(copy, for: school)
    }
}
