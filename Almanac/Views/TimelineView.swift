import SwiftUI

struct TimelineView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var onOpenDay: (Date) -> Void
    var onOpenItem: (Item) -> Void
    var onAdd: () -> Void

    /// Day offset from today of the row currently at the top. Binding it to the
    /// scroll position means the month header is derived rather than tracked —
    /// no geometry readers, no preference plumbing.
    @State private var topOffset: Int? = 0
    /// Tracked separately from `topOffset`, which only settles after a scroll
    /// ends — so the header used to sit on the old month the whole way down.
    @State private var headerOffset: Int = 0
    @State private var forecast: [String: DayWeather] = [:]

    private let range = -21...98
    /// Where the tracked row sits in the visible area — the foot of the top third.
    private static let restingAnchor = UnitPoint(x: 0, y: 0.32)
    private static let space = "timeline"
    /// Where the header reads the month from, in points below the top edge.
    private static let readingLine: CGFloat = 96

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(range, id: \.self) { offset in
                    dayRow(Date.now.startOfDay.adding(days: offset))
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: RowTopsKey.self,
                                    value: [offset: proxy.frame(in: .named(Self.space)).minY]
                                )
                            }
                        )
                }
            }
            .scrollTargetLayout()
        }
        // Anchored a third of the way down rather than at the very top. Landing
        // today at the top edge tucked it under the header and its fade, which
        // is the one row you never want hidden.
        .scrollPosition(id: $topOffset, anchor: Self.restingAnchor)
        .coordinateSpace(.named(Self.space))
        .onPreferenceChange(RowTopsKey.self) { tops in
            let next = TimelineView.month(from: tops, line: TimelineView.readingLine)
            Task { @MainActor in
                if let next, next != headerOffset { headerOffset = next }
            }
        }
        .scrollIndicators(.hidden)
        // Content runs under the status bar; the inset keeps the first row clear
        // of the header rather than a safe area doing it.
        .ignoresSafeArea(edges: .top)
        .safeAreaPadding(.top, 66)
        .safeAreaPadding(.bottom, 70)
        .overlay(alignment: .top) { header }
        .background(Ink.base)
        .task {
            guard let place = store.activeLocation else { return }
            forecast = await WeatherService.shared.forecast(
                latitude: place.latitude,
                longitude: place.longitude
            )
        }
    }

    /// The month of the row at the anchor, which is the one your eye is on
    /// rather than whatever is scrolling out of view at the top.
    private var visibleMonth: Date {
        Date.now.startOfDay.adding(days: headerOffset)
    }

    /// The row crossing the reading line — the one your eye is on, rather than
    /// whatever is sliding out of view at the very top.
    nonisolated private static func month(from tops: [Int: CGFloat], line: CGFloat) -> Int? {
        let above = tops.filter { $0.value <= line }
        if let last = above.max(by: { $0.value < $1.value }) { return last.key }
        return tops.min(by: { $0.value < $1.value })?.key
    }

    // MARK: Header

    private var header: some View {
        ZStack(alignment: .top) {
            // Solid through the status bar and behind the text, then a long tail
            // that lets the bands surface gradually. A short fade reads as a
            // black bar with a soft edge; this reads as the content receding.
            LinearGradient(
                stops: [
                    .init(color: Ink.base, location: 0.00),
                    .init(color: Ink.base, location: 0.42),
                    .init(color: Ink.base.opacity(0.80), location: 0.60),
                    .init(color: Ink.base.opacity(0.42), location: 0.76),
                    .init(color: Ink.base.opacity(0.14), location: 0.89),
                    .init(color: Ink.base.opacity(0.00), location: 1.00)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 210)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)

            headerRow
        }
    }

    private var headerRow: some View {
        // Left-aligned rather than centred. Centred, the month sat behind the
        // buttons on a narrow phone and got clipped.
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(monthName.uppercased())
                    .font(.system(size: 15, weight: .medium))
                    .tracking(2.2)
                    .foregroundStyle(theme.accent)
                Text(yearName)
                    .font(.system(size: 15, weight: .ultraLight))
                    .foregroundStyle(theme.accent.opacity(0.6))
            }
            .lineLimit(1)

            Spacer(minLength: 8)

            GlassGroup {
                PillButton(title: "TODAY") {
                    withAnimation(.easeOut(duration: 0.25)) {
                        topOffset = 0
                        headerOffset = 0
                    }
                }
                PillButton(title: "ADD", action: onAdd)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 16)
        .animation(.easeOut(duration: 0.2), value: monthName)
    }

    private var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL"
        return formatter.string(from: visibleMonth)
    }

    private var yearName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy"
        return formatter.string(from: visibleMonth)
    }

    // MARK: Rows

    private func dayRow(_ day: Date) -> some View {
        let items = store.items(on: day)
        let isToday = day.isSameDay(as: .now)
        let isPast = day < Date.now.startOfDay
        let marks = store.marks(on: day)
        let offDuty = store.workWeek.isHighlighted && !store.isWorkday(day)

        return HStack(alignment: .top, spacing: 0) {
            Button { onOpenDay(day) } label: {
                VStack(spacing: 1) {
                    Text(shortWeekday(day))
                        .font(.system(size: 10, weight: .medium))
                        .tracking(1.4)
                        .foregroundStyle(isToday ? .black.opacity(0.55) : .white.opacity(0.45))
                    Text("\(Calendar.current.component(.day, from: day))")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(isToday ? .black : .white.opacity(isPast ? 0.4 : 1))
                    // A drawn tick rather than a printed dash — the one mark
                    // the app icon actually makes.
                    Capsule()
                        .fill(marks.first?.kind.tint ?? .clear)
                        .frame(width: 18, height: 7)
                        .padding(.top, 3)
                }
                .frame(width: 62)
                .padding(.top, 16)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(isToday ? Color.white : Ink.base)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 0) {
                // A fortnight of school holiday shouldn't print its name fourteen
                // times, so the label lands on the first day of the run only.
                ForEach(marks.filter { $0.isFirstVisibleDay(day) }) { mark in
                    markLabel(store.label(for: mark), tint: mark.kind.tint)
                }

                // Ranges get closed off as well as opened. A holiday's first day
                // was labelled but its last wasn't, so you could see when the
                // break began and never when it ran out.
                ForEach(marks.filter { $0.isLastVisibleDay(day) && !$0.isFirstVisibleDay(day) }) { mark in
                    markLabel("\(store.label(for: mark)) ends", tint: mark.kind.tint)
                }

                // On today, and on the days either side of a change. Repeating it
                // down every row would say the same thing a hundred times with a
                // different number.
                ForEach(store.schoolCountdowns(on: day)) { countdown in
                    if countdown.isTransition || day.isSameDay(as: .now) {
                        HStack(spacing: 7) {
                            Image(systemName: countdown.isBreak ? "backpack" : "graduationcap")
                                .font(.system(size: 9))
                            Text((countdown.schoolName.map { "\($0) · \(countdown.text)" } ?? countdown.text).uppercased())
                                .font(.system(size: 9.5, weight: .semibold))
                                .tracking(1.1)
                                .lineLimit(1)
                        }
                        .opacity(0.8)
                        .padding(.bottom, 6)
                    }
                }

                if items.isEmpty {
                    Color.clear.frame(height: 30)
                } else {
                    ForEach(items) { item in
                        Button { onOpenItem(item) } label: {
                            ItemRow(item: item, showsSubtitle: item.kind != .action)
                                .padding(.vertical, 5)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.leading, 16)
            .padding(.trailing, 10)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 78, alignment: .topLeading)
            .overlay(alignment: .topTrailing) { forecastBadge(day) }
            // Today takes more of the accent rather than a different colour, so
            // it stands out without breaking the run of paper.
            .background(isToday ? theme.paper(0.5) : bandColor(day))
            // Days off pull back a shade instead of turning grey, so the week
            // still reads as one continuous run of colour.
            .overlay(Color.black.opacity(offDuty ? 0.045 : 0))
            .foregroundStyle(theme.onPaper)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func markLabel(_ text: String, tint: Color) -> some View {
        HStack(spacing: 7) {
            Capsule()
                .fill(tint)
                .frame(width: 16, height: 7)
            Text(text.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(1.1)
                .lineLimit(1)
        }
        .opacity(0.85)
        .padding(.bottom, 6)
    }

    /// A glance-level forecast at the trailing edge — icon and the day's range,
    /// nothing more. Only the sixteen days the service covers have one.
    @ViewBuilder
    private func forecastBadge(_ day: Date) -> some View {
        if let weather = forecast[WeatherService.dayKey(day)] {
            HStack(spacing: 5) {
                WeatherIcon(kind: weather.condition.icon, size: 20)
                Text("\(weather.low)–\(weather.high)°")
                    .font(.system(size: 11, weight: .medium))
            }
            .opacity(0.6)
            .foregroundStyle(theme.onPaper)
            .padding(.top, 15)
            .padding(.trailing, 14)
            .allowsHitTesting(false)
        }
    }

    /// Weekdays alternate so consecutive days stay apart; the weekend is a
    /// single flatter shade so Saturday and Sunday read as one block.
    ///
    /// The alternation keys off the weekday rather than the date, so a given day
    /// is the same shade every week. Alternating by date number meant the
    /// pattern slid by one each month and the weekend came out as two tones.
    private func bandColor(_ day: Date) -> Color {
        let weekday = Calendar.current.component(.weekday, from: day)
        // Weekends sit a shade deeper so they read as one block; weekdays
        // alternate faintly, keyed to the weekday so the rhythm is the same
        // every week rather than sliding by one each month.
        guard weekday != 1, weekday != 7 else {
            return theme.paper(0.34)
        }
        return weekday.isMultiple(of: 2)
            ? theme.paper(0.17)
            : theme.paper(0.23)
    }

    private func shortWeekday(_ day: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE"
        return formatter.string(from: day).uppercased()
    }
}


/// Each visible row reports where its top sits, so the header can name the month
/// actually on screen. Only rendered rows report, so the dictionary stays small.
private struct RowTopsKey: PreferenceKey {
    static let defaultValue: [Int: CGFloat] = [:]

    static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
        value.merge(nextValue()) { _, new in new }
    }
}
