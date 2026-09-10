import SwiftUI

struct DayView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    let day: Date

    enum Mode { case list, grid }

    @State private var mode: Mode = .list
    @State private var weather: DayWeather?
    @State private var weatherLoaded = false
    @State private var onThisDay: OnThisDayEntry?
    @State private var onThisDayLoaded = false
    @State private var route: Route?

    /// Same one-sheet rule as the root view.
    private enum Route: Identifiable {
        case detail(Item)
        case edit(Item)

        var id: String {
            switch self {
            case .detail(let item): return "detail-\(item.id)"
            case .edit(let item):   return "edit-\(item.id)"
            }
        }
    }
    @State private var legs: [UUID: TravelLeg] = [:]
    @State private var weatherError: String?

    private let hourHeight: CGFloat = 58

    var body: some View {
        VStack(spacing: 0) {
            headerBar

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    title
                    birthdaySection
                    allDaySection
                    scheduleSection
                    lessonsSection
                    actionsSection
                    weatherSection
                    daylightSection
                    countdownSection
                    onThisDaySection
                }
                .padding(.horizontal, 20)
                .padding(.top, 6)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
        }
        .background(theme.accent.ignoresSafeArea())
        .foregroundStyle(theme.onAccent)
        .task { await loadWeather() }
        .task { await loadOnThisDay() }
        .task { await loadTravel() }
        // Presented from here rather than the root: a sheet requested by a view
        // underneath a fullScreenCover never reaches the screen.
        .sheet(item: $route) { destination in
            Group {
                switch destination {
                case .detail(let item):
                    ItemDetailView(item: item) { toEdit in
                        route = nil
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            route = .edit(toEdit)
                        }
                    }
                    .presentationDetents([.large])

                case .edit(let item):
                    ItemEditView(draft: item, isNew: store.item(id: item.id) == nil)
                }
            }
            .environment(store)
            .environment(\.theme, theme)
        }
    }

    // MARK: Title

    private var title: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.isSameDay(as: .now) ? "TODAY" : weekdayName.uppercased())
                .font(.system(size: 34, weight: .semibold))
            Text("\(monthName.uppercased()) \(Calendar.current.component(.day, from: day)), WEEK \(day.weekOfYear)")
                .font(.system(size: 13))
                .tracking(2.2)
                .opacity(0.8)

            let marks = store.marks(on: day)
            if !marks.isEmpty {
                FlowRow(spacing: 6) {
                    ForEach(marks) { mark in
                        Text(store.label(for: mark))
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.8)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(theme.onAccent.opacity(0.18), in: Capsule())
                    }
                }
                .padding(.top, 4)
            }

            ForEach(store.schoolCountdowns(on: day)) { countdown in
                HStack(spacing: 7) {
                    Image(systemName: countdown.isBreak ? "backpack" : "graduationcap")
                        .font(.system(size: 11))
                    Text(countdown.schoolName.map { "\($0) · \(countdown.text)" } ?? countdown.text)
                        .font(.system(size: 12.5, weight: .medium))
                }
                .opacity(0.85)
                .padding(.top, 6)
            }
        }
    }

    private var weekdayName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: day)
    }

    private var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL"
        return formatter.string(from: day)
    }

    // MARK: Birthdays

    @ViewBuilder
    private var birthdaySection: some View {
        let today = store.birthdays(on: day)
        let soon = store.upcomingBirthdays(from: day, within: 14)

        if !today.isEmpty || !soon.isEmpty {
            SectionLabel(text: "BIRTHDAYS")
            VStack(spacing: 8) {
                ForEach(today) { item in
                    Button { route = .detail(item) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "birthday.cake")
                                .font(.system(size: 17))
                            Text(item.birthdayLine)
                                .font(.system(size: 16, weight: .medium))
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 13)
                        .background(theme.onAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }

                // A fortnight's warning, because a card posted on the morning is
                // a card that arrives late.
                ForEach(soon, id: \.item.id) { entry in
                    Button { route = .detail(entry.item) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "birthday.cake")
                                .font(.system(size: 13))
                                .opacity(0.7)
                            Text(entry.item.title)
                                .font(.system(size: 14))
                            Spacer(minLength: 0)
                            Text(DayCount.short(entry.days))
                                .font(.system(size: 12))
                                .opacity(0.7)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 10)
                        .background(theme.onAccent.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: All day

    @ViewBuilder
    private var allDaySection: some View {
        let items = store.allDayItems(on: day)
        if !items.isEmpty {
            SectionLabel(text: "ALL DAY")
            FlowRow(spacing: 7) {
                ForEach(items) { item in
                    Button { route = .detail(item) } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(Color(hex: store.tag(for: item).hex))
                                .frame(width: 9, height: 9)
                            Text(item.title)
                                .font(.system(size: 14.5))
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 9)
                        .background(theme.onAccent.opacity(0.13), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Schedule

    @ViewBuilder
    private var scheduleSection: some View {
        SectionLabel(text: "SCHEDULE")
        let items = store.timedItems(on: day)

        if items.isEmpty {
            Text("No timed events. The day is open.")
                .font(.system(size: 14, weight: .light))
                .opacity(0.6)
        } else if mode == .list {
            VStack(spacing: 8) {
                ForEach(items) { item in
                    Button { route = .detail(item) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            TagBar(item: item, height: item.place.isEmpty ? 34 : 46)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.system(size: 16, weight: .medium))
                                Text(item.timeLabel)
                                    .font(.system(size: 12.5))
                                    .opacity(0.78)
                                if !item.place.isEmpty {
                                    Text(item.place)
                                        .font(.system(size: 12.5))
                                        .opacity(0.78)
                                }
                            }
                            Spacer(minLength: 0)
                            if let leg = legs[item.id] {
                                travelChip(leg)
                            }
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 13)
                        .background(theme.onAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            hourGrid(items)
        }
    }

    /// Mode icon over the time, with the origin underneath when the leg starts
    /// at another event rather than at home.
    private func travelChip(_ leg: TravelLeg) -> some View {
        VStack(spacing: 3) {
            Image(systemName: leg.mode.symbol)
                .font(.system(size: 15))
            Text(leg.durationLabel)
                .font(.system(size: 11, weight: .medium))
            if let origin = leg.fromTitle {
                Text("from \(origin)")
                    .font(.system(size: 9))
                    .opacity(0.7)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 52)
        .opacity(0.85)
    }

    /// Routes each located event, preferring the previous located event of the
    /// day as the starting point and falling back to wherever you are now.
    private func loadTravel() async {
        let timed = store.timedItems(on: day).filter { $0.travel != .none && !$0.place.isEmpty }
        guard !timed.isEmpty else { return }

        for item in timed {
            let previous = store.timedItems(on: day)
                .filter { $0.id != item.id && $0.effectiveEnd <= item.start && !$0.place.isEmpty }
                .max { $0.effectiveEnd < $1.effectiveEnd }

            var minutes: Int?
            var origin: String?

            if let previous, previous.hasResolvedPlace, item.hasResolvedPlace {
                minutes = await TravelService.shared.minutes(
                    fromQuery: previous.routeQuery,
                    fromLatitude: previous.placeLatitude,
                    fromLongitude: previous.placeLongitude,
                    toQuery: item.routeQuery,
                    toLatitude: item.placeLatitude,
                    toLongitude: item.placeLongitude,
                    mode: item.travel
                )
                if minutes != nil { origin = previous.title }
            }

            if minutes == nil {
                minutes = await TravelService.shared.minutes(
                    to: item.routeQuery,
                    latitude: item.placeLatitude,
                    longitude: item.placeLongitude,
                    mode: item.travel
                )
            }
            if minutes == nil, item.travelMinutes > 0 {
                minutes = item.travelMinutes
            }

            guard let minutes, same(day) else { continue }
            legs[item.id] = TravelLeg(minutes: minutes, mode: item.travel, fromTitle: origin)
        }
    }

    private func same(_ other: Date) -> Bool { other.isSameDay(as: day) }

    // MARK: Hour grid

    private func hourGrid(_ items: [Item]) -> some View {
        let lowHour = min(items.map { $0.start / 60 }.min() ?? 8, 8)
        let highHour = max(items.map { Int(ceil(Double($0.endWithinDay) / 60)) }.max() ?? 18, 18)
        let hours = Array(lowHour..<highHour)
        let lanes = assignLanes(items)
        let laneCount = (lanes.values.max() ?? 0) + 1

        return ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                ForEach(hours, id: \.self) { hour in
                    HStack(alignment: .top, spacing: 0) {
                        Text(hourLabel(hour))
                            .font(.system(size: 11))
                            .tracking(0.8)
                            .opacity(0.65)
                            .frame(width: 54, alignment: .leading)
                            .offset(y: -6)
                        Rectangle()
                            .fill(theme.onAccent.opacity(0.14))
                            .frame(height: 1)
                    }
                    .frame(height: hourHeight, alignment: .top)
                }
            }

            GeometryReader { geometry in
                let laneWidth = (geometry.size.width - 54) / CGFloat(laneCount)
                ForEach(items) { item in
                    let lane = lanes[item.id] ?? 0
                    let top = CGFloat(item.start - lowHour * 60) / 60 * hourHeight
                    let height = max(CGFloat(item.endWithinDay - item.start) / 60 * hourHeight - 4, 34)

                    Button { route = .detail(item) } label: {
                        HStack(alignment: .top, spacing: 9) {
                            TagBar(item: item, height: min(height - 14, 34))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .font(.system(size: 13.5, weight: .medium))
                                    .lineLimit(1)
                                Text(item.timeLabel)
                                    .font(.system(size: 11))
                                    .opacity(0.75)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .frame(width: laneWidth - 12, height: height, alignment: .topLeading)
                        .background(theme.onAccent.opacity(0.15), in: RoundedRectangle(cornerRadius: 9))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 54 + CGFloat(lane) * laneWidth + 6, y: top)
                }
            }
        }
        .frame(height: CGFloat(hours.count) * hourHeight)
    }

    private func hourLabel(_ hour: Int) -> String {
        let display = hour % 12 == 0 ? 12 : hour % 12
        return "\(display) \(hour < 12 || hour == 24 ? "AM" : "PM")"
    }

    /// Simple greedy packing so overlapping events sit side by side.
    private func assignLanes(_ items: [Item]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        var laneEnds: [Int] = []

        for item in items.sorted(by: { $0.start < $1.start }) {
            var lane = 0
            while lane < laneEnds.count, laneEnds[lane] > item.start { lane += 1 }
            if lane == laneEnds.count {
                laneEnds.append(item.endWithinDay)
            } else {
                laneEnds[lane] = item.endWithinDay
            }
            result[item.id] = lane
        }
        return result
    }

    // MARK: Weather

    @ViewBuilder
    private var weatherSection: some View {
        SectionLabel(text: "WEATHER")

        if store.activeLocation == nil {
            Text("Add a location in settings to see the forecast here.")
                .font(.system(size: 14, weight: .light))
                .opacity(0.6)
        } else if let weather {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 14) {
                    WeatherIcon(kind: weather.condition.icon)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("\(weather.low) – \(weather.high)°C")
                            .font(.system(size: 25, weight: .medium))
                        Text(weather.condition.text)
                            .font(.system(size: 13.5))
                            .opacity(0.85)
                        Text(store.activeLocation?.name ?? "")
                            .font(.system(size: 13.5))
                            .opacity(0.7)
                    }
                }

                let cells: [(String, String)] = [
                    ("umbrella", weather.precipitationChance.map { "\($0)%" } ?? "—"),
                    ("sun.max", "UV \(weather.uvIndex)"),
                    ("humidity", weather.humidityLabel),
                    ("wind", "\(weather.windSpeed) km/h"),
                    ("sunrise", weather.sunrise),
                    ("sunset", weather.sunset)
                ]

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(cells, id: \.1) { cell in
                        HStack(spacing: 9) {
                            Image(systemName: cell.0)
                                .font(.system(size: 13))
                                .frame(width: 18)
                            Text(cell.1)
                                .font(.system(size: 13))
                            Spacer(minLength: 0)
                        }
                        .opacity(0.9)
                    }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.onAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
        } else {
            Text(weatherMessage)
                .font(.system(size: 14, weight: .light))
                .opacity(0.6)
        }
    }

    private var weatherMessage: String {
        if !weatherLoaded { return "Loading…" }
        if let weatherError { return weatherError }
        return "No forecast for this date — it only reaches two weeks ahead."
    }

    private func loadWeather() async {
        guard let place = store.activeLocation else {
            weatherLoaded = true
            return
        }
        let forecast = await WeatherService.shared.forecast(
            latitude: place.latitude,
            longitude: place.longitude
        )
        weatherError = forecast.isEmpty ? await WeatherService.shared.lastFailure : nil
        weather = forecast[WeatherService.dayKey(day)]
        weatherLoaded = true
    }

    // MARK: Daylight

    @ViewBuilder
    private var daylightSection: some View {
        if store.showAlmanacLines, let place = store.activeLocation {

            let solar = Sky.solar(date: day, latitude: place.latitude, longitude: place.longitude)
            let moon = Sky.moon(on: day)
            let change = Sky.daylightChange(
                date: day,
                latitude: place.latitude,
                longitude: place.longitude
            )

            SectionLabel(text: "DAYLIGHT")

            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "sun.horizon")
                        .font(.system(size: 18))
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(solar.lengthLabel + " of daylight")
                            .font(.system(size: 15.5, weight: .medium))
                        if let change {
                            Text(change)
                                .font(.system(size: 12.5))
                                .opacity(0.75)
                        }
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 12) {
                    Image(systemName: moon.symbol)
                        .font(.system(size: 18))
                        .frame(width: 26)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(moon.name)
                            .font(.system(size: 15.5, weight: .medium))
                        Text("\(moon.illumination)% lit")
                            .font(.system(size: 12.5))
                            .opacity(0.75)
                    }
                    Spacer(minLength: 0)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.onAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    // MARK: Counting down

    @ViewBuilder
    private var countdownSection: some View {
        let pending = store.countdowns(from: day)
        if !pending.isEmpty {
            SectionLabel(text: "COUNTING DOWN")
            VStack(spacing: 8) {
                ForEach(pending, id: \.item.id) { entry in
                    Button { route = .detail(entry.item) } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(DayCount.long(entry.days).capitalizedFirst)
                                    .font(.system(size: 21, weight: .semibold))
                                Text(entry.item.title)
                                    .font(.system(size: 14))
                                    .opacity(0.85)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "hourglass")
                                .font(.system(size: 20))
                                .opacity(0.55)
                        }
                        .padding(.horizontal, 15)
                        .padding(.vertical, 14)
                        .background(theme.onAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Lessons

    /// A section per child, only here. Lessons are the same every week, so
    /// putting them in the month or the timeline would bury the things that
    /// actually change.
    @ViewBuilder
    private var lessonsSection: some View {
        let bySchool = store.lessonsBySchool(on: day)
        ForEach(bySchool, id: \.school.id) { entry in
            SectionLabel(
                text: store.hasMultipleSchools
                    ? entry.school.name.uppercased()
                    : "LESSONS"
            )

            VStack(spacing: 8) {
                if store.timetable(for: entry.school).isCycled {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                        Text("Week \(entry.week)")
                            .font(.system(size: 12, weight: .semibold))
                            .tracking(0.6)
                        Spacer(minLength: 0)
                    }
                    .opacity(0.7)
                }

                VStack(spacing: 8) {
                    ForEach(entry.lessons) { lesson in
                        lessonRow(lesson, school: entry.school)
                    }
                }
            }
        }
    }

    private func lessonRow(_ lesson: Lesson, school: School) -> some View {
        HStack(spacing: 12) {
            // Just the lesson number. The times never change, so within a day
            // or two they're wallpaper — and they were what made the rows
            // different heights.
            Text("\(lesson.period)")
                .font(.system(size: 14, weight: .semibold))
                .opacity(0.75)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                Text(lesson.subject)
                    .font(.system(size: lesson.isBreak ? 14 : 15.5,
                                  weight: lesson.isBreak ? .regular : .medium))
                if !lesson.detail.isEmpty {
                    Text(lesson.detail)
                        .font(.system(size: 12.5))
                        .opacity(0.7)
                }
                if lesson.needsKit, !lesson.note.isEmpty {
                    Text(lesson.note)
                        .font(.system(size: 12.5))
                        .opacity(0.75)
                }
            }
            Spacer(minLength: 0)
            if lesson.needsKit, !lesson.isBreak {
                Image(systemName: "bag.fill")
                    .font(.system(size: 13))
                    .opacity(0.85)
            }
        }
        .padding(.horizontal, 15)
        .padding(.vertical, lesson.isBreak ? 10 : 13)
        .background(theme.onAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
        // A break sits back so the lessons either side stand out, but stays in
        // the list — the day doesn't read right with a hole in the middle.
        .opacity(lesson.isBreak ? 0.55 : 1)
    }

    // MARK: Actions

    @ViewBuilder
    private var actionsSection: some View {
        let items = store.actions(on: day)
        if !items.isEmpty {
            SectionLabel(text: "ACTIONS")
            VStack(spacing: 8) {
                ForEach(items) { item in
                    // Two targets in one row: the box ticks it off, the rest of
                    // the row opens it. One button doing both meant an action
                    // could only ever be completed, never corrected.
                    HStack(spacing: 12) {
                        Button {
                            store.toggleDone(id: item.id)
                        } label: {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(theme.onAccent.opacity(0.75), lineWidth: 1.6)
                                .frame(width: 20, height: 20)
                                .overlay {
                                    if item.isDone {
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 12, weight: .bold))
                                    }
                                }
                                .padding(.vertical, 6)
                                .padding(.trailing, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            route = .detail(item)
                        } label: {
                            HStack(spacing: 8) {
                                Text(item.title)
                                    .font(.system(size: 15.5))
                                    .strikethrough(item.isDone)
                                    .multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .opacity(0.4)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .opacity(item.isDone ? 0.5 : 1)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 11)
                    .background(theme.onAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
                }
            }
        }
    }

    // MARK: On this day

    @ViewBuilder
    private var onThisDaySection: some View {
        SectionLabel(text: "ON THIS DAY")
        if let onThisDay {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(String(onThisDay.year))
                    .font(.system(size: 14, weight: .semibold))
                Text(onThisDay.text)
                    .font(.system(size: 14))
            }
            .lineSpacing(3)
            .padding(15)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.onAccent.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
        } else {
            Text(onThisDayLoaded ? "Nothing to show." : "Loading…")
                .font(.system(size: 14, weight: .light))
                .opacity(0.6)
        }
    }

    private func loadOnThisDay() async {
        onThisDay = await OnThisDayService.shared.entry(for: day)
        onThisDayLoaded = true
    }

    // MARK: Header bar

    /// Back, the schedule/list switch and add — at the top, labelled, and in the
    /// same place as every other screen. As a floating bar of bare glyphs it
    /// wasn't obvious that the clock meant "show it by the hour".
    private var headerBar: some View {
        HStack(spacing: 10) {
            Spacer()

            GlassGroup {
                modePill("List", isOn: mode == .list) {
                    withAnimation(.easeOut(duration: 0.15)) { mode = .list }
                }
                modePill("Hours", isOn: mode == .grid) {
                    withAnimation(.easeOut(duration: 0.15)) { mode = .grid }
                }
                PillButton(title: "ADD") { route = .edit(Item.draft(on: day)) }
            }
        }
        .foregroundStyle(theme.onAccent)
        .padding(.horizontal, 20)
        // Clear of the sheet's grab indicator, which sits in the chrome above.
        .padding(.top, 42)
        .padding(.bottom, 10)
    }

    private func modePill(_ title: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(isOn ? theme.accent : theme.onAccent.opacity(0.6))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .background(isOn ? AnyShapeStyle(theme.onAccent) : AnyShapeStyle(Color.clear), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Wrapping row for the all-day pills

struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
