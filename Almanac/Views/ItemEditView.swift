import SwiftUI
import MapKit

struct ItemEditView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State var draft: Item
    let isNew: Bool

    @State private var startDate: Date = .now
    @State private var endDate: Date = .now
    /// The length of the event, which is what actually stays fixed when the
    /// start moves. Shifting the end by a delta instead meant opening the editor
    /// — which sets the start — nudged the end by however far the seeded start
    /// happened to be from the current time.
    @State private var duration: TimeInterval = 3600
    /// The date the editor opened on, so moving a repeating event can be told
    /// apart from simply editing one of its occurrences.
    @State private var openedOn: Date = .now

    @State private var placeQuery = ""
    @State private var search = PlaceSearch()
    @State private var isResolving = false

    @State private var routedMinutes: Int?
    @State private var isRouting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Type", selection: $draft.kind) {
                        ForEach(ItemKind.allCases, id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField(draft.kind == .birthday ? "Whose birthday" : "What", text: $draft.title)

                    DatePicker(
                        draft.kind == .birthday ? "Date of birth" : "Day",
                        selection: $draft.day,
                        displayedComponents: .date
                    )

                    if draft.kind == .birthday {
                        Toggle("Show age", isOn: $draft.showsAge)
                    }
                }

                if draft.kind == .birthday {
                    Section {
                        Text("Repeats every year, all day.")
                            .foregroundStyle(.secondary)
                    } footer: {
                        Text(draft.showsAge
                             ? "The age comes from the year above, so it stays right on its own. Turn off Show age if the year isn't known."
                             : "Only the day and month are used. No age is shown.")
                    }
                }

                if draft.kind == .event {
                    Section {
                        Toggle("All day", isOn: $draft.isAllDay)
                        if !draft.isAllDay {
                            DatePicker("Starts", selection: $startDate, displayedComponents: .hourAndMinute)
                                // Moving the start carries the end with it, so an
                                // hour-long thing stays an hour long. Every other
                                // calendar does this and it's jarring when one doesn't.
                                // Recomputed from the duration rather than
                                // nudged, so it lands in the same place however
                                // many times this runs.
                                .onChange(of: startDate) { _, newValue in
                                    endDate = newValue.addingTimeInterval(duration)
                                }

                            DatePicker("Ends", selection: $endDate, displayedComponents: .hourAndMinute)
                                // Setting the end is what defines the length;
                                // from then on the start carries it.
                                .onChange(of: endDate) { _, newValue in
                                    duration = ItemEditView.span(from: startDate, to: newValue)
                                }

                            // An end earlier than the start reads as the next
                            // morning, which is what a late event usually is.
                            // Snapping it back to the start made midnight
                            // impossible to express.
                            if crossesMidnight {
                                Text("Ends the next day")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    placeSection
                    travelSection
                }

                if draft.kind == .event {
                    Section {
                        Picker("Repeat", selection: $draft.recurrence.frequency) {
                            ForEach(Recurrence.Frequency.allCases, id: \.self) { frequency in
                                Text(frequency.label).tag(frequency)
                            }
                        }

                        if draft.recurrence.repeats {
                            Toggle("Ends", isOn: Binding(
                                get: { draft.recurrence.until != nil },
                                set: { on in
                                    draft.recurrence.until = on
                                        ? draft.recurrence.defaultEnd(from: draft.day)
                                        : nil
                                }
                            ))

                            if draft.recurrence.until != nil {
                                DatePicker(
                                    "Last day",
                                    selection: Binding(
                                        get: { draft.recurrence.until ?? seriesStart },
                                        set: { draft.recurrence.until = $0 }
                                    ),
                                    // Bounded by where the series began, not the
                                    // occurrence you happened to open from. Using
                                    // the latter made every date before today's
                                    // occurrence unreachable — so shortening a
                                    // series from a later date was impossible.
                                    in: seriesStart...,
                                    displayedComponents: .date
                                )

                                // Spelling out the count makes a wrong year
                                // obvious: "52 times" for something meant to run
                                // till Christmas doesn't read as a typo, it reads
                                // as a mistake.
                                if let count = draft.recurrence.occurrenceCount(from: seriesStart) {
                                    Text(count >= 400
                                         ? "400+ times"
                                         : "\(count) time\(count == 1 ? "" : "s") in total")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        Picker("If it lands on a non-working day", selection: $draft.recurrence.adjustment) {
                            ForEach(Recurrence.DateAdjustment.allCases, id: \.self) { rule in
                                Text(rule.label).tag(rule)
                            }
                        }
                    } footer: {
                        if draft.recurrence.adjustment.adjusts {
                            Text("Weekends and bank holidays move it to the nearest working day. The date itself doesn't change, so payday stays the 25th and lands on the Friday when the 25th is a Sunday.")
                        } else if draft.isOccurrence {
                            Text("This is one of a repeating series. Changes apply to the whole series.")
                        } else if draft.recurrence.repeats {
                            Text("Repeats from the day above. Leave \"Ends\" off to carry on indefinitely.")
                        }
                    }

                    if let nominal = draft.nominalDay, draft.recurrence.repeats {
                        Section {
                            DatePicker(
                                "This one falls on",
                                selection: Binding(
                                    get: { draft.movedOccurrences[nominal.dayKey] ?? draft.day },
                                    set: { draft.movedOccurrences[nominal.dayKey] = $0.startOfDay }
                                ),
                                displayedComponents: .date
                            )

                            if draft.movedOccurrences[nominal.dayKey] != nil {
                                Button("Put it back") {
                                    draft.movedOccurrences.removeValue(forKey: nominal.dayKey)
                                }
                            }

                            Button("Skip this one", role: .destructive) {
                                draft.skippedOccurrences.insert(nominal.dayKey)
                                draft.movedOccurrences.removeValue(forKey: nominal.dayKey)
                                store.save(draft)
                                dismiss()
                            }
                        } header: {
                            Text("Just this one")
                        } footer: {
                            Text("Moves or drops this occurrence only — a week off swimming, or December's pay landing early. The rest of the series carries on around it.")
                        }
                    }

                    // Skipped and moved dates can't be reached from the calendar
                    // any more, so the only way back is a list of them here.
                    if !draft.exceptions.isEmpty {
                        Section {
                            ForEach(draft.exceptions, id: \.key) { exception in
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(exceptionDate(exception.date))
                                        Text(exception.movedTo == nil
                                             ? "Skipped"
                                             : "Moved to \(exceptionDate(exception.movedTo!))")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Button("Restore") {
                                        draft.skippedOccurrences.remove(exception.key)
                                        draft.movedOccurrences.removeValue(forKey: exception.key)
                                    }
                                    .font(.footnote)
                                    .buttonStyle(.borderless)
                                }
                            }
                        } header: {
                            Text("Changed dates")
                        }
                    }

                }

                Section {
                    let options = draft.alertsFromMorning ? AlertOption.allDay : AlertOption.timed
                    ForEach(options, id: \.self) { minutes in
                        Button {
                            if let index = draft.alerts.firstIndex(of: minutes) {
                                draft.alerts.remove(at: index)
                            } else {
                                draft.alerts.append(minutes)
                                draft.alerts.sort()
                            }
                        } label: {
                            HStack {
                                Text(AlertOption.label(minutes, fromMorning: draft.alertsFromMorning))
                                Spacer()
                                if draft.alerts.contains(minutes) {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(theme.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                } header: {
                    Text("Alerts")
                } footer: {
                    Text(draft.recurrence.repeats
                         ? "Set for the next dozen occurrences and topped up each time the app opens — iOS only holds 64 pending notifications at once."
                         : "Pick as many as you like.")
                }

                Section {
                    TextField(
                        draft.kind == .action ? "Details, or a list" : "Anything worth remembering",
                        text: $draft.notes,
                        axis: .vertical
                    )
                    .lineLimit(3...10)
                } header: {
                    Text("Notes")
                } footer: {
                    if draft.kind == .action {
                        Text("Room for the detail an action needs — what to buy, who to ring, what to bring.")
                    }
                }

                Section {
                    TextField(
                        draft.kind == .event ? "Link, e.g. a Teams or Meet URL" : "Link",
                        text: $draft.url
                    )
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                } footer: {
                    Text(draft.kind == .event
                         ? "Shown as a Join button, for calls that happen somewhere other than a place."
                         : "Shown as a button on the item.")
                }

                Section {
                    Toggle("Count down to this", isOn: $draft.countsDown)
                } footer: {
                    Text("Pins it to the day view with the days remaining — a trip, a birthday, anything you're waiting for.")
                }

                Section("Calendar") {
                    Picker("Calendar", selection: $draft.calendarID) {
                        ForEach(store.calendars) { tag in
                            HStack {
                                Circle()
                                    .fill(Color(hex: tag.hex))
                                    .frame(width: 12, height: 12)
                                Text(tag.name)
                            }
                            .tag(tag.id)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                if !isNew {
                    Section {
                        Button("Delete", role: .destructive) {
                            store.delete(id: draft.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New" : "Edit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { commit() }
                        .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .tint(theme.accent)
        }
        .onAppear(perform: seedPickers)
        .task(id: placeQuery) {
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            search.update(query: placeQuery)
        }
    }

    // MARK: Place

    @ViewBuilder
    private var placeSection: some View {
        Section {
            if draft.hasResolvedPlace {
                // Already pinned. Show what was picked rather than a search box.
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "mappin.circle.fill")
                        .foregroundStyle(theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(draft.place)
                        if !draft.placeAddress.isEmpty {
                            Text(draft.placeAddress)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Change") { clearPlace() }
                        .font(.footnote)
                }
            } else {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search for a place", text: $placeQuery)
                        .autocorrectionDisabled()
                    if search.isSearching || isResolving { ProgressView() }
                }

                ForEach(search.suggestions, id: \.self) { suggestion in
                    Button {
                        Task { await pick(suggestion) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(suggestion.title)
                            if !suggestion.subtitle.isEmpty {
                                Text(suggestion.subtitle)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }

                if !placeQuery.isEmpty && search.suggestions.isEmpty && !search.isSearching {
                    Button {
                        draft.place = placeQuery
                        draft.placeAddress = ""
                        placeQuery = ""
                        search.clear()
                    } label: {
                        Label("Use \"\(placeQuery)\" as plain text", systemImage: "text.cursor")
                            .font(.footnote)
                    }
                } else if !draft.place.isEmpty && placeQuery.isEmpty {
                    HStack {
                        Text(draft.place)
                        Spacer()
                        Text("not pinned")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Where")
        } footer: {
            Text(draft.hasResolvedPlace
                 ? "Pinned, so travel time is looked up rather than estimated."
                 : "Pick a result to pin the location. Plain text still works, but travel time falls back to your estimate.")
        }
    }

    private func pick(_ suggestion: MKLocalSearchCompletion) async {
        isResolving = true
        defer { isResolving = false }

        guard let place = await search.resolve(suggestion) else {
            draft.place = suggestion.title
            draft.placeAddress = suggestion.subtitle
            return
        }
        draft.place = place.name
        draft.placeAddress = place.address
        draft.placeLatitude = place.latitude
        draft.placeLongitude = place.longitude
        placeQuery = ""
        search.clear()
        await refreshRoute()
    }

    private func clearPlace() {
        draft.place = ""
        draft.placeAddress = ""
        draft.placeLatitude = nil
        draft.placeLongitude = nil
        routedMinutes = nil
        placeQuery = ""
        search.clear()
    }

    // MARK: Travel

    @ViewBuilder
    private var travelSection: some View {
        Section {
            Picker("Getting there", selection: $draft.travel) {
                ForEach(TravelMode.allCases, id: \.self) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .onChange(of: draft.travel) { _, _ in
                Task { await refreshRoute() }
            }

            if draft.travel != .none {
                if isRouting {
                    HStack {
                        Text("Checking route…")
                        Spacer()
                        ProgressView()
                    }
                } else if let routedMinutes {
                    HStack {
                        Text("Travel time")
                        Spacer()
                        Text(durationLabel(routedMinutes))
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Leave by")
                        Spacer()
                        Text(Item.clock(currentStartMinutes - routedMinutes))
                            .foregroundStyle(theme.accent)
                    }
                } else {
                    Stepper(
                        "Estimate: \(draft.travelMinutes) min",
                        value: $draft.travelMinutes,
                        in: 0...600,
                        step: 5
                    )
                }
            }
        } footer: {
            if draft.travel == .cycle {
                Text("MapKit has no cycling directions, so cycling always uses your estimate.")
            } else if draft.travel != .none && routedMinutes == nil {
                Text("Pin a location above to have this looked up instead. Your estimate is the offline fallback either way.")
            }
        }
    }


    private func exceptionDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM yyyy"
        return formatter.string(from: date)
    }

    private var currentStartMinutes: Int {
        let calendar = Calendar.current
        return calendar.component(.hour, from: startDate) * 60
            + calendar.component(.minute, from: startDate)
    }

    private func durationLabel(_ minutes: Int) -> String {
        minutes >= 60 ? "\(minutes / 60)h \(minutes % 60)min" : "\(minutes) min"
    }

    private func refreshRoute() async {
        guard draft.hasResolvedPlace, draft.travel.supportsRouting else {
            routedMinutes = nil
            return
        }
        isRouting = true
        defer { isRouting = false }
        routedMinutes = await TravelService.shared.minutes(
            to: draft.routeQuery,
            latitude: draft.placeLatitude,
            longitude: draft.placeLongitude,
            mode: draft.travel
        )
    }

    /// Seconds from start to end, treating an earlier end as the next day and
    /// never returning a whole day or more.
    nonisolated static func span(from start: Date, to end: Date) -> TimeInterval {
        let calendar = Calendar.current
        let startMinutes = calendar.component(.hour, from: start) * 60
            + calendar.component(.minute, from: start)
        let endMinutes = calendar.component(.hour, from: end) * 60
            + calendar.component(.minute, from: end)
        let minutes = endMinutes <= startMinutes
            ? endMinutes + 24 * 60 - startMinutes
            : endMinutes - startMinutes
        return TimeInterval(minutes * 60)
    }

    /// Where the repeat actually starts. Editing a repeating event opens on the
    /// occurrence you tapped, so `draft.day` is that date rather than the first.
    private var seriesStart: Date {
        (draft.seriesStart ?? draft.day).startOfDay
    }

    private var crossesMidnight: Bool {
        let calendar = Calendar.current
        let start = calendar.component(.hour, from: startDate) * 60
            + calendar.component(.minute, from: startDate)
        let end = calendar.component(.hour, from: endDate) * 60
            + calendar.component(.minute, from: endDate)
        return end <= start
    }

    // MARK: Saving

    private func seedPickers() {
        let calendar = Calendar.current
        startDate = calendar.date(bySettingHour: draft.start / 60, minute: draft.start % 60, second: 0, of: draft.day) ?? draft.day
        let end = draft.end ?? (draft.start + 60)
        // Wrapped for the picker, which only shows a time of day.
        let endOfDay = end % (24 * 60)
        endDate = calendar.date(bySettingHour: endOfDay / 60, minute: endOfDay % 60, second: 0, of: draft.day) ?? draft.day
        duration = TimeInterval(max(end - draft.start, 15) * 60)
        openedOn = draft.day.startOfDay
        Task { await refreshRoute() }
    }

    private func commit() {
        let calendar = Calendar.current
        var item = draft
        item.title = draft.title.trimmingCharacters(in: .whitespaces)
        item.day = draft.day.startOfDay

        // Editing a repeat opens on the occurrence you tapped, so saving used to
        // write that date back as the series start — open December's instance,
        // change the title, and the whole series jumped to December. The series
        // keeps its own start, shifted only by however far the date was actually
        // moved in the editor.
        if draft.isOccurrence {
            let moved = DayCount.between(openedOn, and: draft.day)
            item.day = seriesStart.adding(days: moved)
            item.seriesStart = nil
            item.nominalDay = nil
        }

        if draft.kind == .birthday {
            // A birthday is an all-day yearly repeat by definition; setting it
            // any other way would just be a chance to set it wrong.
            item.isAllDay = true
            item.end = nil
            item.place = ""
            item.placeAddress = ""
            item.placeLatitude = nil
            item.placeLongitude = nil
            item.travel = .none
            item.travelMinutes = 0
            item.recurrence.frequency = .yearly
            item.recurrence.adjustment = .keep
            item.recurrence.until = nil
        } else if draft.kind == .action {
            item.isAllDay = false
            item.place = ""
            item.placeAddress = ""
            item.placeLatitude = nil
            item.placeLongitude = nil
            item.travel = .none
            item.travelMinutes = 0
            item.end = nil
        } else if draft.isAllDay {
            item.end = nil
        } else {
            item.start = calendar.component(.hour, from: startDate) * 60
                + calendar.component(.minute, from: startDate)
            var end = calendar.component(.hour, from: endDate) * 60
                + calendar.component(.minute, from: endDate)
            // Stored as minutes from the start day, so a midnight finish is
            // 1440 rather than a second date to keep in step.
            if end <= item.start { end += 24 * 60 }
            item.end = end
        }

        store.save(item)
        dismiss()
    }
}
