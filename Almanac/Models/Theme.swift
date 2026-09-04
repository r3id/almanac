import SwiftUI
import UIKit

nonisolated struct Theme: Identifiable, Hashable {
    let name: String
    let hex: String

    var id: String { name }
    var accent: Color { Color(hex: hex) }

    /// The accent lightened toward paper.
    ///
    /// The timeline used the accent at full strength, which made a saturated
    /// block of colour per day. Mixing it toward off-white instead gives the
    /// same hue as tinted paper — the colour still identifies the theme, but it
    /// sits behind the writing rather than competing with it.
    func paper(_ strength: Double) -> Color {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(accent).getRed(&red, green: &green, blue: &blue, alpha: &alpha)

        let sheet: CGFloat = 0.965
        let mix = CGFloat(max(0, min(strength, 1)))
        return Color(
            red: Double(sheet - (sheet - red) * mix),
            green: Double(sheet - (sheet - green) * mix),
            blue: Double(sheet - (sheet - blue) * mix)
        )
    }

    /// Ink on those pastels. Dark whatever the theme, because every paper tint
    /// is light by construction.
    var onPaper: Color { Color(hex: "16202A") }

    /// Pale themes need dark text on accent surfaces, or the day view is unreadable.
    var onAccent: Color {
        Color.relativeLuminance(hex) > 0.42 ? Color(hex: "101012") : .white
    }

    /// There is no light mode, so every accent sits on black. Anything below
    /// roughly 0.08 relative luminance stops separating from the chrome — the
    /// timeline bands merge into the rail and the month heat circles disappear.
    /// The original Nightfall was 0.018 and did exactly that.
    static let all: [Theme] = [
        .init(name: "Deep Teal",     hex: "17959B"),
        .init(name: "Nightfall",     hex: "3A57A0"),
        .init(name: "Harvest",       hex: "C9A227"),
        .init(name: "Rushlight",     hex: "E8952F"),
        .init(name: "Ember",         hex: "D9502B"),
        .init(name: "Brick",         hex: "B93231"),
        .init(name: "Rosehip",       hex: "C41F45"),
        .init(name: "Foxglove",      hex: "D91E5B"),
        .init(name: "Heather",       hex: "BE6DB8"),
        .init(name: "Damson",        hex: "97267E"),
        .init(name: "Wisteria",      hex: "9A93D6"),
        .init(name: "Meltwater",     hex: "6FAEDB"),
        .init(name: "Shallows",      hex: "8ED4DC"),
        .init(name: "Sea Glass",     hex: "A9CCD6"),
        .init(name: "Hoarfrost",     hex: "AFC0C4"),
        .init(name: "Verdigris",     hex: "A8C9B4"),
        .init(name: "Wheatfield",    hex: "E3DCA8"),
        .init(name: "First Light",   hex: "EFC98D"),
        .init(name: "Bramble",       hex: "B06B81"),
        .init(name: "Coppice",       hex: "3F6B52")
    ]

    static func named(_ name: String) -> Theme {
        all.first { $0.name == name } ?? all[0]
    }
}

nonisolated extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        self.init(
            .sRGB,
            red:   Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue:  Double(value & 0xFF) / 255,
            opacity: 1
        )
    }

    static func relativeLuminance(_ hex: String) -> Double {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        func channel(_ raw: UInt64) -> Double {
            let c = Double(raw) / 255
            return c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        let r = channel((value >> 16) & 0xFF)
        let g = channel((value >> 8) & 0xFF)
        let b = channel(value & 0xFF)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

/// The two flat greys the chrome sits on. Everything else is the theme accent.
enum Ink {
    static let base = Color.black
    static let raised = Color(hex: "141416")
    static let field = Color(hex: "1D1D20")
}

extension Color {
    /// Round-trips a picked colour back to the hex the store keeps.
    var hexString: String {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        UIColor(self).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(
            format: "%02X%02X%02X",
            Int((red * 255).rounded()),
            Int((green * 255).rounded()),
            Int((blue * 255).rounded())
        )
    }
}
