import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// A panorama being dragged within Orb. Declared in project.yml.
    static let orbCapture = UTType(exportedAs: "com.nathanielcblack.orb.capture")
}

/// What a dragged panorama carries: which capture it is, nothing other apps would accept.
struct CaptureDrag: Codable, Transferable {
    let id: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .orbCapture)
    }
}

/// One folder's subfolders and panoramas. Captures taken from here are filed in it.
struct FolderView: View {
    @Environment(CaptureStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// State, so renaming the folder from here keeps showing it.
    @State private var path: String
    @State private var capturing = false
    @State private var prompt: NamePrompt?

    init(path: String) {
        _path = State(initialValue: path)
    }

    var body: some View {
        let records = store.captures(in: path)
        Group {
            if records.isEmpty && store.subfolders(of: path).isEmpty {
                ContentUnavailableView {
                    Label("No panoramas in \(FolderPath.name(path))", systemImage: "folder")
                } description: {
                    Text("Panoramas you capture from here are filed in this folder. To move one in, touch and hold it in the library.")
                }
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        FolderGrid(parent: path, prompt: $prompt)
                        CaptureGrid(records: records, prompt: $prompt)
                    }
                    .padding(16)
                }
            }
        }
        .navigationTitle(FolderPath.name(path))
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    prompt = NamePrompt(title: "New Folder") { store.createFolder($0, in: path) }
                } label: { Image(systemName: "folder.badge.plus") }
                .accessibilityLabel("New folder")
                Menu {
                    FolderMenu(path: path, prompt: $prompt, renamed: { path = $0 }, deleted: { dismiss() })
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .safeAreaInset(edge: .bottom) {
            ShutterButton { capturing = true }
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
                .background(.ultraThinMaterial)
        }
        .namePrompt($prompt)
        .fullScreenCover(isPresented: $capturing) { CaptureView(folder: path) }
    }
}

/// Rename, share, and delete for a folder, as a context menu or a toolbar menu.
struct FolderMenu: View {
    let path: String
    @Binding var prompt: NamePrompt?
    var renamed: (String) -> Void = { _ in }
    var deleted: () -> Void = {}
    @Environment(CaptureStore.self) private var store

    var body: some View {
        Button {
            prompt = NamePrompt(title: "Rename Folder", text: FolderPath.name(path)) { renamed(store.renameFolder(path, to: $0)) }
        } label: { Label("Rename", systemImage: "pencil") }
        let shared = SharedPanorama.all(store.captures(within: path))
        if !shared.isEmpty {
            ShareLink(items: shared) { SharePreview($0.fileName) } label: {
                Label("Share All (\(shared.count))", systemImage: "square.and.arrow.up")
            }
        }
        // Keeps the panoramas, so it needs no confirmation.
        Button(role: .destructive) {
            store.deleteFolder(path)
            deleted()
        } label: { Label("Delete Folder", systemImage: "folder.badge.minus") }
    }
}

/// Files a panorama at the top level, in a folder, or in a new folder beside it.
struct MoveToFolderMenu: View {
    let id: UUID
    @Binding var prompt: NamePrompt?
    @Environment(CaptureStore.self) private var store

    var body: some View {
        Menu {
            Picker("Folder", selection: Binding(get: { store.record(id)?.folder }, set: { store.move(id, to: $0) })) {
                Text("No Folder").tag(String?.none)
                ForEach(store.folders, id: \.self) { Text(FolderPath.label($0)).tag(String?.some($0)) }
            }
            Button {
                prompt = NamePrompt(title: "New Folder") { name in
                    if let folder = store.createFolder(name, in: store.record(id)?.folder) { store.move(id, to: folder) }
                }
            } label: { Label("New Folder", systemImage: "folder.badge.plus") }
        } label: { Label("Move to Folder", systemImage: "folder") }
    }
}

/// A request for a name: renaming a panorama or folder, or naming a new folder.
struct NamePrompt {
    var title: String
    var text = ""
    var save: (String) -> Void
}

extension View {
    /// Shows `prompt` as an alert with a text field while it's set.
    func namePrompt(_ prompt: Binding<NamePrompt?>) -> some View {
        alert(prompt.wrappedValue?.title ?? "", isPresented: Binding(get: { prompt.wrappedValue != nil },
                                                                        set: { if !$0 { prompt.wrappedValue = nil } })) {
            TextField("Name", text: Binding(get: { prompt.wrappedValue?.text ?? "" },
                                            set: { prompt.wrappedValue?.text = $0 }))
            Button("Cancel", role: .cancel) {}
            Button("Save") { if let p = prompt.wrappedValue { p.save(p.text) } }
        }
    }
}
