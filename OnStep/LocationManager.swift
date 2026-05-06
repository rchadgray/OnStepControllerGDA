import Foundation
import CoreLocation
import Combine

// Wraps CoreLocation to obtain the device's GPS coordinates and expose them
// in the formats that the OnStep LX200 protocol expects.
final class LocationManager: NSObject, ObservableObject {
    @Published var latitude:  Double = 0.0
    @Published var longitude: Double = 0.0
    @Published var locationReceived   = false
    @Published var authorizationStatus: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        // Kilometre accuracy is sufficient for telescope alignment — no need to drain
        // the battery with high-precision GPS.
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    // Requests a one-shot GPS fix. Handles the case where permission hasn't been
    // granted yet by asking first; the delegate will trigger a fix once granted.
    func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .authorizedWhenInUse, .authorizedAlways:
            manager.requestLocation()
        default:
            break
        }
    }

    // MARK: - LX200 Formatting

    // Formats latitude for the :St command: [s]DD*MM:SS
    // e.g. +41*01:30  (positive = North, negative = South)
    var lx200Latitude: String {
        let sign = latitude >= 0 ? "+" : "-"
        let a    = abs(latitude)
        let deg  = Int(a)
        let mt   = (a - Double(deg)) * 60.0
        let min  = Int(mt)
        let sec  = Int((mt - Double(min)) * 60.0)
        return String(format: "%@%02d*%02d:%02d", sign, deg, min, sec)
    }

    // Formats longitude for the :Sg command: [s]DDD*MM:SS
    // LX200 convention: positive = West, negative = East (opposite of standard GPS).
    // e.g. +081*43:48 for Wadsworth, Ohio (81.73° W)
    var lx200Longitude: String {
        let sign = longitude <= 0 ? "+" : "-"   // GPS negative (West) → LX200 positive
        let a    = abs(longitude)
        let deg  = Int(a)
        let mt   = (a - Double(deg)) * 60.0
        let min  = Int(mt)
        let sec  = Int((mt - Double(min)) * 60.0)
        return String(format: "%@%03d*%02d:%02d", sign, deg, min, sec)
    }

    // Human-readable strings for display in the Setup screen.
    var latitudeDisplay: String {
        String(format: "%.4f° %@", abs(latitude), latitude >= 0 ? "N" : "S")
    }
    var longitudeDisplay: String {
        String(format: "%.4f° %@", abs(longitude), longitude >= 0 ? "E" : "W")
    }
}

extension LocationManager: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        DispatchQueue.main.async {
            self.latitude  = loc.coordinate.latitude
            self.longitude = loc.coordinate.longitude
            self.locationReceived = true
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        #if DEBUG
        print("LocationManager: \(error.localizedDescription)")
        #endif
    }

    // If the user grants permission after the app is already running, immediately
    // request a location fix so there's no extra tap required.
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        DispatchQueue.main.async {
            self.authorizationStatus = manager.authorizationStatus
            if manager.authorizationStatus == .authorizedWhenInUse ||
               manager.authorizationStatus == .authorizedAlways {
                manager.requestLocation()
            }
        }
    }
}
