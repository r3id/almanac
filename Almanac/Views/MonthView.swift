import SwiftUI

struct MonthView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    @Binding var selected: Date
    var onOpenDay: (Date) -> Void
    var onOpenItem: (Item) -> Void
    var onAdd: () -> Void

    /// Months either side of this one that can be paged to.
    private let span = 60
    @State private var monthOffset = 0

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 0), count: 7)
    private let sidePadding: CGFloat = 14
    private let rowSpacing: CGFloat = 6
    private let markSpacing: CGFloat = 4
    private let markHeight: CGFloat = 3
    /// The strip under each date holding the mark and the kit bag. Named once
    /// and used by both the layout maths and the cell, because when the two
    /// disagreed every row was 4pt taller than budgeted — invisible in a
    /// five-row month, and 24pt of clipping in a six-row one.
    private let markRowHeight: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            let layout = layout(for: geometry.size)

            VStack(spacing: 0) {
                header
                weekdayRow(cellSize: layout.cell)

                // A paging TabView rather than a drag gesture: the swipe is the
                // system's, so it tracks the finger and never jumps on release.
                TabView(selection: $monthOffset) {
                    ForEach(-span...span, id: \.self) { offset in
                        grid(for: month(at: offset), cellSize: layout.cell)
                            .tag(offset)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(height: layout.grid)
                .onChange(of: monthOffset) { _, _ in syncSelection() }

                monthLegend
                selectedHeader
                list
            }
        }
        .background(Ink.base)
    }

    // MARK: Layout
    //
    // The grid takes a share of whatever height it's given rather than a fixed
    // number, so it fills a big phone instead of sitting squashed at the top
    // with dead space underneath. Cells are then sized from that share and from
    // the column width, whichever is tighter, and the frame is derived back from
    // the cell — so the six rows always fit exactly.

    private func layout(for size: CGSize) -> (cell: CGFloat, grid: CGFloat) {
        let column = (size.width - sidePadding * 2) / 7
        let share = min(max(size.height * 0.46, 300), 430)
        let rowFromHeight = (share - rowSpacing * 5) / 6
        let below = markSpacing + markRowHeight

        // Capped, and pulled well inside the column. Sized to the row alone the
        // discs grew until they touched, which turned the grid into a wall of
        // circles rather than dates that happen to be marked.
        let cell = max(
            min(min(rowFromHeight - below, column - 16), 38),
            30
        )
        let grid = (cell + below) * 6 + rowSpacing * 5
        return (cell, grid)
    }

    // MARK: Month maths

    private func month(at offset: Int) -> Date {
        let calendar = Calendar.current
        let base = calendar.date(from: calendar.dateComponents([.year, .month], from: .now)) ?? .now
        return calendar.date(byAdding: .month, value: offset, to: base) ?? base
    }

    private var visibleMonth: Date { month(at: monthOffset) }

    private func syncSelection() {
        let calendar = Calendar.current
        if calendar.isDate(.now, equalTo: visibleMonth, toGranularity: .month) {
            selected = Date.now.startOfDay
        } else {
            selected = visibleMonth.startOfDay
        }
    }

    // MARK: Header

    private var header: some View {
        // Centred against the title block as a whole. Baseline alignment lined
        // the pill's small text up with the 26pt title and dropped it to the
        // bottom of the row.
        HStack(alignment: .center, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(monthName.uppercased())
                    .font(.system(size: 26, weight: .medium))
                    .foregroundStyle(theme.accent)
                Text(visibleMonth.formatted(.dateTime.year()))
                    .font(.system(size: 26, weight: .ultraLight))
                    .foregroundStyle(theme.accent.opacity(0.55))
            }

            Spacer()

            GlassGroup {
                if monthOffset != 0 {
                    PillButton(title: "TODAY") {
                        withAnimation(.easeOut(duration: 0.25)) { monthOffset = 0 }
                    }
                    .transition(.opacity)
                }
                PillButton(title: "ADD", action: onAdd)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 44)
        .padding(.bottom, 22)
        .animation(.easeOut(duration: 0.2), value: monthOffset)
    }

    private var monthName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "LLLL"
        return formatter.string(from: visibleMonth)
    }

    // MARK: Grid

    private func weekdayRow(cellSize: CGFloat) -> some View {
        LazyVGrid(columns: columns, spacing: 0) {
            ForEach(Array(["M", "T", "W", "T", "F", "S", "S"].enumerated()), id: \.offset) { _, symbol in
                Text(symbol)
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.5)
                    .foregroundStyle(.white.opacity(0.35))
            }
        }
        .padding(.horizontal, sidePadding)
        .padding(.bottom, 10)
    }

    private func grid(for month: Date, cellSize: CGFloat) -> some View {
        LazyVGrid(columns: columns, spacing: rowSpacing) {
            ForEach(days(in: month), id: \.self) { day in
                dayCell(day, in: month, cellSize: cellSize)
            }
        }
        .padding(.horizontal, sidePadding)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func days(in month: Date) -> [Date] {
        let calendar = Calendar.current
        guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: month))
        else { return [] }
        // Monday-first.
        let lead = (calendar.component(.weekday, from: first) + 5) % 7
        let start = first.adding(days: -lead)

        // Only the weeks this month occupies. A fixed 42 cells meant September
        // 2026 drew a whole extra row of October — dates from the wrong month,
        // heat circles and all.
        let length = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let weeks = Int((Double(lead + length) / 7).rounded(.up))
        return (0..<(weeks * 7)).map { start.adding(days: $0) }
    }

    private func dayCell(_ day: Date, in month: Date, cellSize: CGFloat) -> some View {
        let count = store.count(on: day)
        let isToday = day.isSameDay(as: .now)
        let isSelected = day.isSameDay(as: selected)
        let inMonth = Calendar.current.isDate(day, equalTo: month, toGranularity: .month)
        let mark = store.marks(on: day).first
        // Kit days earn a mark of their own — forgetting the bag is the thing
        // the calendar is meant to prevent.
        let needsKit = !store.kitNeeded(on: day).isEmpty
        let offDuty = store.workWeek.isHighlighted && !store.isWorkday(day)

        return Button {
            if isSelected {
                onOpenDay(day)
            } else {
                withAnimation(.easeOut(duration: 0.12)) { selected = day }
            }
        } label: {
            VStack(spacing: markSpacing) {
                ZStack {
                    // Only days with something on get a disc. A grey circle on
                    // every empty weekend was most of the clutter.
                    if count > 0 || isToday {
                        Circle()
                            .fill(isToday ? Color.white : theme.accent.opacity(fillOpacity(count)))
                    }
                    if isSelected && !isToday {
                        Circle().strokeBorder(.white, lineWidth: 1.6)
                    }
                    Text(dayNumber(day))
                        .font(.system(size: min(cellSize * 0.4, 17), weight: isToday ? .semibold : .regular))
                        .foregroundStyle(numberColour(isToday: isToday, inMonth: inMonth, offDuty: offDuty))
                }
                .frame(width: cellSize, height: cellSize)

                HStack(spacing: 3) {
                    if let mark {
                        Capsule()
                            .fill(mark.kind.tint)
                            .frame(
                                width: needsKit ? cellSize * 0.26 : cellSize * 0.44,
                                height: markHeight
                            )
                    }
                    if needsKit {
                        Image(systemName: "bag.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(theme.accent)
                    }
                }
                .frame(height: markRowHeight)
                .opacity(inMonth ? 1 : 0.3)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Lighter than before at the bottom end: one event shouldn't look the same
    /// as four, and a nearly-solid disc for a single item was drowning the date.
    private func fillOpacity(_ count: Int) -> Double {
        count == 0 ? 0 : min(0.18 + Double(count) * 0.15, 0.78)
    }

    private func dayNumber(_ day: Date) -> String {
        String(Calendar.current.component(.day, from: day))
    }

    private func numberColour(isToday: Bool, inMonth: Bool, offDuty: Bool) -> Color {
        if isToday { return .black }
        guard inMonth else { return .white.opacity(0.18) }
        return .white.opacity(offDuty ? 0.5 : 0.95)
    }

    // MARK: Legend

    private var monthLegend: some View {
        let visible = uniqueMarks
        return Group {
            if !visible.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 14) {
                        ForEach(visible) { mark in
                            HStack(spacing: 6) {
                                Capsule()
                                    .fill(mark.kind.tint)
                                    .frame(width: 14, height: 7)
                                Text(store.label(for: mark))
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.5))
                                    .lineLimit(1)
                                    .fixedSize()
                            }
                        }
                    }
                    .padding(.horizontal, 22)
                }
                .scrollIndicators(.hidden)
                .padding(.top, 14)
            }
        }
    }

    private var uniqueMarks: [DayMark] {
        var seen = Set<UUID>()
        var result: [DayMark] = []
        for day in days(in: visibleMonth)
        where Calendar.current.isDate(day, equalTo: visibleMonth, toGranularity: .month) {
            for mark in store.marks(on: day) where !seen.contains(mark.id) {
                seen.insert(mark.id)
                result.append(mark)
            }
        }
        return result
    }

    // MARK: Selected day

    private var selectedHeader: some View {
        HStack(alignment: .top) {
            // The whole heading opens the day, not just the chevron.
            Button { onOpenDay(selected) } label: {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 7) {
                        Text(selectedTitle)
                            .font(.system(size: 20, weight: .medium))
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.3))
                    }
                    Text(selected.relativeLabel)
                        .font(.system(size: 11))
                        .tracking(1.6)
                        .foregroundStyle(.white.opacity(0.4))

                    // Their own wrapping row. Sharing a line with the relative
                    // label meant two marks on a day like Christmas ran into it
                    // and truncated mid-word.
                    let marks = store.marks(on: selected)
                    if !marks.isEmpty {
                        FlowRow(spacing: 6) {
                            ForEach(marks) { mark in
                                HStack(spacing: 5) {
                                    Capsule()
                                        .fill(mark.kind.tint)
                                        .frame(width: 12, height: 6)
                                    Text(store.label(for: mark).uppercased())
                                        .font(.system(size: 10, weight: .medium))
                                        .tracking(1.1)
                                        .foregroundStyle(.white.opacity(0.6))
                                }
                            }
                        }
                        .padding(.top, 3)
                    }
                    ForEach(store.schoolCountdowns(on: selected)) { countdown in
                        Text(countdown.schoolName.map { "\($0) · \(countdown.text)" } ?? countdown.text)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.5))
                            .padding(.top, 1)
                    }
                }
            }
            .buttonStyle(.plain)

            Spacer()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
        .padding(.top, 22)
    }

    private var selectedTitle: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE MMM d"
        return formatter.string(from: selected).uppercased()
    }

    private var list: some View {
        ScrollView {
            let items = store.items(on: selected)
            if items.isEmpty {
                Button(action: onAdd) {
                    HStack(spacing: 10) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .light))
                        Text("Nothing planned")
                            .font(.system(size: 15, weight: .light))
                    }
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
                }
                .buttonStyle(.plain)
            } else {
                VStack(spacing: 4) {
                    ForEach(items) { item in
                        Button { onOpenItem(item) } label: {
                            ItemRow(item: item)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.top, 12)
            }
        }
        .scrollIndicators(.hidden)
        .safeAreaPadding(.bottom, 70)
        .foregroundStyle(.white)
        .padding(.horizontal, 22)
    }
}
