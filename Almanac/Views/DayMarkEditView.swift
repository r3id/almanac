import SwiftUI

struct DayMarkEditView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State var draft: DayMark
    let isNew: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.title)

                    Picker("Kind", selection: $draft.kind) {
                        ForEach([DayMarkKind.schoolHoliday, .halfTerm, .insetDay, .custom], id: \.self) { kind in
                            Text(kind.label).tag(kind)
                        }
                    }
                    .onChange(of: draft.kind) { _, newValue in
                        draft.weekdaysOnly = newValue.defaultWeekdaysOnly
                        if newValue.isSingleDay { draft.end = draft.start }
                    }
                    if store.hasMultipleSchools {
                        Picker("School", selection: Binding(
                            get: { draft.schoolID ?? store.schools.first?.id },
                            set: { draft.schoolID = $0 }
                        )) {
                            ForEach(store.schools) { school in
                                Text(school.name).tag(Optional(school.id))
                            }
                        }
                    }
                } footer: {
                    Text("Bank holidays are filled in for you. Add the breaks: half terms, holidays and inset days. There's no \"term time\" to add — a day that isn't one of these is a school day.")
                }

                Section {
                    DatePicker("From", selection: $draft.start, displayedComponents: .date)
                        .onChange(of: draft.start) { _, newValue in
                            if draft.kind.isSingleDay || draft.end < newValue { draft.end = newValue }
                        }

                    if !draft.kind.isSingleDay {
                        DatePicker("To", selection: $draft.end, displayedComponents: .date)
                    }

                    Toggle("Weekdays only", isOn: $draft.weekdaysOnly)

                    if draft.markedDayCount > 0 {
                        Text("\(draft.markedDayCount) day\(draft.markedDayCount == 1 ? "" : "s") marked")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Dates")
                } footer: {
                    Text("Weekends were never school days, so a half term that painted the Saturday either side would just be noise. Leave this on for anything school-related.")
                }

                if !isNew {
                    Section {
                        Button("Delete", role: .destructive) {
                            store.deleteMark(id: draft.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New range" : "Edit range")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveMark(draft)
                        dismiss()
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .tint(theme.accent)
        }
    }
}
