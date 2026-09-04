import SwiftUI

/// A home for things that work *on* the calendar rather than settings that
/// change it. One entry today; it exists so the next one has somewhere to go
/// that isn't the settings screen.
struct ToolsView: View {
    @Environment(Store.self) private var store
    @Environment(\.theme) private var theme
    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        LeavePlannerView()
                            .environment(store)
                            .environment(\.theme, theme)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Label("Holiday planner", systemImage: "beach.umbrella")
                            Text("Stretch your annual leave around bank holidays")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Tools")
            .navigationBarTitleDisplayMode(.inline)
            .safeAreaPadding(.bottom, 70)
            .tint(theme.accent)
        }
    }
}
