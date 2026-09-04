import Foundation
import MapKit
import Observation

nonisolated struct ResolvedPlace: Hashable {
    /// What goes on the event: "Sakura Japanese Restaurant".
    var name: String
    /// The full address, kept so routing can find it again unambiguously.
    var address: String
    var latitude: Double
    var longitude: Double
}

/// Type-ahead venue and address search, so an event's location is a real place
/// rather than a string you hope MapKit can find later.
///
/// This is what removes the manual travel estimate: once a location resolves to
/// coordinates, the ETA is a routing question with an actual answer.
@MainActor
@Observable
final class PlaceSearch: NSObject, MKLocalSearchCompleterDelegate {

    private(set) var suggestions: [MKLocalSearchCompletion] = []
    private(set) var isSearching = false

    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    func update(query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else {
            suggestions = []
            isSearching = false
            return
        }
        isSearching = true
        completer.queryFragment = trimmed
    }

    func clear() {
        suggestions = []
        isSearching = false
        completer.queryFragment = ""
    }

    /// Turns a suggestion into coordinates.
    ///
    /// Reads the position from the response's bounding region rather than
    /// `mapItem.placemark`, which is deprecated as of iOS 26. For a single
    /// resolved venue the region is tight around it, and a road ETA doesn't care
    /// about the last few metres anyway.
    func resolve(_ completion: MKLocalSearchCompletion) async -> ResolvedPlace? {
        let request = MKLocalSearch.Request(completion: completion)
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }

        let centre = response.boundingRegion.center
        guard CLLocationCoordinate2DIsValid(centre) else { return nil }

        return ResolvedPlace(
            name: completion.title,
            address: completion.subtitle,
            latitude: centre.latitude,
            longitude: centre.longitude
        )
    }

    // MARK: MKLocalSearchCompleterDelegate

    nonisolated func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        let results = completer.results
        Task { @MainActor in
            self.suggestions = results
            self.isSearching = false
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        Task { @MainActor in
            self.suggestions = []
            self.isSearching = false
        }
    }
}
