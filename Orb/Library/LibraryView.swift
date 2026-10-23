import SwiftUI

struct LibraryView: View {
    @Environment(CaptureStore.self) private var store
    @State private var capturing = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if store.captures.isEmpty {
                    ContentUnavailableView {
                        Label("No panoramas yet", systemImage: "globe.americas")
                    } description: {
                        Text("Tap the shutter, then follow the dots around you. Orb takes the shots and stitches a full 360° sphere on the phone.")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 14)], spacing: 18) {
                            ForEach(store.captures) { record in
                                NavigationLink(value: record.id) { LibraryCell(record: record) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button(role: .destructive) { store.delete(record.id) } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Orb")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: UUID.self) { PanoDetailView(id: $0) }
            .safeAreaInset(edge: .bottom) {
                ShutterButton { capturing = true }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
            }
        }
        .fullScreenCover(isPresented: $capturing) { CaptureView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

private struct LibraryCell: View {
    let record: CaptureRecord
    @Environment(CaptureStore.self) private var store
    @Environment(StitchService.self) private var stitcher

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                ThumbnailImage(url: store.thumbnailURL(record.id), version: record.panorama?.date)
                if let job = stitcher.jobs[record.id] {
                    Color.black.opacity(0.45)
                    VStack(spacing: 8) {
                        ProgressView(value: job.fraction).tint(.yellow).frame(width: 96)
                        Text(job.stage).font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.white)
                } else if record.stitchError != nil {
                    Color.black.opacity(0.45)
                    Image(systemName: "exclamationmark.triangle.fill").font(.title).foregroundStyle(.yellow)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text(record.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.subheadline.weight(.medium))
            Text("\(record.shots.count) shots · \(record.lens == .ultraWide ? "0.5×" : "1×")")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct ThumbnailImage: View {
    let url: URL
    let version: Date?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(Color(white: 0.12))
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "globe").font(.largeTitle).foregroundStyle(.tertiary)
            }
        }
        .task(id: version) { image = UIImage(contentsOfFile: url.path) }
    }
}

private struct ShutterButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().stroke(.white, lineWidth: 4).frame(width: 74, height: 74)
                Circle().fill(.white).frame(width: 60, height: 60)
                Image(systemName: "rotate.3d").font(.title2.weight(.semibold)).foregroundStyle(.black)
            }
        }
        .accessibilityLabel("New 360° capture")
    }
}
