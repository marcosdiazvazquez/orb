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
    /// Compass bearing of the panorama's centre, degrees clockwise from north. A column's
    /// bearing is this plus its longitude, which grows to the right.
    var heading: Double?
}

/// Where a capture was taken: the accuracy-weighted average of its best GPS fixes.
struct CaptureLocation: Codable, Hashable {
    var latitude: Double
    var longitude: Double
    /// Radius of uncertainty of the best single fix, metres.
    var accuracy: Double
}

/// Which way north is, so every direction in the capture has a compass bearing.
struct CaptureHeading: Codable, Hashable {
    /// Bearing of the shot rotations' world X axis, degrees clockwise from north. Those rotations
    /// come from the gyroscope alone, so X is wherever the phone pointed when tracking began.
    var worldX: Double
    /// Spread (circular standard deviation) of the compass readings averaged, degrees. A magnetic
    /// disturbance that is the same in every direction biases them without widening it.
    var spread: Double
    /// From true north, or magnetic north when location was off.
    var trueNorth: Bool
}

/// One capture: its shots, and the panorama once stitched. Saved as `capture.json` in the
/// capture's folder next to the shot files, `pano.jpg`, `planet.jpg` and `thumb.jpg`.
struct CaptureRecord: Codable, Hashable, Identifiable {
    var id: UUID
    var date: Date
    /// Given by the user; without one, the library shows the date.
    var name: String?
    /// The folder it's filed in; nil is the top level of the library.
    var folder: String?
    /// Where it was taken, if the phone had a precise fix.
    var location: CaptureLocation?
    /// Which way north is, if the compass had enough readings.
    var heading: CaptureHeading?
    var lens: Lens
    /// Field of view across the photos' long side, radians.
    var longFOV: Double
    var plannedShots: Int
    var shots: [ShotRecord]
    var panorama: PanoramaInfo?
    var stitchError: String?
}

extension CaptureRecord {
    var title: String { name ?? date.formatted(.dateTime.month(.abbreviated).day().hour().minute()) }

    /// The name, without `.jpg`, that the panorama is shared and saved to Photos under, so each
    /// file is named after its spot rather than `pano.jpg`.
    var fileName: String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let base = name ?? "Orb \(format.string(from: date))"
        let safe = base.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".").union(.whitespacesAndNewlines))
        return safe.isEmpty ? "Orb" : safe
    }
}

@Observable @MainActor
final class CaptureStore {
    private(set) var captures: [CaptureRecord] = []
    /// Folder names, empty ones included, in Finder order.
    private(set) var folders: [String] = []

    nonisolated static let root = URL.documentsDirectory.appending(path: "Captures", directoryHint: .isDirectory)
    /// Outside `root`, whose loose files `load()` would clear away, and hidden from the Files app.
    nonisolated static let foldersURL = URL.applicationSupportDirectory.appending(path: "folders.json")

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
        let saved = (try? Data(contentsOf: Self.foldersURL)).flatMap { try? JSONDecoder().decode([String].self, from: $0) }
        folders = Self.sorted(Set(saved ?? []).union(found.compactMap(\.folder)))
    }

    func captures(in folder: String?) -> [CaptureRecord] { captures.filter { $0.folder == folder } }

    func rename(_ id: UUID, to name: String) {
        guard var record = record(id) else { return }
        record.name = Self.cleaned(name)
        save(record)
    }

    func move(_ id: UUID, to folder: String?) {
        guard var record = record(id) else { return }
        record.folder = folder
        save(record)
    }

    /// Adds a folder, or finds the one with that name. Nil for a blank name.
    @discardableResult func createFolder(_ name: String) -> String? {
        guard let name = Self.cleaned(name) else { return nil }
        if !folders.contains(name) { setFolders(folders + [name]) }
        return name
    }

    /// Renames a folder, merging it into any folder already called `newName`. Returns the name
    /// the folder ends up with.
    @discardableResult func renameFolder(_ folder: String, to newName: String) -> String {
        guard let newName = Self.cleaned(newName), newName != folder else { return folder }
        for var record in captures where record.folder == folder {
            record.folder = newName
            save(record)
        }
        setFolders(folders.filter { $0 != folder } + [newName])
        return newName
    }

    /// Removes a folder. Its panoramas aren't deleted; they move to the top level.
    func deleteFolder(_ folder: String) {
        for var record in captures where record.folder == folder {
            record.folder = nil
            save(record)
        }
        setFolders(folders.filter { $0 != folder })
    }

    private func setFolders(_ names: [String]) {
        folders = Self.sorted(Set(names))
        try? FileManager.default.createDirectory(at: Self.foldersURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(folders) { try? data.write(to: Self.foldersURL, options: .atomic) }
    }

    private static func sorted(_ names: Set<String>) -> [String] {
        names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private static func cleaned(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A link named `<fileName>.jpg` to the capture's `pano.jpg`, for sharing. It's the same
    /// bytes, so the GPS, capture time and 360° metadata go along unchanged.
    nonisolated static func namedPanorama(id: UUID, fileName: String) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appending(path: "Shared/\(id.uuidString)", directoryHint: .isDirectory)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let source = directory(for: id).appending(path: "pano.jpg")
        let link = dir.appending(path: "\(fileName).jpg")
        do { try fm.linkItem(at: source, to: link) } catch { try fm.copyItem(at: source, to: link) }
        return link
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
