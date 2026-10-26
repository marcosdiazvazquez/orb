import CoreLocation
import Foundation

/// Where a capture is taken: the most accurate GPS fix seen while capturing, so the panorama can
/// carry coordinates the way a camera photo does. Capturing works without it.
@MainActor
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var since: Date?
    private var bestFix: CLLocation?
    private var answered: CheckedContinuation<Void, Never>?

    /// The best fix since `start()`; nil without permission, precise location, or a fix.
    var best: CaptureLocation? {
        bestFix.map { CaptureLocation(latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude,
                                      accuracy: $0.horizontalAccuracy) }
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    /// Asks for location the first time, and returns once the user has answered.
    func requestAccess() async {
        guard manager.authorizationStatus == .notDetermined, answered == nil else { return }
        await withCheckedContinuation { cont in
            answered = cont
            manager.requestWhenInUseAuthorization()
        }
    }

    func start() {
        bestFix = nil
        since = Date()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard self.manager.authorizationStatus != .notDetermined else { return }
            answered?.resume()
            answered = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            // Approximate location is off by kilometres: no use for placing a photo.
            guard let since, self.manager.accuracyAuthorization == .fullAccuracy else { return }
            // Fixes cached from before the capture began may be from another spot.
            for fix in locations where fix.horizontalAccuracy >= 0 && fix.timestamp >= since {
                if fix.horizontalAccuracy <= bestFix?.horizontalAccuracy ?? .infinity { bestFix = fix }
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix yet, or none at all indoors: the capture goes ahead without coordinates.
    }
}
