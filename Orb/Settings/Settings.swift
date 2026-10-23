import PanoCore
import SwiftUI

enum SettingsKey {
    static let lens = "lens"
    static let density = "density"
    static let output = "outputWidth"
    static let lockExposure = "lockExposure"
}

enum Lens: String, CaseIterable, Identifiable, Codable {
    case ultraWide, wide

    var id: Self { self }
    var label: String { self == .ultraWide ? "Ultra Wide (0.5×)" : "Wide (1×)" }
    /// Typical long-side field of view, for estimates before the camera is open.
    var typicalLongFOV: Double { (self == .ultraWide ? 106.0 : 67.0) * .pi / 180 }
}

enum ShotDensity: String, CaseIterable, Identifiable {
    case standard, dense

    var id: Self { self }
    var label: String { self == .standard ? "Standard" : "Dense" }
    /// Fraction of each frame shared with its neighbours.
    var overlap: Double { self == .standard ? 0.4 : 0.55 }
}

enum OutputQuality: Int, CaseIterable, Identifiable {
    case standard = 4096, high = 6144, max = 8192

    var id: Self { self }
    var label: String {
        switch self {
        case .standard: "4K (4096 × 2048)"
        case .high: "6K (6144 × 3072)"
        case .max: "8K (8192 × 4096)"
        }
    }
    var short: String {
        switch self {
        case .standard: "4K"
        case .high: "6K"
        case .max: "8K"
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.lens) private var lens: Lens = .ultraWide
    @AppStorage(SettingsKey.density) private var density: ShotDensity = .standard
    @AppStorage(SettingsKey.output) private var output: OutputQuality = .high
    @AppStorage(SettingsKey.lockExposure) private var lockExposure = true

    private var shotCount: Int {
        let short = 2 * atan(tan(lens.typicalLongFOV / 2) * 0.75)
        return ShotPlan(shortFOV: short, overlap: density.overlap).count
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Lens", selection: $lens) {
                        ForEach(Lens.allCases) { Text($0.label).tag($0) }
                    }
                    Picker("Overlap", selection: $density) {
                        ForEach(ShotDensity.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Capture")
                } footer: {
                    Text("About \(shotCount) shots per sphere. Dense overlap takes longer but stitches better in plain or close-up scenes. Phones without an ultra wide camera use the wide one.")
                }

                Section {
                    Toggle("Lock exposure at first shot", isOn: $lockExposure)
                } footer: {
                    Text("Locked exposure and white balance make seams invisible. Turn it off for scenes with both bright windows and dark corners; the stitcher then evens out the brightness.")
                }

                Section {
                    Picker("Resolution", selection: $output) {
                        ForEach(OutputQuality.allCases) { Text($0.label).tag($0) }
                    }
                } header: {
                    Text("Panorama")
                } footer: {
                    Text("Applies to new captures. Re-stitch older ones from their ⋯ menu.")
                }

                Section("Files") {
                    Text("Original shots and panoramas are in the Files app under On My iPhone › Orb › Captures.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }
}
