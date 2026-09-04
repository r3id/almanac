import SwiftUI
import CloudKit

struct SettingsView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    var body: some View {
        @Bindable var store = store

        return NavigationStack {
            Form {
                Section {
                    row("You", "person", YouSettings())
                    row("Location", "location", LocationSettings())
                    row("Calendars", "circle.grid.2x2", CalendarSettings())
                    row("School", "graduationcap", SchoolSettings())
                    row("Appearance", "paintpalette", AppearanceSettings())
                    row("Sharing", "person.2", SharingSettings())
                }


                Section {
                    Toggle("Show my iOS calendars", isOn: $store.showSystemCalendars)
                } footer: {
                    Text("Mirrors events from Calendar.app alongside your own. Read-only — Almanac never edits them.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaPadding(.bottom, 70)
            .tint(theme.accent)
        }
    }

    private func row<Destination: View>(
        _ title: String, _ symbol: String, _ destination: Destination
    ) -> some View {
        NavigationLink {
            destination
                .environment(store)
                .environment(\.theme, theme)
        } label: {
            Label(title, systemImage: symbol)
        }
    }
}

// MARK: - You

struct YouSettings: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var store = store

        return Form {
            Section {
                TextField("Name", text: $store.userName)
            } header: {
                Text("Name")
            } footer: {
                Text("Used in the greeting. Leave it empty for a plain \"Good evening\".")
            }

            Section {
                Toggle("Count down to my birthday", isOn: Binding(
                    get: { store.birthday != nil },
                    set: { on in
                        store.birthday = on
                            ? (store.birthday ?? Date.now.startOfDay)
                            : nil
                    }
                ))

                if store.birthday != nil {
                    DatePicker(
                        "Date of birth",
                        selection: Binding(
                            get: { store.birthday ?? Date.now.startOfDay },
                            set: { store.birthday = $0.startOfDay }
                        ),
                        displayedComponents: .date
                    )
                }
            } header: {
                Text("Birthday")
            } footer: {
                Text("Give the year and it'll know the age to wish you. Set it to this year if you'd rather it didn't.")
            }
        }
        .navigationTitle("You")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaPadding(.bottom, 70)
        .tint(theme.accent)
    }
}

// MARK: - Location

