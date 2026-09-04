import Foundation

/// Sun and moon, computed rather than fetched — so the almanac lines work for any
/// date, offline, not just the sixteen days a forecast covers.
nonisolated enum Sky {

    // MARK: Sun

    struct SolarDay {
        var sunrise: Date?
        var sunset: Date?
        /// Nil above the Arctic circle on a polar day or night.
        var length: TimeInterval?

        var lengthLabel: String {
            guard let length else { return "—" }
            let hours = Int(length) / 3600
            let minutes = (Int(length) % 3600) / 60
            return "\(hours)h \(minutes)m"
        }
    }

    /// Standard sunrise equation. Accurate to about a minute, which is far more
    /// than a calendar needs.
    static func solar(date: Date, latitude: Double, longitude: Double) -> SolarDay {
        let julian = date.startOfDay.julianDay + 0.5
        let n = (julian - 2451545.0 + 0.0008).rounded()
        let meanSolarNoon = n - longitude / 360.0

        let m = (357.5291 + 0.98560028 * meanSolarNoon).truncatingRemainder(dividingBy: 360)
        let mRad = m * .pi / 180

        let center = 1.9148 * sin(mRad) + 0.0200 * sin(2 * mRad) + 0.0003 * sin(3 * mRad)
        let lambda = (m + center + 180 + 102.9372).truncatingRemainder(dividingBy: 360)
        let lambdaRad = lambda * .pi / 180

        let transit = 2451545.0 + meanSolarNoon + 0.0053 * sin(mRad) - 0.0069 * sin(2 * lambdaRad)

        let declination = asin(sin(lambdaRad) * sin(23.4397 * .pi / 180))
        let phi = latitude * .pi / 180

        let numerator = sin(-0.833 * .pi / 180) - sin(phi) * sin(declination)
        let denominator = cos(phi) * cos(declination)
        let cosHourAngle = numerator / denominator

        guard abs(cosHourAngle) <= 1 else {
            // Sun never rises or never sets at this latitude today.
            return SolarDay(sunrise: nil, sunset: nil, length: cosHourAngle > 1 ? 0 : 86400)
        }

        let hourAngle = acos(cosHourAngle) * 180 / .pi
        let riseJulian = transit - hourAngle / 360
        let setJulian = transit + hourAngle / 360

        let sunrise = Date(julianDay: riseJulian)
        let sunset = Date(julianDay: setJulian)

        return SolarDay(sunrise: sunrise, sunset: sunset, length: sunset.timeIntervalSince(sunrise))
    }

    /// "3 minutes longer than yesterday" — the line that makes a year feel like it moves.
    static func daylightChange(date: Date, latitude: Double, longitude: Double) -> String? {
        let today = solar(date: date, latitude: latitude, longitude: longitude)
        let yesterday = solar(date: date.adding(days: -1), latitude: latitude, longitude: longitude)

        guard let a = today.length, let b = yesterday.length else { return nil }
        let delta = Int((a - b).rounded())
        guard abs(delta) >= 30 else { return "the same as yesterday" }

        let minutes = abs(delta) / 60
        let seconds = abs(delta) % 60
        let amount = minutes > 0
            ? "\(minutes) min\(minutes == 1 ? "" : "s")"
            : "\(seconds) sec"

        return delta > 0 ? "\(amount) longer than yesterday" : "\(amount) shorter than yesterday"
    }

    // MARK: Moon

    struct MoonPhase {
        /// 0 is new, 0.5 is full.
        var fraction: Double
        var name: String
        var symbol: String
        /// Percentage of the disc lit.
        var illumination: Int
    }

    private static let synodicMonth = 29.530588853
    /// A known new moon: 6 January 2000, 18:14 UTC.
    private static let referenceNewMoon = 2451550.26

    static func moon(on date: Date) -> MoonPhase {
        let julian = date.startOfDay.julianDay + 0.5
        var fraction = ((julian - referenceNewMoon) / synodicMonth).truncatingRemainder(dividingBy: 1)
        if fraction < 0 { fraction += 1 }

        let illumination = Int((((1 - cos(2 * .pi * fraction)) / 2) * 100).rounded())

        let (name, symbol): (String, String)
        switch fraction {
        case ..<0.03:      (name, symbol) = ("New moon", "moonphase.new.moon")
        case ..<0.22:      (name, symbol) = ("Waxing crescent", "moonphase.waxing.crescent")
        case ..<0.28:      (name, symbol) = ("First quarter", "moonphase.first.quarter")
        case ..<0.47:      (name, symbol) = ("Waxing gibbous", "moonphase.waxing.gibbous")
        case ..<0.53:      (name, symbol) = ("Full moon", "moonphase.full.moon")
        case ..<0.72:      (name, symbol) = ("Waning gibbous", "moonphase.waning.gibbous")
        case ..<0.78:      (name, symbol) = ("Last quarter", "moonphase.last.quarter")
        case ..<0.97:      (name, symbol) = ("Waning crescent", "moonphase.waning.crescent")
        default:           (name, symbol) = ("New moon", "moonphase.new.moon")
        }

        return MoonPhase(fraction: fraction, name: name, symbol: symbol, illumination: illumination)
    }
}

// MARK: - Julian day conversion

nonisolated extension Date {
    var julianDay: Double {
        timeIntervalSince1970 / 86400.0 + 2440587.5
    }

    init(julianDay: Double) {
        self.init(timeIntervalSince1970: (julianDay - 2440587.5) * 86400.0)
    }
}
