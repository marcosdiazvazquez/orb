import SwiftUI

@main
struct OrbApp: App {
    @UIApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var store: CaptureStore
    @State private var stitcher: StitchService
    @AppStorage(SettingsKey.output) private var output: OutputQuality = .high

    init() {
        let store = CaptureStore()
        _store = State(initialValue: store)
        _stitcher = State(initialValue: StitchService(store: store))
    }

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environment(store)
                .environment(stitcher)
                .preferredColorScheme(.dark)
                // A capture whose stitch was interrupted (app killed) picks up where it left off.
                .task { stitcher.resumeUnfinished(outputWidth: output.rawValue) }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        OrientationLock.allowed
    }
}

/// Which way the screen may turn. Portrait everywhere (capture assumes it), except the 360°
/// viewer, which also turns sideways with the phone.
@MainActor
enum OrientationLock {
    private(set) static var allowed: UIInterfaceOrientationMask = .portrait

    static func allow(_ mask: UIInterfaceOrientationMask) {
        allowed = mask
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
            // Turn back to portrait now rather than at the next rotation.
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask))
        }
    }
}
