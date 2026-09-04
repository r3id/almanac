import SwiftUI

struct SchoolTermEditView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    @State var draft: SchoolTerm
    let isNew: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Autumn term", text: $draft.name)

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
                    Text("Copy these straight off your council's term dates page.")
                }

                Section {
                    DatePicker("First day", selection: $draft.start, displayedComponents: .date)
                        .onChange(of: draft.start) { _, newValue in
                            if draft.end < newValue { draft.end = newValue }
                        }
                    DatePicker("Last day", selection: $draft.end, displayedComponents: .date)
                } header: {
                    Text("Dates")
                } footer: {
                    Text("Enter the term itself. The holiday before the next term is worked out from the gap, so you never type a holiday in.")
                }

                if !isNew {
                    Section {
                        Button("Delete", role: .destructive) {
                            store.deleteTerm(id: draft.id)
                            dismiss()
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "New term" : "Edit term")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.saveTerm(draft)
                        dismiss()
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .tint(theme.accent)
        }
    }
}
