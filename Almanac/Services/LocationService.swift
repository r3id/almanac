import Foundation
import CoreLocation
import MapKit

/// One-shot current location, used for weather and the daylight figures when you
/// want them to follow you rather than stay pinned to home.
///
/// Travel times don't come through here — `MKMapItem.forCurrentLocation()` handles
/// that inside MapKit, which is why an ETA works even with this switched off.
@MainActor
final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()

    private let manager = CLLocationManager()
    private var locationPending: CheckedContinuation<CLLocation?, Never>?
    private var authPending: CheckedContinuation<Bool, Never>?

    override init() {
        super.init()
        manager.delegate = self
        // A calendar needs the right town, not the right doorstep.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    var status: CLAuthorizationStatus { manager.authorizationStatus }

    /// Without this key in Info.plist, iOS never shows the permission prompt and
    /// never reports an error — the request simply does nothing. Checking for it
    /// turns a silent failure into something the UI can explain.
    var hasUsageDescription: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSLocationWhenInUseUsageDescription") != nil
    }

    var isAuthorised: Bool {
        status == .authorizedWhenInUse || status == .authorizedAlways
    }

    var isDenied: Bool {
        status == .denied || status == .restricted
    }

    /// Shows the system prompt if it hasn't been shown, and waits for the answer.
    ///
    /// Asking for a fix immediately after `requestWhenInUseAuthorization()` fails
    /// silently, because the status is still `.notDetermined` while the alert is
    /// on screen. Waiting here is what makes the very first tap work.
    func ensureAuthorised() async -> Bool {
        guard hasUsageDescription else { return false }
        if isAuthorised { return true }
        if isDenied { return false }
        guard status == .notDetermined, authPending == nil else { return false }

        return await withCheckedContinuation { continuation in
            authPending = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Returns nil rather than throwing — a missing location should quietly fall
    /// back to the home place, not interrupt anything.
    func current() async -> CLLocation? {
        guard await ensureAuthorised() else { return nil }
        guard locationPending == nil else { return nil }

        return await withCheckedContinuation { continuation in
            locationPending = continuation
            manager.requestLocation()
        }
    }

    /// A named place for wherever you are, ready to drop straight into home.
    func currentPlace() async -> GeocodedPlace? {
        guard let location = await current() else { return nil }
        let name = await name(for: location) ?? "Current location"
        return GeocodedPlace(
            name: name,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            region: nil,
            country: nil
        )
    }

    /// A place name for the coordinate, or nil if there isn't one to be had.
    ///
    /// Below iOS 26 this returns nil rather than falling back to `CLGeocoder`.
    /// That isn't laziness: `CLGeocoder` is deprecated in the SDK this builds
    /// against, and Swift has no way to silence a deprecation at the call site.
    /// Marking the fallback deprecated only moves the warning up to whatever
    /// calls it, and then to whatever calls that — the chain has no end short of
    /// deprecating the whole app.
    ///
    /// The cost is small and contained: on iOS 25 and earlier the current
    /// location reads "Current location" instead of naming the town. Everything
    /// that matters — the forecast, the daylight figures — runs off coordinates
    /// and is unaffected.
    ///
    /// Raise the deployment target to iOS 26 and this can lose the check too.
    func name(for location: CLLocation) async -> String? {
        guard #available(iOS 26.0, *) else { return nil }
        guard let request = MKReverseGeocodingRequest(location: location) else { return nil }
        guard let items = try? await request.mapItems else { return nil }
        return items.first?.name
    }

    private func resumeLocation(_ location: CLLocation?) {
        locationPending?.resume(returning: location)
        locationPending = nil
    }

    // MARK: CLLocationManagerDelegate
    // The protocol isn't main-actor bound, so each callback hops back explicitly.

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let last = locations.last
        Task { @MainActor in self.resumeLocation(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in self.resumeLocation(nil) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            guard self.status != .notDetermined else { return }
            self.authPending?.resume(returning: self.isAuthorised)
            self.authPending = nil
            if !self.isAuthorised { self.resumeLocation(nil) }
        }
    }
}
