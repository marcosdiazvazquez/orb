import SwiftUI

@main
struct OrbApp: App {
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
