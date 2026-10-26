import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// A panorama shared as `<name>.jpg` instead of `pano.jpg`, with its metadata intact. The named
/// file is made only when the user picks where to send it.
struct SharedPanorama: Transferable {
    let id: UUID
    let fileName: String

    init(_ record: CaptureRecord, fileName: String? = nil) {
        id = record.id
        self.fileName = fileName ?? record.fileName
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .jpeg) { item in
            SentTransferredFile(try CaptureStore.namedPanorama(id: item.id, fileName: item.fileName))
        }
    }

    /// The stitched panoramas among `records`, with repeated names numbered ("Steps", "Steps 2")
    /// so that sending them together doesn't overwrite any.
    static func all(_ records: [CaptureRecord]) -> [SharedPanorama] {
        var seen: [String: Int] = [:]
        return records.filter { $0.panorama != nil }.map { record in
            let key = record.fileName.lowercased()
            let n = (seen[key] ?? 0) + 1
            seen[key] = n
            return SharedPanorama(record, fileName: n == 1 ? record.fileName : "\(record.fileName) \(n)")
        }
    }
}
