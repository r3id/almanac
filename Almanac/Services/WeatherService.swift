import Foundation

nonisolated struct DayWeather {
    var code: Int
    var high: Int
    var low: Int
    var precipitationChance: Int?
    var humidityLow: Int?
    var humidityHigh: Int?
    var uvIndex: Int
    var windSpeed: Int
    var sunrise: String
    var sunset: String

    var condition: (text: String, icon: WeatherIconKind) {
        switch code {
        case 0:          return ("Clear", .clear)
        case 1:          return ("Mostly clear", .clear)
        case 2:          return ("Partly cloudy", .partly)
        case 3:          return ("Overcast", .cloudy)
        case 45, 48:     return ("Fog", .cloudy)
        case 51, 53, 55: return ("Drizzle", .rain)
        case 61, 80:     return ("Light rain", .rain)
        case 63, 81:     return ("Rain", .rain)
        case 65, 82:     return ("Heavy rain", .rain)
        case 71, 73, 75: return ("Snow", .snow)
        case 95, 96, 99: return ("Thunderstorms", .storm)
        default:         return ("Cloudy", .cloudy)
        }
    }

    var humidityLabel: String {
        guard let low = humidityLow, let high = humidityHigh else { return "—" }
        return "\(low)% – \(high)%"
    }
}

nonisolated struct GeocodedPlace: Identifiable, Hashable {
    let name: String
    let latitude: Double
    let longitude: Double
    var region: String?
    var country: String?

    var id: String { "\(name)|\(latitude)|\(longitude)" }

    /// "Kingston, Greater London, United Kingdom" — enough to tell apart the
    /// half dozen places that share a name.
    var detail: String {
        [region, country].compactMap { $0 }.joined(separator: ", ")
    }
}

/// Open-Meteo needs no API key and no paid developer account, which keeps this
/// buildable with a free Apple ID. Swap in WeatherKit later if you upgrade.
actor WeatherService {
    static let shared = WeatherService()

    private var cache: [String: DayWeather] = [:]
    private var cachedAt: Date?
    private var cacheKey: String = ""

    /// Several matches rather than one, so you pick the right Kingston instead of
    /// typing a longer query until the guess happens to be correct.
    func search(place query: String, count: Int = 8) async throws -> [GeocodedPlace] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return [] }

        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        components.queryItems = [
            .init(name: "name", value: trimmed),
            .init(name: "count", value: String(count)),
            .init(name: "language", value: Locale.current.language.languageCode?.identifier ?? "en")
        ]
        guard let url = components.url else { return [] }
        let (data, _) = try await URLSession.shared.data(from: url)

        struct Response: Decodable {
            struct Result: Decodable {
                let name: String
                let latitude: Double
                let longitude: Double
                let admin1: String?
                let country: String?
            }
            let results: [Result]?
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        return (decoded.results ?? []).map {
            GeocodedPlace(
                name: $0.name,
                latitude: $0.latitude,
                longitude: $0.longitude,
                region: $0.admin1,
                country: $0.country
            )
        }
    }

    /// Set when the last fetch failed, so the UI can say why instead of showing
    /// an empty section.
    private(set) var lastFailure: String?

    func forecast(latitude: Double, longitude: Double) async -> [String: DayWeather] {
        let key = "\(latitude),\(longitude)"
        if key == cacheKey, let cachedAt, Date.now.timeIntervalSince(cachedAt) < 900 {
            return cache
        }

        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(latitude)),
            .init(name: "longitude", value: String(longitude)),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max,sunrise,sunset,uv_index_max,wind_speed_10m_max"),
            .init(name: "hourly", value: "relative_humidity_2m"),
            .init(name: "timezone", value: "auto"),
            // The docs cap this at 16 on the main endpoint and 10 on some models.
            // Asking for more than a model allows returns HTTP 400 and no data at
            // all, so 14 stays inside every limit while losing almost nothing.
            .init(name: "forecast_days", value: "14")
        ]
        guard let url = components.url else {
            lastFailure = "Couldn't build the request."
            return [:]
        }

        // Every array is optional. A single unsupported variable used to throw
        // during decode and take the whole forecast down with it — including the
        // temperatures, which had arrived perfectly well.
        struct Response: Decodable {
            struct Daily: Decodable {
                let time: [String]
                let weather_code: [Int]?
                let temperature_2m_max: [Double]?
                let temperature_2m_min: [Double]?
                let precipitation_probability_max: [Int?]?
                let sunrise: [String]?
                let sunset: [String]?
                let uv_index_max: [Double?]?
                let wind_speed_10m_max: [Double]?
            }
            struct Hourly: Decodable {
                let time: [String]
                let relative_humidity_2m: [Int]?
            }
            let daily: Daily?
            let hourly: Hourly?
            let error: Bool?
            let reason: String?
        }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let decoded = try JSONDecoder().decode(Response.self, from: data)

            // Open-Meteo reports bad parameters in the body, not just the status.
            if decoded.error == true {
                lastFailure = decoded.reason ?? "The forecast service rejected the request."
                return [:]
            }
            if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
                lastFailure = decoded.reason ?? "Forecast service returned \(http.statusCode)."
                return [:]
            }
            guard let daily = decoded.daily else {
                lastFailure = "The forecast came back without any daily data."
                return [:]
            }

            var result: [String: DayWeather] = [:]

            for (index, dayKey) in daily.time.enumerated() {
                var humidities: [Int] = []
                if let hourly = decoded.hourly, let values = hourly.relative_humidity_2m {
                    for (hourIndex, stamp) in hourly.time.enumerated()
                    where stamp.hasPrefix(dayKey) && hourIndex < values.count {
                        humidities.append(values[hourIndex])
                    }
                }

                func value<T>(_ array: [T]?) -> T? {
                    guard let array, index < array.count else { return nil }
                    return array[index]
                }

                guard let high = value(daily.temperature_2m_max),
                      let low = value(daily.temperature_2m_min)
                else { continue }

                result[dayKey] = DayWeather(
                    code: value(daily.weather_code) ?? 3,
                    high: Int(high.rounded()),
                    low: Int(low.rounded()),
                    precipitationChance: value(daily.precipitation_probability_max) ?? nil,
                    humidityLow: humidities.min(),
                    humidityHigh: humidities.max(),
                    uvIndex: Int(((value(daily.uv_index_max) ?? nil) ?? 0).rounded()),
                    windSpeed: Int((value(daily.wind_speed_10m_max) ?? 0).rounded()),
                    sunrise: String((value(daily.sunrise) ?? "").suffix(5)),
                    sunset: String((value(daily.sunset) ?? "").suffix(5))
                )
            }

            guard !result.isEmpty else {
                lastFailure = "The forecast came back empty."
                return [:]
            }

            lastFailure = nil
            cache = result
            cacheKey = key
            cachedAt = .now
            return result
        } catch let error as URLError {
            lastFailure = "No connection to the forecast service (\(error.code.rawValue))."
            return [:]
        } catch {
            lastFailure = "Couldn't read the forecast response."
            return [:]
        }
    }

    nonisolated static func dayKey(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
