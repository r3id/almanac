import SwiftUI

/// The day at a glance, in the app's own clothes.
///
/// Everything here already existed somewhere — it just needed one screen that
/// answers "what have I got on?" without making you pick a date first.
struct TodayView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var onOpenDay: (Date) -> Void
    var onOpenItem: (Item) -> Void
    var onAdd: () -> Void

    @State private var weather: DayWeather?

    private var today: Date { Date.now.startOfDay }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                tiles
                factLine
                kitLine
                schoolLines
                nextUp
                scheduleSection
                actionsSection
                countdownSection
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 20)
        }
        .scrollIndicators(.hidden)
        .safeAreaPadding(.bottom, 70)
        .background(Ink.base)
        .foregroundStyle(.white)
        .task { await loadWeather() }
    }

    // MARK: Header

    private var greeting: String {
        let time: String
        switch Calendar.current.component(.hour, from: .now) {
        case ..<12:   time = "Good morning"
        case 12..<18: time = "Good afternoon"
        default:      time = "Good evening"
        }
        return store.userName.isEmpty ? time : "\(time), \(store.userName)"
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                Text(greeting)
                    .font(.system(size: 30, weight: .semibold))
                Spacer()
                GlassGroup { PillButton(title: "ADD", action: onAdd) }
            }
            // Same treatment as the month heading: weekday and date in the
            // theme colour, the year light behind it.
            Button { onOpenDay(today) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(weekdayAndDate.uppercased())
                        .font(.system(size: 20, weight: .medium))
                        .foregroundStyle(theme.accent)
                    Text(yearName)
                        .font(.system(size: 20, weight: .ultraLight))
                        .foregroundStyle(theme.accent.opacity(0.55))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent.opacity(0.45))
                }
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 40)
    }

    private var weekdayAndDate: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: today)
    }

    private var yearName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: today)
    }

    // MARK: Tiles

    private var tiles: some View {
        let todayCount = store.items(on: today).count
        let tomorrowCount = store.items(on: today.adding(days: 1)).count
        let outstanding = store.outstandingActions()
        let overdue = outstanding.filter { store.isOverdue($0) }.count

        return HStack(spacing: 9) {
            tile(String(todayCount), "Today", filled: true)
            tile(String(tomorrowCount), "Tomorrow", filled: false)
            tile(
                String(outstanding.count),
                outstanding.isEmpty ? "Actions" : (overdue > 0 ? "\(overdue) overdue" : "Actions"),
                filled: false,
                alarm: overdue > 0
            )
        }
        .padding(.top, 22)
    }

    private func tile(_ number: String, _ caption: String, filled: Bool, alarm: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(number)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(filled ? theme.onAccent : (alarm ? Color(hex: "FF8A7A") : .white))
            Text(caption)
                .font(.system(size: 12))
                .foregroundStyle(filled ? theme.onAccent.opacity(0.75) : .white.opacity(0.5))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            filled ? AnyShapeStyle(theme.accent)
                   : AnyShapeStyle(Color.white.opacity(alarm ? 0.10 : 0.06)),
            in: RoundedRectangle(cornerRadius: 14)
        )
    }

    // MARK: The fact

    /// One line of context under the counts. On a birthday or Christmas it takes
    /// the theme colour and says so properly; the rest of the year it's quiet.
    @ViewBuilder
    private var factLine: some View {
        if let fact = store.fact(on: today) {
            HStack(spacing: 9) {
                Image(systemName: fact.symbol)
                    .font(.system(size: 13))
                    .foregroundStyle(fact.isCelebration ? theme.accent : .white.opacity(0.5))
                Text(fact.text)
                    .font(.system(size: 14, weight: fact.isCelebration ? .semibold : .regular))
                    .foregroundStyle(fact.isCelebration ? .white : .white.opacity(0.65))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                fact.isCelebration
                    ? AnyShapeStyle(theme.accent.opacity(0.22))
                    : AnyShapeStyle(Color.white.opacity(0.05)),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .padding(.top, 12)
        }
    }

    // MARK: Kit

    /// Today's bag and tomorrow's, because the useful moment is the evening
    /// before — the same reason the reminder fires at six.
    @ViewBuilder
    private var kitLine: some View {
        let todayKit = store.kitNeeded(on: today)
        let tomorrowKit = store.kitNeeded(on: today.adding(days: 1))

        if !todayKit.isEmpty || !tomorrowKit.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                if !todayKit.isEmpty {
                    kitRow("Today", todayKit, strong: true)
                }
                if !tomorrowKit.isEmpty {
                    kitRow("Tomorrow", tomorrowKit, strong: false)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(theme.accent.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 12)
        }
    }

    private func kitRow(_ when: String, _ needed: [(school: School, lesson: Lesson)], strong: Bool) -> some View {
        let subjects = needed.map(\.lesson.subject).joined(separator: ", ")
        let notes = needed.map(\.lesson.note).filter { !$0.isEmpty }
        let names = store.hasMultipleSchools
            ? Set(needed.map(\.school.name)).sorted().joined(separator: ", ") + " · "
            : ""

        return HStack(alignment: .top, spacing: 9) {
            Image(systemName: "bag.fill")
                .font(.system(size: 13))
                .foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(names)\(subjects) \(when.lowercased())")
                    .font(.system(size: 14, weight: strong ? .semibold : .medium))
                if !notes.isEmpty {
                    Text(notes.joined(separator: " · "))
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: School

    @ViewBuilder
    private var schoolLines: some View {
        let countdowns = store.schoolCountdowns(on: today)
        if !countdowns.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(countdowns) { countdown in
                    HStack(spacing: 9) {
                        Image(systemName: countdown.isBreak ? "backpack" : "graduationcap")
                            .font(.system(size: 13))
                            .foregroundStyle(theme.accent)
                        Text(countdown.schoolName.map { "\($0) · \(countdown.text)" } ?? countdown.text)
                            .font(.system(size: 14, weight: .medium))
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 12)
        }
    }

    // MARK: Next up

    /// The one thing you're most likely to be about to miss.
    @ViewBuilder
    private var nextUp: some View {
        let minutesNow = Calendar.current.component(.hour, from: .now) * 60
            + Calendar.current.component(.minute, from: .now)
        let next = store.timedItems(on: today).first { $0.start >= minutesNow }

        if let next {
            SectionLabel(text: "NEXT UP")
            Button { onOpenItem(next) } label: {
                HStack(alignment: .top, spacing: 12) {
                    TagBar(item: next, height: 40)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(next.title)
                            .font(.system(size: 18, weight: .semibold))
                        Text(next.timeLabel + (next.place.isEmpty ? "" : " · \(next.place)"))
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.55))
                        if next.travel != .none, next.travelMinutes > 0 {
                            Text("Leave by \(Item.clock(next.start - next.travelMinutes))")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(theme.accent)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 14)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var scheduleSection: some View {
        let items = store.items(on: today).filter { $0.kind != .action }
        if !items.isEmpty {
            SectionLabel(text: "TODAY")
            VStack(spacing: 0) {
                ForEach(items) { item in
                    Button { onOpenItem(item) } label: {
                        ItemRow(item: item)
                            .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var actionsSection: some View {
        let outstanding = store.outstandingActions()
        if !outstanding.isEmpty {
            SectionLabel(text: "ACTIONS")
            VStack(spacing: 8) {
                ForEach(outstanding) { item in
                    HStack(spacing: 12) {
                        Button { store.toggleDone(id: item.id) } label: {
                            RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(.white.opacity(0.5), lineWidth: 1.6)
                                .frame(width: 20, height: 20)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button { onOpenItem(item) } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title)
                                    .font(.system(size: 15))
                                if store.isOverdue(item) {
                                    Text("Overdue · \(overdueLabel(item.day))")
                                        .font(.system(size: 12.5))
                                        .foregroundStyle(Color(hex: "FF8A7A"))
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func overdueLabel(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM"
        return formatter.string(from: day)
    }

    @ViewBuilder
    private var countdownSection: some View {
        let pending = store.countdowns(from: today).prefix(3)
        if !pending.isEmpty {
            SectionLabel(text: "COUNTING DOWN")
            VStack(spacing: 8) {
                ForEach(Array(pending), id: \.item.id) { entry in
                    Button { onOpenItem(entry.item) } label: {
                        HStack {
                            Text(entry.item.title)
                                .font(.system(size: 15))
                            Spacer(minLength: 0)
                            Text(DayCount.long(entry.days))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(.white.opacity(0.55))
                        }
                        .padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loadWeather() async {
        guard let place = store.activeLocation else { return }
        let forecast = await WeatherService.shared.forecast(
            latitude: place.latitude,
            longitude: place.longitude
        )
        weather = forecast[WeatherService.dayKey(today)]
    }
}
