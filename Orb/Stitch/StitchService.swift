import Foundation
import Observation
import PanoCore
import UIKit

/// Stitches captures one at a time off the main thread and publishes progress per capture.
@Observable @MainActor
final class StitchService {
    struct Progress: Equatable {
        var fraction: Double
        var stage: String
    }

    private(set) var jobs: [UUID: Progress] = [:]
    private var queue: [(id: UUID, width: Int)] = []
    private var running = false
    private let store: CaptureStore

    init(store: CaptureStore) {
        self.store = store
    }

    func enqueue(_ id: UUID, outputWidth: Int) {
        guard jobs[id] == nil else { return }
        jobs[id] = Progress(fraction: 0, stage: "Waiting")
        queue.append((id, outputWidth))
        runNext()
    }

    func resumeUnfinished(outputWidth: Int) {
        for r in store.captures where r.panorama == nil && r.stitchError == nil {
            enqueue(r.id, outputWidth: outputWidth)
        }
    }

    private func runNext() {
        guard !running, !queue.isEmpty else { return }
        let (id, width) = queue.removeFirst()
        guard let record = store.record(id) else {
            jobs[id] = nil
            runNext()
            return
        }
        running = true
        let directory = CaptureStore.directory(for: id)
        let background = BackgroundTask(name: "Stitch panorama")
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result {
                try StitchJob.run(record: record, directory: directory, outputWidth: width) { fraction, stage in
                    Task { @MainActor in self?.report(id, fraction, stage) }
                }
            }
            await MainActor.run {
                background.end()
                guard let self else { return }
                defer {
                    self.jobs[id] = nil
                    self.running = false
                    self.runNext()
                }
                // Deleted while stitching: don't bring it back.
                guard var updated = self.store.record(id) else { return }
                switch result {
                case .success(let info):
                    updated.panorama = info
                    updated.stitchError = nil
                case .failure(let error):
                    updated.stitchError = error.localizedDescription
                }
                self.store.save(updated)
            }
        }
    }

    private func report(_ id: UUID, _ fraction: Double, _ stage: String) {
        guard let old = jobs[id] else { return }
        if stage != old.stage || fraction - old.fraction >= 0.01 || fraction >= 1 {
            jobs[id] = Progress(fraction: fraction, stage: stage)
        }
    }
}

/// Asks iOS for time to finish a stitch if the app goes to the background.
@MainActor
private final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}

enum StitchJob {
    /// Decodes the shots at the resolution the output needs, stitches, and writes
    /// `pano.jpg` (with 360° metadata, capture time, and GPS if the capture has a location),
    /// `planet.jpg` and `thumb.jpg` into the capture folder.
    static func run(record: CaptureRecord, directory: URL, outputWidth: Int,
                    progress: @escaping @Sendable (Double, String) -> Void) throws -> PanoramaInfo {
        guard record.shots.count >= 2 else { throw StitchError.tooFewShots }
        progress(0, "Loading")
        // Source pixels per radian slightly above the output's, so nothing is upsampled.
        let maxSide = Int(record.longFOV * Double(outputWidth) / (2 * .pi) * 1.15)
        var shots: [StitchShot] = []
        for (k, shot) in record.shots.enumerated() {
            let image = try ImageCodec.decode(directory.appending(path: shot.file), maxPixelSize: maxSide)
            // Photos are written upright (EXIF orientation applied on decode). Should one come
            // back in the sensor's landscape layout, use that layout's axes instead.
            let axes = image.width > image.height ? deviceFromNativeBackCamera : deviceFromBackCamera
            let focal = PinholeCamera.focal(longSide: max(image.width, image.height), longSideFOV: record.longFOV)
            shots.append(StitchShot(image: image, rotation: Mat3(rowMajor: shot.deviceRotation) * axes, focal: focal))
            progress(0.08 * Double(k + 1) / Double(record.shots.count), "Loading")
        }

        let (pano, report) = Stitcher.stitch(shots, options: StitchOptions(outputWidth: outputWidth)) { f, stage in
            progress(0.08 + 0.8 * f, stage)
        }
        shots.removeAll()

        progress(0.9, "Saving")
        let panoURL = directory.appending(path: "pano.jpg")
        try ImageCodec.writeJPEG(pano, to: panoURL, quality: 0.92, equirectangular: true,
                                 location: record.location, date: record.date)
        let small = pano.width > 4096 ? pano.resized(width: 4096, height: 2048) : pano
        let planet = PanoRender.littlePlanet(small, size: 2048)
        try ImageCodec.writeJPEG(planet, to: directory.appending(path: "planet.jpg"), quality: 0.9)
        try ImageCodec.writeJPEG(planet.resized(maxSide: 480), to: directory.appending(path: "thumb.jpg"), quality: 0.85)
        progress(1, "Done")

        return PanoramaInfo(width: pano.width, height: pano.height, seconds: report.seconds,
                            alignmentDegrees: report.rounds.last?.rmsAfterDegrees,
                            matches: report.rounds.last?.matches ?? 0, date: Date())
    }
}

enum StitchError: LocalizedError {
    case tooFewShots
    var errorDescription: String? { "At least two shots are needed to stitch." }
}
