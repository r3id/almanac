import SwiftUI

// MARK: - Weather icon

nonisolated enum WeatherIconKind {
    case clear, partly, cloudy, rain, snow, storm
}

/// Drawn rather than SF-Symbol'd, so the sun and cloud keep the flat,
/// slightly oversized look the original had.
struct WeatherIcon: View {
    let kind: WeatherIconKind
    var size: CGFloat = 52

    var body: some View {
        ZStack {
            switch kind {
            case .clear:
                Circle()
                    .frame(width: size * 0.5, height: size * 0.5)
            case .partly:
                Circle()
                    .frame(width: size * 0.34, height: size * 0.34)
                    .offset(x: size * 0.16, y: -size * 0.16)
                cloud
            case .cloudy:
                cloud
            case .rain:
                cloud
                strokes(count: 3, symbolHeight: size * 0.16)
                    .offset(y: size * 0.3)
            case .snow:
                cloud
                HStack(spacing: size * 0.12) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle().frame(width: size * 0.07, height: size * 0.07)
                    }
                }
                .opacity(0.7)
                .offset(y: size * 0.32)
            case .storm:
                cloud
                Image(systemName: "bolt.fill")
                    .font(.system(size: size * 0.26))
                    .offset(y: size * 0.3)
                    .opacity(0.85)
            }
        }
        .frame(width: size, height: size)
    }

    private var cloud: some View {
        Image(systemName: "cloud.fill")
            .font(.system(size: size * 0.52))
            .opacity(0.85)
            .offset(y: size * 0.05)
    }

    private func strokes(count: Int, symbolHeight: CGFloat) -> some View {
        HStack(spacing: symbolHeight * 0.55) {
            ForEach(0..<count, id: \.self) { index in
                Capsule()
                    .frame(width: symbolHeight * 0.22, height: symbolHeight)
                    .offset(y: index == 1 ? symbolHeight * 0.25 : 0)
            }
        }
        .opacity(0.6)
    }
}

// MARK: - Colour bar

struct TagBar: View {
    @Environment(Store.self) private var store

    let item: Item
    var height: CGFloat = 34

    var body: some View {
        Capsule()
            .fill(Color(hex: store.tag(for: item).hex))
            .frame(width: 4, height: height)
    }
}

// MARK: - Section label

struct SectionLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .tracking(2.4)
            .opacity(0.72)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 26)
            .padding(.bottom, 8)
    }
}

// MARK: - Item row used inside the month list and timeline

struct ItemRow: View {
    let item: Item
    var showsSubtitle: Bool = true

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            TagBar(item: item, height: showsSubtitle ? 34 : 20)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    // A ticked action has to read as ticked everywhere it
                    // appears, not just on the screen where you ticked it.
                    if item.kind == .action, item.isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 11))
                            .opacity(0.7)
                    }
                    Text(item.kind == .birthday ? item.birthdayLine : item.title)
                        .font(.system(size: 15.5, weight: .regular))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .strikethrough(item.kind == .action && item.isDone)
                    if showsRepeatMark {
                        Image(systemName: "repeat")
                            .font(.system(size: 9))
                            .opacity(0.6)
                    }
                    if !item.notes.isEmpty {
                        Image(systemName: "text.alignleft")
                            .font(.system(size: 9))
                            .opacity(0.5)
                    }
                }
                if showsSubtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .opacity(0.72)
                }
            }
            Spacer(minLength: 0)
        }
        .opacity(item.kind == .action && item.isDone ? 0.45 : 1)
        .contentShape(Rectangle())
    }

    private var subtitle: String {
        if item.kind == .birthday { return "Birthday" }
        var parts: [String] = [item.timeLabel]
        if !item.place.isEmpty { parts.append(item.place) }
        return parts.joined(separator: "   ")
    }

    private var showsRepeatMark: Bool { item.recurrence.repeats }
}

extension View {
    /// Liquid Glass where it exists, the old material where it doesn't.
    ///
    /// Building against the iOS 26 SDK gives system bars Liquid Glass for
    /// nothing, but a hand-rolled capsule is just a capsule — it has to ask.
    /// Below 26 this falls back to `.ultraThinMaterial`, which is the closest
    /// thing available and what the app used before.
    @ViewBuilder
    func almanacGlass(_ shape: some Shape = Capsule()) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

/// Groups neighbouring glass shapes so they blend as they come together, rather
/// than sitting as separate frosted blobs. Below iOS 26 it's just an HStack.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 9
    @ViewBuilder var content: Content

    var body: some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                HStack(spacing: spacing) { content }
            }
        } else {
            HStack(spacing: spacing) { content }
        }
    }
}

/// The small outlined capsule used for TODAY and ADD. One definition, so the
/// two never drift apart on different screens.
struct PillButton: View {
    let title: String
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.6)
                .foregroundStyle(.white.opacity(0.6))
                .padding(.horizontal, 13)
                .padding(.vertical, 7)
                .almanacGlass()
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Theme through the environment

private struct ThemeKey: EnvironmentKey {
    static let defaultValue: Theme = Theme.all[0]
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}
