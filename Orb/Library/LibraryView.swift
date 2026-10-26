import SwiftUI

struct LibraryView: View {
    @Environment(CaptureStore.self) private var store
    @State private var capturing = false
    @State private var showSettings = false
    @State private var prompt: NamePrompt?

    var body: some View {
        NavigationStack {
            Group {
                if store.captures.isEmpty && store.folders.isEmpty {
                    ContentUnavailableView {
                        Label("No panoramas yet", systemImage: "globe.americas")
                    } description: {
                        Text("Tap the shutter, then follow the dots around you. Orb takes the shots and stitches a full 360° sphere on the phone.")
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 18) {
                            if !store.folders.isEmpty {
                                LazyVGrid(columns: CaptureGrid.columns, spacing: 18) {
                                    ForEach(store.folders, id: \.self) { name in
                                        NavigationLink(value: FolderRoute(name: name)) { FolderCell(name: name) }
                                            .buttonStyle(.plain)
                                            .contextMenu { FolderMenu(name: name, prompt: $prompt) }
                                    }
                                }
                            }
                            CaptureGrid(records: store.captures(in: nil), prompt: $prompt)
                        }
                        .padding(16)
                    }
                }
            }
            .navigationTitle("Orb")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        prompt = NamePrompt(title: "New Folder") { store.createFolder($0) }
                    } label: { Image(systemName: "folder.badge.plus") }
                    .accessibilityLabel("New folder")
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
            }
            .navigationDestination(for: UUID.self) { PanoDetailView(id: $0) }
            .navigationDestination(for: FolderRoute.self) { FolderView(name: $0.name) }
            .safeAreaInset(edge: .bottom) {
                ShutterButton { capturing = true }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                    .background(.ultraThinMaterial)
            }
            .namePrompt($prompt)
        }
        .fullScreenCover(isPresented: $capturing) { CaptureView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

struct FolderRoute: Hashable {
    let name: String
}

/// Panoramas, newest first, each opening its detail view.
struct CaptureGrid: View {
    static let columns = [GridItem(.adaptive(minimum: 160), spacing: 14)]

    let records: [CaptureRecord]
    @Binding var prompt: NamePrompt?
    @Environment(CaptureStore.self) private var store

    var body: some View {
        LazyVGrid(columns: Self.columns, spacing: 18) {
            ForEach(records) { record in
                NavigationLink(value: record.id) { LibraryCell(record: record) }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            prompt = NamePrompt(title: "Rename", text: record.name ?? "") { store.rename(record.id, to: $0) }
                        } label: { Label("Rename", systemImage: "pencil") }
                        MoveToFolderMenu(id: record.id, prompt: $prompt)
                        if record.panorama != nil {
                            ShareLink(item: SharedPanorama(record), preview: SharePreview(record.title)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                        }
                        Button(role: .destructive) { store.delete(record.id) } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
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

            Text(record.title)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Group {
                if record.name != nil {
                    Text(record.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                } else {
                    Text("\(record.shots.count) shots · \(record.lens == .ultraWide ? "0.5×" : "1×")")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

/// A folder, shown with its newest panorama as the cover.
private struct FolderCell: View {
    let name: String
    @Environment(CaptureStore.self) private var store

    var body: some View {
        let records = store.captures(in: name)
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                if let cover = records.first {
                    ThumbnailImage(url: store.thumbnailURL(cover.id), version: cover.panorama?.date)
                } else {
                    Rectangle().fill(Color(white: 0.12))
                }
                Image(systemName: "folder.fill")
                    .font(.title3)
                    .foregroundStyle(.yellow)
                    .padding(10)
                    .shadow(radius: 3)
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            Text(name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Text(records.count == 1 ? "1 panorama" : "\(records.count) panoramas")
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

struct ShutterButton: View {
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
