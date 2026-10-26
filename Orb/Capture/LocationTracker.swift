import CoreLocation
import Foundation
import Observation

/// Where a capture is taken, from the GPS fixes seen while capturing, so the panorama can carry
/// coordinates the way a camera photo does. Capturing works without it.
@Observable @MainActor
final class LocationTracker: NSObject, CLLocationManagerDelegate {
    enum Status: Equatable {
        /// Location is denied, or only approximate.
        case off
        case searching
        case fix(accuracy: Double)
    }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var since: Date?
    @ObservationIgnored private var answered: CheckedContinuation<Void, Never>?
    private var fixes: [CLLocation] = []
    private var usable = false

    /// The position to tag the capture with; nil without permission, precise location, or a fix.
    var best: CaptureLocation? { Self.combine(fixes) }

    var status: Status {
        if let best { return .fix(accuracy: best.accuracy) }
        return usable ? .searching : .off
    }

    /// Location allowed at all, while in use or always. Core Motion needs it for true north.
    var allowed: Bool {
        let status = manager.authorizationStatus
        return status != .notDetermined && status != .denied && status != .restricted
    }

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        // Standing still is exactly when iOS would otherwise pause updates to save power.
        manager.pausesLocationUpdatesAutomatically = false
    }

    /// Asks for location the first time, and for precise location whenever it's off, returning
    /// once the user has answered.
    func requestAccess() async {
        if manager.authorizationStatus == .notDetermined, answered == nil {
            await withCheckedContinuation { cont in
                answered = cont
                manager.requestWhenInUseAuthorization()
            }
        }
        guard allowed, manager.accuracyAuthorization == .reducedAccuracy else { return }
        // Approximate location is off by kilometres. Ask for precise location for this session;
        // the purpose string is under this key in Info.plist.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: "Capture") { _ in cont.resume() }
        }
    }

    func start() {
        fixes = []
        since = Date()
        manager.startUpdatingLocation()
    }

    func stop() {
        manager.stopUpdatingLocation()
    }

    /// Averages the fixes within 1.5× of the best one's accuracy, weighted by 1/accuracy², so
    /// noise averages out while the phone stands in one spot and early coarse fixes don't count.
    /// The accuracy reported is the best single fix's: consecutive fixes' errors are correlated,
    /// so the average is not as much better as independent fixes would make it.
    nonisolated static func combine(_ fixes: [CLLocation]) -> CaptureLocation? {
        guard let bestAccuracy = fixes.map(\.horizontalAccuracy).min() else { return nil }
        var latitude = 0.0, longitude = 0.0, total = 0.0
        for fix in fixes where fix.horizontalAccuracy <= bestAccuracy * 1.5 {
            let weight = 1 / max(0.01, fix.horizontalAccuracy * fix.horizontalAccuracy)
            latitude += weight * fix.coordinate.latitude
            longitude += weight * fix.coordinate.longitude
            total += weight
        }
        return CaptureLocation(latitude: latitude / total, longitude: longitude / total, accuracy: bestAccuracy)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            usable = allowed && self.manager.accuracyAuthorization == .fullAccuracy
            guard self.manager.authorizationStatus != .notDetermined else { return }
            answered?.resume()
            answered = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let since, self.manager.accuracyAuthorization == .fullAccuracy else { return }
            // Fixes cached from before the capture began may be from another spot.
            fixes += locations.filter { $0.horizontalAccuracy >= 0 && $0.timestamp >= since }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // No fix yet, or none at all indoors: the capture goes ahead without coordinates.
    }
}
