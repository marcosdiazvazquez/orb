import Photos
import SwiftUI

struct PanoDetailView: View {
    let id: UUID
    @Environment(CaptureStore.self) private var store
    @Environment(StitchService.self) private var stitcher
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.output) private var output: OutputQuality = .high
    @State private var mode: PanoViewMode = .look
    @State private var gyro = false
    /// Compass bearing the view faces, if the panorama has a heading.
    @State private var bearing: Double?
    @State private var showInfo = false
    @State private var confirmDelete = false
    @State private var alert: String?
    @State private var prompt: NamePrompt?

    private var record: CaptureRecord? { store.record(id) }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let record, let pano = record.panorama {
                PanoViewer(url: store.panoramaURL(id), version: pano.date, mode: $mode, gyro: gyro,
                           heading: pano.heading, onBearing: { bearing = $0 })
                    .ignoresSafeArea()
            }
            if let job = stitcher.jobs[id] {
                VStack(spacing: 12) {
                    ProgressView(value: job.fraction).tint(.yellow).frame(width: 200)
                    Text(job.stage == "Waiting" ? "Waiting to stitch…" : "\(job.stage)…")
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            } else if let error = record?.stitchError {
                VStack(spacing: 12) {
                    Text("Stitching failed").font(.headline)
                    Text(error).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    HStack {
                        Button("Delete", role: .destructive) { confirmDelete = true }
                            .buttonStyle(.bordered)
                        Button("Try again") { stitcher.enqueue(id, outputWidth: output.rawValue) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .padding(24)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
                .padding(24)
            }
        }
        .overlay(alignment: .top) {
            if mode == .look, record?.panorama?.heading != nil, let bearing {
                BearingLabel(degrees: bearing).padding(.top, 8)
            }
        }
        .navigationTitle(record.map { $0.name ?? $0.date.formatted(date: .abbreviated, time: .shortened) } ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar { if record?.panorama != nil { bottomBar } }
        .sheet(isPresented: $showInfo) { if let record { InfoSheet(record: record) } }
        .confirmationDialog("Delete this panorama and its shots?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(id)
                dismiss()
            }
        }
        .alert(alert ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {
            Button("OK", role: .cancel) {}
        }
        .namePrompt($prompt)
        .onAppear { OrientationLock.allow(.allButUpsideDown) }
        .onDisappear { OrientationLock.allow(.portrait) }
    }

    @ToolbarContentBuilder private var bottomBar: some ToolbarContent {
        ToolbarItemGroup(placement: .bottomBar) {
            Button { gyro.toggle() } label: {
                Image(systemName: gyro ? "gyroscope" : "hand.draw")
            }
            .disabled(mode == .planet)
            .accessibilityLabel(gyro ? "Steer with touch" : "Steer by moving the phone")
            Spacer()
            Button { mode = mode == .look ? .planet : .look } label: {
                Image(systemName: mode == .look ? "globe.americas" : "view.3d")
            }
            .accessibilityLabel(mode == .look ? "Little planet" : "Look around")
            Spacer()
            if let record {
                ShareLink(item: SharedPanorama(record), preview: SharePreview(record.title)) {
                    Image(systemName: "square.and.arrow.up")
                }
            }
            Spacer()
            Menu {
                Button {
                    prompt = NamePrompt(title: "Rename", text: record?.name ?? "") { store.rename(id, to: $0) }
                } label: { Label("Rename", systemImage: "pencil") }
                MoveToFolderMenu(id: id, prompt: $prompt)
                Divider()
                Button { Task { await saveToPhotos() } } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                ShareLink(item: store.planetURL(id)) { Label("Share Little Planet", systemImage: "globe.europe.africa") }
                Menu {
                    ForEach(OutputQuality.allCases) { q in
                        Button(q.label) { stitcher.enqueue(id, outputWidth: q.rawValue) }
                    }
                } label: { Label("Re-stitch", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(stitcher.jobs[id] != nil)
                Button { showInfo = true } label: { Label("Details", systemImage: "info.circle") }
                Divider()
                Button(role: .destructive) { confirmDelete = true } label: { Label("Delete", systemImage: "trash") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
    }

    private func saveToPhotos() async {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            alert = "Orb isn't allowed to add photos. Allow it in Settings › Orb › Photos."
            return
        }
        let url = store.panoramaURL(id)
        let fileName = "\(record?.fileName ?? "Orb").jpg"
        do {
            // Adding the file itself keeps the 360° metadata intact; the original file name is
            // what Photos exports it as.
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = fileName
                PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: url, options: options)
            }
            alert = "Saved to Photos. Google Photos and Facebook show it as a 360° photo."
        } catch {
            alert = error.localizedDescription
        }
    }
}

private struct InfoSheet: View {
    let record: CaptureRecord
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                LabeledContent("Captured", value: record.date.formatted(date: .long, time: .shortened))
                LabeledContent("Shots", value: "\(record.shots.count) of \(record.plannedShots)")
                LabeledContent("Lens", value: "\(record.lens.label), \(Int((record.longFOV * 180 / .pi).rounded()))°")
                LabeledContent("Location", value: record.location.map {
                    String(format: "%.5f, %.5f (±%.0f m)", $0.latitude, $0.longitude, $0.accuracy)
                } ?? "Not recorded")
                LabeledContent("Heading", value: record.heading.map { h in
                    let centre = record.panorama?.heading.map { "Centre \(Bearing.label($0)), " } ?? ""
                    return centre + String(format: "±%.0f°", h.spread) + (h.trueNorth ? "" : " (magnetic)")
                } ?? "Not recorded")
                if let p = record.panorama {
                    LabeledContent("Panorama", value: "\(p.width) × \(p.height)")
                    LabeledContent("Stitch time", value: String(format: "%.1f s", p.seconds))
                    if let a = p.alignmentDegrees {
                        LabeledContent("Alignment", value: String(format: "%.3f° RMS, %d matches", a, p.matches))
                    }
                }
            }
            .navigationTitle("Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}
