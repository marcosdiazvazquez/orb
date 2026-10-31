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
    /// Free text about the panorama, of any length. Unlike the name, it isn't the title or the
    /// file name, and it isn't in `pano.jpg`, so it stays behind when the panorama is shared.
    var description: String?
    /// The path of the folder it's filed in (see `FolderPath`); nil is the top level of the library.
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

/// A folder is known by its path from the top of the library, such as `Trips/Italy`.
enum FolderPath {
    static func components(_ path: String) -> [String] { path.split(separator: "/").map(String.init) }

    /// What the folder itself is called.
    static func name(_ path: String) -> String { components(path).last ?? path }

    /// The folder it's in; nil at the top level.
    static func parent(_ path: String) -> String? {
        let above = components(path).dropLast()
        return above.isEmpty ? nil : above.joined(separator: "/")
    }

    static func child(_ name: String, of parent: String?) -> String { parent.map { "\($0)/\(name)" } ?? name }

    /// For menus that list every folder, where the name alone could be ambiguous.
    static func label(_ path: String) -> String { components(path).joined(separator: " › ") }

    /// Whether `path` is `folder` or anywhere inside it.
    static func contains(_ folder: String, _ path: String) -> Bool { path == folder || path.hasPrefix(folder + "/") }
}

@Observable @MainActor
final class CaptureStore {
    private(set) var captures: [CaptureRecord] = []
    /// Folder paths, empty folders included, each followed by what's inside it, in Finder order.
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
        folders = Self.tree((saved ?? []) + found.compactMap(\.folder))
    }

    /// The panoramas directly in `folder`; nil is the top level.
    func captures(in folder: String?) -> [CaptureRecord] { captures.filter { $0.folder == folder } }

    /// The panoramas in `folder` and its subfolders.
    func captures(within folder: String) -> [CaptureRecord] {
        captures.filter { $0.folder.map { FolderPath.contains(folder, $0) } ?? false }
    }

    /// The folders directly in `folder`; nil is the top level.
    func subfolders(of folder: String?) -> [String] { folders.filter { FolderPath.parent($0) == folder } }

    func rename(_ id: UUID, to name: String) {
        guard var record = record(id) else { return }
        record.name = Self.cleaned(name)
        save(record)
    }

    func describe(_ id: UUID, as description: String) {
        guard var record = record(id) else { return }
        record.description = Self.cleaned(description)
        save(record)
    }

    func move(_ id: UUID, to folder: String?) {
        guard var record = record(id) else { return }
        record.folder = folder
        save(record)
    }

    /// Adds a folder inside `parent`, or finds the one with that name there. Returns its path, or
    /// nil for a blank name.
    @discardableResult func createFolder(_ name: String, in parent: String? = nil) -> String? {
        guard let name = Self.folderName(name) else { return nil }
        let path = FolderPath.child(name, of: parent)
        if !folders.contains(path) { setFolders(folders + [path]) }
        return path
    }

    /// Renames a folder, merging it into any folder beside it already called `newName`. Returns
    /// the path the folder ends up with.
    @discardableResult func renameFolder(_ folder: String, to newName: String) -> String {
        guard let name = Self.folderName(newName) else { return folder }
        let path = FolderPath.child(name, of: FolderPath.parent(folder))
        if path != folder { relocate(folder, to: path) }
        return path
    }

    /// Removes a folder. What's in it isn't deleted: its panoramas and subfolders move up a level.
    func deleteFolder(_ folder: String) { relocate(folder, to: FolderPath.parent(folder)) }

    /// Makes everything in `folder` belong to `destination` instead, merging with what's there.
    private func relocate(_ folder: String, to destination: String?) {
        func moved(_ path: String) -> String? {
            guard FolderPath.contains(folder, path) else { return path }
            return path == folder ? destination : FolderPath.child(String(path.dropFirst(folder.count + 1)), of: destination)
        }
        for var record in captures(within: folder) {
            record.folder = record.folder.flatMap(moved)
            save(record)
        }
        setFolders(folders.compactMap(moved))
    }

    private func setFolders(_ paths: [String]) {
        folders = Self.tree(paths)
        try? FileManager.default.createDirectory(at: Self.foldersURL.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(folders) { try? data.write(to: Self.foldersURL, options: .atomic) }
    }

    /// `paths` and the folders above them, each followed by what's inside it, in Finder order.
    private static func tree(_ paths: [String]) -> [String] {
        var all = Set<String>()
        for path in paths {
            var folder: String? = path
            while let current = folder {
                all.insert(current)
                folder = FolderPath.parent(current)
            }
        }
        return all.sorted { a, b in
            let (x, y) = (FolderPath.components(a), FolderPath.components(b))
            if let (p, q) = zip(x, y).first(where: { $0 != $1 }) { return p.localizedStandardCompare(q) == .orderedAscending }
            return x.count < y.count
        }
    }

    /// A slash in a folder's name would read as a level of the path.
    private static func folderName(_ name: String) -> String? {
        cleaned(name.replacingOccurrences(of: "/", with: "-"))
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
