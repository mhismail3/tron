import CoreLocation
import Foundation

/// Monitors device location using significant location changes (low-power).
///
/// Provides reverse-geocoded location context (city, region, country) for
/// DeviceContext system prompt injection. Only active when location integration
/// is enabled in settings. Uses `significantLocationChanges` (~500m threshold)
/// to minimize battery impact.
@MainActor
final class LocationService: NSObject, @unchecked Sendable {
    static let shared = LocationService()

    private nonisolated(unsafe) let manager = CLLocationManager()
    private nonisolated(unsafe) let geocoder = CLGeocoder()

    private(set) var currentLocation: LocationContext?
    private var isMonitoring = false
    private var permissionContinuation: CheckedContinuation<Bool, Never>?

    struct LocationContext {
        let city: String?
        let region: String?
        let country: String?
        let latitude: Double?
        let longitude: Double?
    }

    private override init() {
        super.init()
        manager.delegate = self
    }

    // MARK: - Authorization

    func requestPermission() async -> Bool {
        let status = manager.authorizationStatus
        // Already determined — return immediately
        if status == .authorizedWhenInUse || status == .authorizedAlways {
            return true
        }
        if status == .denied || status == .restricted {
            return false
        }
        // Status is .notDetermined — show dialog and wait for delegate callback
        return await withCheckedContinuation { continuation in
            // Guard re-entrancy: if called twice before delegate fires,
            // resume the first continuation immediately to prevent hanging.
            if let existing = self.permissionContinuation {
                existing.resume(returning: manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways)
            }
            self.permissionContinuation = continuation
            manager.requestWhenInUseAuthorization()
        }
    }

    // MARK: - Control

    func startMonitoring() {
        guard !isMonitoring else { return }
        manager.requestWhenInUseAuthorization()
        if CLLocationManager.significantLocationChangeMonitoringAvailable() {
            manager.startMonitoringSignificantLocationChanges()
            isMonitoring = true
        }
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        manager.stopMonitoringSignificantLocationChanges()
        isMonitoring = false
        currentLocation = nil
    }

    // MARK: - Context

    /// Format location as a compact string for DeviceContext.
    func formatContextPart(precision: String) -> String? {
        guard let loc = currentLocation else { return nil }

        var parts: [String] = []
        if let city = loc.city { parts.append(city) }
        if let region = loc.region { parts.append(region) }
        if let country = loc.country { parts.append(country) }

        guard !parts.isEmpty else { return nil }

        var result = parts.joined(separator: ", ")
        if precision == "coordinates", let lat = loc.latitude, let lon = loc.longitude {
            result += " (\(String(format: "%.2f", lat)), \(String(format: "%.2f", lon)))"
        }
        return result
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationService: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        geocoder.reverseGeocodeLocation(location) { [weak self] placemarks, _ in
            guard let place = placemarks?.first else { return }
            Task { @MainActor in
                self?.currentLocation = LocationContext(
                    city: place.locality,
                    region: place.administrativeArea,
                    country: place.isoCountryCode,
                    latitude: location.coordinate.latitude,
                    longitude: location.coordinate.longitude
                )
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Location errors are non-fatal — context just won't include location
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor [weak self] in
            guard let self else { return }

            // Resolve pending permission request if waiting
            if let continuation = self.permissionContinuation {
                self.permissionContinuation = nil
                let granted = status == .authorizedWhenInUse || status == .authorizedAlways
                continuation.resume(returning: granted)
            }

            if status == .authorizedWhenInUse || status == .authorizedAlways {
                if self.isMonitoring {
                    self.manager.startMonitoringSignificantLocationChanges()
                }
            } else if status == .denied || status == .restricted {
                self.stopMonitoring()
            }
        }
    }
}
