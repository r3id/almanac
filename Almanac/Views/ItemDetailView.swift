import SwiftUI

struct ItemDetailView: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss

    let item: Item
    var onEdit: (Item) -> Void

    @State private var routedMinutes: Int?

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                Capsule()
                    .fill(.white.opacity(0.3))
                    .frame(width: 38, height: 4)
                    .padding(.top, 12)

                VStack(spacing: 0) {
                    Text(item.kind == .birthday ? item.birthdayLine : item.title)
                        .font(.system(size: 25, weight: .semibold))
                        .multilineTextAlignment(.center)

                    Text(item.timeLabel)
                        .font(.system(size: 17))
                        .padding(.top, 14)

                    Text(dateLine)
                        .font(.system(size: 11))
                        .tracking(2)
                        .opacity(0.65)
                        .padding(.top, 6)

                    if item.kind == .event, !item.isAllDay {
                        Text(afterwardsLine)
                            .font(.system(size: 15, weight: .light))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 290)
                            .padding(.top, 30)
                    }

                    if !item.place.isEmpty {
                        VStack(spacing: 4) {
                            Text(item.place)
                                .font(.system(size: 19, weight: .medium))
                            if !item.placeAddress.isEmpty {
                                Text(item.placeAddress)
                                    .font(.system(size: 13))
                                    .opacity(0.6)
                            }
                        }
                        .multilineTextAlignment(.center)
                        .padding(.top, 30)
                    }

                    if let travelLine {
                        Text(travelLine)
                            .font(.system(size: 14.5, weight: .light))
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 270)
                            .opacity(0.9)
                            .padding(.top, 14)
                    }

                    if let nominal = item.nominalDay, !nominal.isSameDay(as: item.day) {
                        Text(movedLine(from: nominal))
                            .font(.system(size: 13))
                            .opacity(0.75)
                            .padding(.top, 16)
                    }

                    if let summary = item.recurrence.summary(from: item.seriesStart ?? item.day) {
                        HStack(spacing: 6) {
                            Image(systemName: "repeat")
                                .font(.system(size: 11))
                            Text(summary)
                                .font(.system(size: 13))
                        }
                        .opacity(0.75)
                        .padding(.top, 18)
                    }

                    if let link = item.link {
                        Link(destination: link) {
                            HStack(spacing: 8) {
                                Image(systemName: "video.fill")
                                    .font(.system(size: 13))
                                Text("Join")
                                    .font(.system(size: 13, weight: .semibold))
                                    .tracking(1.2)
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 12)
                            .background(.white.opacity(0.14), in: Capsule())
                        }
                        .padding(.top, 26)
                    }

                    if !item.notes.isEmpty {
                        // Left-aligned rather than centred: notes are often a
                        // list, and centred lines make a list unreadable.
                        Text(item.notes)
                            .font(.system(size: 14, weight: .light))
                            .multilineTextAlignment(.leading)
                            .lineSpacing(4)
                            .frame(maxWidth: 320, alignment: .leading)
                            .opacity(0.85)
                            .padding(.top, 26)
                    }

                    if item.isExternal {
                        Text("From your system calendar — edit it in Calendar.")
                            .font(.system(size: 12))
                            .opacity(0.5)
                            .padding(.top, 26)
                    }

                    if item.kind == .action, !item.isExternal {
                        Button {
                            store.toggleDone(id: item.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 9) {
                                Image(systemName: item.isDone ? "arrow.uturn.backward" : "checkmark")
                                    .font(.system(size: 13, weight: .semibold))
                                Text(item.isDone ? "Not done after all" : "Mark as done")
                                    .font(.system(size: 13, weight: .semibold))
                            }
                            .padding(.horizontal, 24)
                            .padding(.vertical, 13)
                            .background(.white.opacity(0.14), in: Capsule())
                        }
                        .padding(.top, 28)
                    }

                    // A repeating event needs both. Delete meaning "delete every
                    // one of these, forever" behind a single unlabelled button
                    // is how people lose a year of appointments.
                    if item.recurrence.repeats, !item.isExternal {
                        HStack(spacing: 14) {
                            button("SKIP THIS ONE") {
                                store.skipOccurrence(of: item)
                                dismiss()
                            }
                            button("DELETE SERIES", tint: Color(hex: "FF8A7A")) {
                                store.delete(id: item.id)
                                dismiss()
                            }
                        }
                        .padding(.top, 44)

                        HStack(spacing: 14) {
                            button("CLOSE") { dismiss() }
                            button("EDIT") { onEdit(item) }
                        }
                        .padding(.top, 14)
                    } else {
                        HStack(spacing: 14) {
                            button("CLOSE") { dismiss() }
                            if !item.isExternal {
                                button("EDIT") { onEdit(item) }
                                button("DELETE", tint: Color(hex: "FF8A7A")) {
                                    store.delete(id: item.id)
                                    dismiss()
                                }
                            }
                        }
                        .padding(.top, 44)
                    }
                }
                .padding(.horizontal, 28)
                .padding(.top, 30)
                .padding(.bottom, 40)
            }
        }
        .scrollIndicators(.hidden)
        .frame(maxWidth: .infinity)
        .background(Ink.raised)
        .foregroundStyle(.white)
        .task { await routeIfPossible() }
    }

    private func button(_ label: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .tracking(1.8)
                .foregroundStyle(tint)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(.white.opacity(0.1), in: Capsule())
        }
    }

    /// "Moved from Sunday 25 October" — otherwise a payday quietly showing on
    /// the 23rd looks like the rule is wrong.
    private func movedLine(from nominal: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return "Moved from \(formatter.string(from: nominal))"
    }

    private var dateLine: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE d MMMM"
        return formatter.string(from: item.day).uppercased()
    }

    private var afterwardsLine: String {
        if let next = store.nextItem(after: item) {
            return "Next up afterwards: \(next.title) at \(Item.clock(next.start))."
        }
        return "Free for the rest of the day afterwards"
    }

    private var travelLine: String? {
        guard item.kind == .event, !item.isAllDay, item.travel != .none else { return nil }
        let minutes = routedMinutes ?? item.travelMinutes
        guard minutes > 0 else { return nil }

        let duration = minutes >= 60
            ? "\(minutes / 60)h \(minutes % 60)min."
            : "\(minutes) min."
        let leaveBy = Item.clock(item.start - minutes)
        let source = routedMinutes == nil ? "" : " (live)"
        return "\(duration)\(source) \(item.travel.phrase) so you should leave before \(leaveBy)"
    }

    private func routeIfPossible() async {
        guard item.travel.supportsRouting, !item.place.isEmpty else { return }
        routedMinutes = await TravelService.shared.minutes(
            to: item.routeQuery,
            latitude: item.placeLatitude,
            longitude: item.placeLongitude,
            mode: item.travel
        )
    }
}
