import Foundation
import Observation
import PanoCore

struct ShotRecord: Codable, Hashable {
    var file: String
    var target: Int
    /// Device-to-world rotation from Core Motion, row-major (world Z up).
    var deviceRotation: [Double]
    var time: Double
}

struct PanoramaInfo: Codable, Hashable {
    var width: Int
    var height: Int
    var seconds: Double
    /// RMS ray misalignment after the last bundle-adjustment round.
    var alignmentDegrees: Double?
    var matches: Int
    var date: Date
}

/// One capture: its shots, and the panorama once stitched. Saved as `capture.json` in the
/// capture's folder next to the shot files, `pano.jpg`, `planet.jpg` and `thumb.jpg`.
struct CaptureRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var date: Date
    var lens: Lens
    /// Field of view across the photos' long side, radians.
    var longFOV: Double
    var plannedShots: Int
    var shots: [ShotRecord]
    var panorama: PanoramaInfo?
    var stitchError: String?
}

@Observable @MainActor
final class CaptureStore {
    private(set) var captures: [CaptureRecord] = []

    nonisolated static let root = URL.documentsDirectory.appending(path: "Captures", directoryHint: .isDirectory)

    nonisolated static func directory(for id: UUID) -> URL {
        root.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    func panoramaURL(_ id: UUID) -> URL { Self.directory(for: id).appending(path: "pano.jpg") }
    func planetURL(_ id: UUID) -> URL { Self.directory(for: id).appending(path: "planet.jpg") }
    func thumbnailURL(_ id: UUID) -> URL { Self.directory(for: id).appending(path: "thumb.jpg") }

    init() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        load()
    }

    func record(_ id: UUID) -> CaptureRecord? { captures.first { $0.id == id } }

    func load() {
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
        var found: [CaptureRecord] = []
        for dir in dirs {
            let json = dir.appending(path: "capture.json")
            if let data = try? Data(contentsOf: json), let r = try? Self.decoder.decode(CaptureRecord.self, from: data) {
                found.append(r)
            } else if !fm.fileExists(atPath: json.path) {
                // Leftover from a capture that never finished (app quit mid-capture).
                try? fm.removeItem(at: dir)
            }
        }
        captures = found.sorted { $0.date > $1.date }
    }

    func save(_ record: CaptureRecord) {
        let url = Self.directory(for: record.id).appending(path: "capture.json")
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? Self.encoder.encode(record) { try? data.write(to: url, options: .atomic) }
        if let i = captures.firstIndex(where: { $0.id == record.id }) {
            captures[i] = record
        } else {
            captures.insert(record, at: 0)
            captures.sort { $0.date > $1.date }
        }
    }

    func delete(_ id: UUID) {
        try? FileManager.default.removeItem(at: Self.directory(for: id))
        captures.removeAll { $0.id == id }
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
