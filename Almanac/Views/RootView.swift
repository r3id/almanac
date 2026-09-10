import SwiftUI

struct RootView: View {
    @Environment(Store.self) private var store

    enum Pane { case today, month, timeline, tools, settings }

    @State private var pane: Pane = .today
    @State private var selected: Date = Date.now.startOfDay

    @State private var openDay: DayRef?
    @State private var route: Route?

    /// Three separate `.sheet` modifiers stacked on one view is a well-worn way
    /// to have one of them quietly refuse to present. One sheet, one route.
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

    var body: some View {
        ZStack(alignment: .bottom) {
            Ink.base.ignoresSafeArea()

            // Switching panes is a tap, not a swipe. Horizontal belongs to the
            // month grid for paging months, and one gesture can't do both.
            Group {
                switch pane {
                case .today:
                    TodayView(
                        onOpenDay: { openDay = DayRef(date: $0) },
                        onOpenItem: { route = .detail($0) },
                        onAdd: { route = .edit(newItem(on: Date.now.startOfDay)) }
                    )

                case .month:
                    MonthView(
                        selected: $selected,
                        onOpenDay: { openDay = DayRef(date: $0) },
                        onOpenItem: { route = .detail($0) },
                        onAdd: { route = .edit(newItem(on: selected)) }
                    )

                case .timeline:
                    TimelineView(
                        onOpenDay: { openDay = DayRef(date: $0) },
                        onOpenItem: { route = .detail($0) },
                        onAdd: { route = .edit(newItem(on: Date.now.startOfDay)) }
                    )

                // Destinations in their own right, not sheets. A settings screen
                // you can't swipe away from is a page pretending to be a modal.
                case .tools:
                    ToolsView()

                case .settings:
                    SettingsView()
                }
            }
            .transition(.opacity)

            toolbar
        }
        .environment(\.theme, store.theme)
        .preferredColorScheme(.dark)

        // A sheet rather than a full-screen cover: the grabber and the
        // swipe-down do the dismissing, so the day needs no back button, and
        // the calendar stays visible behind it.
        .sheet(item: $openDay) { ref in
            DayView(day: ref.date)
                .environment(store)
                .environment(\.theme, store.theme)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }

        .sheet(item: $route) { destination in
            Group {
                switch destination {
                case .detail(let item):
                    ItemDetailView(item: item) { toEdit in
                        route = nil
                        // Let the sheet finish dismissing before the editor opens.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                            route = .edit(toEdit)
                        }
                    }
                    .presentationDetents([.large])
                    .presentationDragIndicator(.hidden)

                case .edit(let item):
                    ItemEditView(draft: item, isNew: store.item(id: item.id) == nil)
                }
            }
            .environment(store)
            .environment(\.theme, store.theme)
        }

        .task {
            await NotificationService.shared.requestAuthorization()
            await store.refreshExternal()
            await store.refreshHolidays()
            await store.refreshCurrentLocation()
            await store.rescheduleAllNotifications()
            if store.syncEnabled { await CloudSync.shared.start(store: store) }
        }
    }

    /// The toolbar and the horizontal swipe do the same job — the bar is just the
    /// visible version, and it also holds add and settings.
    private var toolbar: some View {
        HStack(spacing: 6) {
            barButton("sun.horizon", isOn: pane == .today) { show(.today) }
            barButton("calendar", isOn: pane == .month) { show(.month) }
            barButton("list.bullet", isOn: pane == .timeline) { show(.timeline) }
            barButton("wrench.and.screwdriver", isOn: pane == .tools) { show(.tools) }
            barButton("gearshape", isOn: pane == .settings) { show(.settings) }
        }
        .padding(7)
        // A near-invisible shape underneath catches taps that land between the
        // icons. The previous fix put a tap gesture on the container, which
        // consumed the tap before the buttons inside it ever saw one.
        .background(Capsule().fill(.white.opacity(0.001)))
        .almanacGlass()
        // Without this the bar only catches taps that land on a button. Drawing
        // a background — material or glass — doesn't make an area hit-testable,
        // so gaps between the icons passed the tap through to whatever row was
        // scrolling underneath.
        .padding(.bottom, 8)
    }

    private func barButton(_ symbol: String, isOn: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17))
                .frame(width: 46, height: 38)
                // The selected pane stays a solid capsule rather than more
                // glass. Glass on glass reads as a smudge; the whole point of
                // the bar being glass is that the selection sits clearly on it.
                .background(isOn ? Color.white : .clear, in: Capsule())
                .foregroundStyle(isOn ? Color.black : .white.opacity(0.8))
        }
        .buttonStyle(.plain)
    }

    private func show(_ next: Pane) {
        guard pane != next else { return }
        pane = next
    }

    private func newItem(on day: Date) -> Item {
        Item.draft(on: day)
    }
}