struct LocationSettings: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    @State private var query = ""
    @State private var results: [GeocodedPlace] = []
    @State private var isSearching = false
    @State private var message = ""
    @State private var isLocating = false
    @State private var isTesting = false
    @State private var forecastResult: String?

    var body: some View {
        @Bindable var store = store

        return Form {
            Section {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search for a town or city", text: $query)
                        .autocorrectionDisabled()
                    if isSearching {
                        ProgressView()
                    } else if !query.isEmpty {
                        Button {
                            query = ""
                            results = []
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }

                ForEach(results) { place in
                    Button {
                        store.homeName = place.name
                        store.homeLatitude = place.latitude
                        store.homeLongitude = place.longitude
                        query = ""
                        results = []
                        message = "Home set to \(place.name)."
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(place.name)
                            if !place.detail.isEmpty {
                                Text(place.detail)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }

                Button {
                    Task { await useCurrentAsHome() }
                } label: {
                    HStack {
                        Label("Use where I am now", systemImage: "location")
                        Spacer()
                        if isLocating { ProgressView() }
                    }
                }

                if store.hasHome {
                    HStack {
                        Text("Home")
                        Spacer()
                        Text(store.homeName).foregroundStyle(.secondary)
                    }

                    Button {
                        Task { await testForecast() }
                    } label: {
                        HStack {
                            Label("Test the forecast", systemImage: "cloud.sun")
                            Spacer()
                            if isTesting { ProgressView() }
                        }
                    }

                    if let forecastResult {
                        Text(forecastResult)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Home")
            } footer: {
                Text("Where the forecast and daylight figures come from when you're not following your current location.")
            }

            Section {
                Toggle("Follow my current location", isOn: $store.useCurrentLocation)
                    .onChange(of: store.useCurrentLocation) { _, _ in
                        Task { await store.refreshCurrentLocation() }
                    }

                if store.useCurrentLocation {
                    if !LocationService.shared.hasUsageDescription {
                        Text("NSLocationWhenInUseUsageDescription is missing from Info.plist, so iOS won't show the permission prompt.")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    } else if LocationService.shared.isDenied {
                        Text("Location is switched off for Almanac. Settings › Privacy › Location Services.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else if !store.currentName.isEmpty {
                        HStack {
                            Text("Now in")
                            Spacer()
                            Text(store.currentName).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Locating…").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Current location")
            } footer: {
                Text("Weather and daylight follow you, falling back to home if there's no fix. Travel times always use where you are, whatever this is set to.")
            }
        }
        .navigationTitle("Location")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaPadding(.bottom, 70)
        .tint(theme.accent)
        .onAppear { query = "" }
        .task(id: query) {
            let trimmed = query.trimmingCharacters(in: .whitespaces)
            guard trimmed.count >= 2 else {
                results = []
                return
            }
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }

            isSearching = true
            defer { isSearching = false }
            do {
                results = try await WeatherService.shared.search(place: trimmed)
                message = results.isEmpty ? "No matches. Try a nearby larger town." : ""
            } catch {
                results = []
                message = "Search is unavailable right now."
            }
        }
    }

    /// Fetches once and reports what came back, so a broken forecast can be
    /// diagnosed from inside the app rather than guessed at.
    private func testForecast() async {
        guard let place = store.activeLocation else {
            forecastResult = "No location set."
            return
        }
        isTesting = true
        defer { isTesting = false }

        let days = await WeatherService.shared.forecast(
            latitude: place.latitude,
            longitude: place.longitude
        )
        if days.isEmpty {
            forecastResult = await WeatherService.shared.lastFailure ?? "Nothing came back."
        } else {
            forecastResult = "Working — \(days.count) days for \(place.name)."
        }
    }

    private func useCurrentAsHome() async {
        isLocating = true
        defer { isLocating = false }

        guard LocationService.shared.hasUsageDescription else {
            message = "Add NSLocationWhenInUseUsageDescription to Info.plist first."
            return
        }
        guard !LocationService.shared.isDenied else {
            message = "Location is switched off for Almanac."
            return
        }
        guard let place = await LocationService.shared.currentPlace() else {
            message = "Couldn't get a fix. Search for your town instead."
            return
        }
        store.homeName = place.name
        store.homeLatitude = place.latitude
        store.homeLongitude = place.longitude
        message = "Home set to \(place.name)."
    }
}

// MARK: - Calendars

struct CalendarSettings: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    @State private var editing: CalendarTag?

    var body: some View {
        Form {
            Section {
                ForEach(store.calendars) { tag in
                    Button {
                        editing = tag
                    } label: {
                        HStack(spacing: 14) {
                            Circle()
                                .fill(Color(hex: tag.hex))
                                .frame(width: 22, height: 22)
                            Text(tag.name)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                .onDelete { offsets in
                    for index in offsets {
                        store.deleteCalendar(id: store.calendars[index].id)
                    }
                }

                Button {
                    editing = CalendarTag(id: UUID().uuidString, name: "", hex: "6FA8A0")
                } label: {
                    Label("Add a calendar", systemImage: "plus")
                }
            } footer: {
                Text("Your names, your colours. Deleting one moves anything using it to the first calendar in the list rather than leaving events pointing at nothing.")
            }
        }
        .navigationTitle("Calendars")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaPadding(.bottom, 70)
        .tint(theme.accent)
        .sheet(item: $editing) { tag in
            CalendarEditView(draft: tag, isNew: !store.calendars.contains { $0.id == tag.id })
                .environment(store)
                .environment(\.theme, theme)
        }
    }
}

struct CalendarEditView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State var draft: CalendarTag
    let isNew: Bool

    @State private var colour: Color = .white

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name)
                    ColorPicker("Colour", selection: $colour, supportsOpacity: false)
                }

                Section {
                    HStack(spacing: 11) {
                        Capsule()
                            .fill(colour)
                            .frame(width: 4, height: 34)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(draft.name.isEmpty ? "Untitled" : draft.name)
                                .font(.system(size: 15.5))
                            Text("10:00 AM → 11:00 AM")
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    Text("Preview")
                }
            }
            .navigationTitle(isNew ? "New calendar" : "Edit calendar")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.hex = colour.hexString
                        store.saveCalendar(draft)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .tint(theme.accent)
        }
        .onAppear { colour = Color(hex: draft.hex) }
    }
}

// MARK: - School

struct SchoolSettings: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    @State private var route: Route?

    private enum Route: Identifiable {
        case term(SchoolTerm)
        case mark(DayMark)
        case school(School)

        var id: String {
            switch self {
            case .term(let value):   return "term-\(value.id)"
            case .mark(let value):   return "mark-\(value.id)"
            case .school(let value): return "school-\(value.id)"
            }
        }
    }

    var body: some View {
        @Bindable var store = store

        return Form {
            // A section per school. With one school its header reads "Terms" and
            // nothing mentions schools at all — the concept only surfaces once
            // there's a second child with different dates to keep apart.
            ForEach(store.schools) { school in
                schoolSection(school)
            }

            Section {
                Button {
                    route = .school(School())
                } label: {
                    Label(
                        store.schools.isEmpty ? "Add school dates" : "Add another school",
                        systemImage: "plus"
                    )
                }
            } footer: {
                Text(store.schools.count > 1
                     ? "Each school keeps its own terms, so holidays are worked out separately and countdowns are labelled with whose they are."
                     : "Only needed if you have children at schools with different term dates.")
            }

            Section {
                Picker("Bank holidays", selection: $store.holidayRegion) {
                    ForEach(HolidayRegion.allCases) { region in
                        Text(region.label).tag(region)
                    }
                }
                if !store.automaticMarks.isEmpty {
                    Text("\(store.automaticMarks.count) dates loaded from gov.uk")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("School")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaPadding(.bottom, 70)
        .tint(theme.accent)
        .sheet(item: $route) { destination in
            Group {
                switch destination {
                case .term(let term):
                    SchoolTermEditView(
                        draft: term,
                        isNew: !store.schoolTerms.contains { $0.id == term.id }
                    )
                case .mark(let mark):
                    DayMarkEditView(
                        draft: mark,
                        isNew: !store.dayMarks.contains { $0.id == mark.id }
                    )
                case .school(let school):
                    SchoolEditView(
                        draft: school,
                        isNew: !store.schools.contains { $0.id == school.id }
                    )
                }
            }
            .environment(store)
            .environment(\.theme, theme)
        }
    }

    private func timetableSummary(for school: School) -> String {
        let table = store.timetable(for: school)
        guard !table.lessons.isEmpty else { return "None" }
        let kit = table.lessons.filter(\.needsKit).count
        let base = "\(table.lessons.count) lessons"
        return kit > 0 ? "\(base) · \(kit) with kit" : base
    }

    @ViewBuilder
    private func schoolSection(_ school: School) -> some View {
        let terms = store.terms(for: school)
        let marks = store.marks(for: school)
        let derived = store.derivedHolidays.filter { $0.schoolID == school.id && $0.kind == .schoolHoliday }

        Section {
            if store.hasMultipleSchools {
                Button { route = .school(school) } label: {
                    HStack {
                        Text(school.name.isEmpty ? "Untitled school" : school.name)
                        Spacer()
                        Image(systemName: "pencil")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                }
                .foregroundStyle(.primary)
            }

            ForEach(terms) { term in
                Button { route = .term(term) } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(term.name)
                        Text(term.rangeLabel)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.primary)
            }
            .onDelete { offsets in
                for index in offsets { store.deleteTerm(id: terms[index].id) }
            }

            Button {
                route = .term(SchoolTerm(schoolID: school.id))
            } label: {
                Label("Add a term", systemImage: "plus")
            }

            NavigationLink {
                TimetableSettings(school: school)
                    .environment(store)
                    .environment(\.theme, theme)
            } label: {
                HStack {
                    Label("Timetable", systemImage: "table")
                    Spacer()
                    Text(timetableSummary(for: school))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(derived) { holiday in
                HStack(spacing: 12) {
                    Capsule()
                        .fill(holiday.kind.tint)
                        .frame(width: 3, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(holiday.title)
                        Text("\(holiday.rangeLabel)  ·  from the gap")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            ForEach(marks) { mark in
                Button { route = .mark(mark) } label: {
                    HStack(spacing: 12) {
                        Capsule()
                            .fill(mark.kind.tint)
                            .frame(width: 3, height: 30)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mark.title)
                            Text("\(mark.rangeLabel)  ·  \(mark.kind.label)")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .onDelete { offsets in
                for index in offsets { store.deleteMark(id: marks[index].id) }
            }

            Button {
                route = .mark(DayMark(kind: .halfTerm, schoolID: school.id))
            } label: {
                Label("Add a break", systemImage: "plus")
            }
        } header: {
            Text(store.hasMultipleSchools
                 ? (school.name.isEmpty ? "School" : school.name)
                 : "Terms")
        } footer: {
            Text("Enter each term's first and last day. Everything between two terms becomes a holiday automatically. Half terms and inset days sit inside a term, so add those here too.")
        }
    }
}

struct SchoolEditView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State var draft: School
    let isNew: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Arthur's school", text: $draft.name)
                } footer: {
                    Text("Used to label countdowns and holidays once you have more than one school.")
                }

                if !isNew {
                    Section {
                        Button("Delete", role: .destructive) {
                            store.deleteSchool(id: draft.id)
                            dismiss()
                        }
                    } footer: {
                        Text("Removes its terms and breaks as well. Leaving them would fold one child's dates into another's.")
                    }
                }
            }
            .navigationTitle(isNew ? "New school" : "Edit school")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveSchool(draft)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .tint(theme.accent)
        }
    }
}

// MARK: - Sharing

struct SharingSettings: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    /// Wrapped rather than conformed. `CKShare` is a class, so Swift already
    /// supplies an `ObjectIdentifier`-based `id` for any `AnyObject` that adopts
    /// `Identifiable` — adding a `String` one makes the associated type
    /// ambiguous and the conformance fails.
    private struct ShareBox: Identifiable {
        let share: CKShare
        var id: String { share.recordID.recordName }
    }

    @State private var share: ShareBox?
    @State private var isPreparing = false
    @State private var message: String?

    private let sync = CloudSync.shared

    var body: some View {
        @Bindable var store = store

        return Form {
            Section {
                Toggle("Sync with iCloud", isOn: $store.syncEnabled)
                    .onChange(of: store.syncEnabled) { _, on in
                        if on { Task { await CloudSync.shared.start(store: store) } }
                    }

                if store.syncEnabled {
                    HStack {
                        Text("Status")
                        Spacer()
                        Text(sync.status.label)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                    HStack {
                        Text("Container")
                        Spacer()
                        Text(sync.containerName)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } footer: {
                Text(store.syncEnabled
                     ? "Your calendar syncs to your own iCloud account. Nothing leaves it until you invite someone."
                     : "Off until you turn it on. Needs the iCloud capability with CloudKit ticked in Xcode — without that entitlement, iOS shuts the app down the moment it touches CloudKit.")
            }

            Section {
                Button {
                    Task { await prepareShare() }
                } label: {
                    HStack {
                        Label(sync.isShared ? "Manage sharing" : "Invite someone", systemImage: "person.badge.plus")
                        Spacer()
                        if isPreparing { ProgressView() }
                    }
                }
                .disabled(isPreparing || !store.syncEnabled)

                if !sync.participants.isEmpty {
                    ForEach(sync.participants, id: \.self) { person in
                        HStack {
                            Image(systemName: "person.crop.circle")
                            Text(person)
                        }
                    }
                }

                if let message {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Shared with")
            } footer: {
                Text("Everything is shared: events, actions, birthdays, school dates and calendars. Whoever you invite can add and edit, and their changes appear on your phone. Per-calendar sharing isn't possible yet — CloudKit shares a whole zone.")
            }
        }
        .navigationTitle("Sharing")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaPadding(.bottom, 70)
        .tint(theme.accent)
        .sheet(item: $share) { box in
            CloudShareSheet(share: box.share, container: sync.container) {
                self.share = nil
                Task { await sync.refreshShareState() }
            }
            .ignoresSafeArea()
        }
        .task { await sync.refreshShareState() }
    }

    private func prepareShare() async {
        isPreparing = true
        defer { isPreparing = false }
        do {
            share = ShareBox(share: try await sync.shareForZone())
        } catch {
            message = "Couldn't set up sharing: \(error.localizedDescription)"
        }
    }
}

// MARK: - Appearance

struct AppearanceSettings: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme

    var body: some View {
        @Bindable var store = store

        return Form {
            Section {
                Toggle("Count school days only", isOn: $store.countInSchoolDays)
            } header: {
                Text("School countdowns")
            } footer: {
                Text("Off, a break three days away reads as three days, weekend included. On, it counts only the days school is actually open — useful for a child counting down lessons, less so for planning around it.")
            }

            Section {
                Toggle("Daylight and moon", isOn: $store.showAlmanacLines)
            } footer: {
                Text("Adds day length and moon phase to each day. Calculated on device, so it works for any date and offline.")
            }

            Section {
                Toggle("Highlight my working week", isOn: $store.workWeek.isHighlighted)

                if store.workWeek.isHighlighted {
                    ForEach(WorkWeek.weekdayNames, id: \.number) { entry in
                        Button {
                            if store.workWeek.days.contains(entry.number) {
                                store.workWeek.days.remove(entry.number)
                            } else {
                                store.workWeek.days.insert(entry.number)
                            }
                        } label: {
                            HStack {
                                Text(entry.name)
                                Spacer()
                                if store.workWeek.days.contains(entry.number) {
                                    Image(systemName: "checkmark").foregroundStyle(theme.accent)
                                }
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
            } header: {
                Text("Working week")
            } footer: {
                Text("Days off sit back a shade rather than turning grey, so a busy Saturday still reads as busy.")
            }

            Section("Theme") {
                ForEach(Theme.all) { candidate in
                    Button {
                        store.themeName = candidate.name
                    } label: {
                        HStack(spacing: 14) {
                            Circle()
                                .fill(candidate.accent)
                                .frame(width: 26, height: 26)
                            Text(candidate.name)
                                .fontWeight(candidate.name == store.themeName ? .semibold : .regular)
                            Spacer()
                            if candidate.name == store.themeName {
                                Image(systemName: "checkmark").foregroundStyle(theme.accent)
                            }
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaPadding(.bottom, 70)
        .tint(theme.accent)
    }
}
