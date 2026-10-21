import SwiftUI
import SyncEngine

extension DeviceFile: Identifiable {
    public var id: String { filename }
}

/// The second half of "On device": files on the Kindle that no library book claims — sent by
/// calibre for a book since removed from the library, added by hand, or left by another app.
/// Listed so they can be cleaned up; deleting one removes the file only, never its `.sdr`
/// reading-progress folder, and the engine re-checks each one is still an orphan first.
struct OrphanFilesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        let files = model.orphans

        VStack(alignment: .leading, spacing: 0) {
            header(count: files.count)
            Divider()
            Table(files, selection: $model.orphanSelection) {
                TableColumn("Title") { file in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(model.orphanTitle(file)).lineLimit(1)
                        if let authors = model.orphanAuthors(file) {
                            Text(authors).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                .width(min: 200, ideal: 320)

                TableColumn("Folder") { file in
                    Text(folder(of: file)).foregroundStyle(.secondary).lineLimit(1)
                }

                TableColumn("Format") { file in
                    Text((file.filename as NSString).pathExtension.uppercased())
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }
                .width(60)

                TableColumn("On Kindle") { file in
                    if let date = file.modified {
                        Text(date, format: .dateTime.day().month(.abbreviated).year())
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .width(min: 80, ideal: 96)

                TableColumn("Size") { file in
                    Text(ByteCountFormatter.string(fromByteCount: Int64(file.size), countStyle: .file))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .width(70)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if !ids.isEmpty {
                    if model.isUSBDrive {
                        Button("Show in Finder", systemImage: "folder") {
                            Task { await model.revealOnKindle(Array(ids)) }
                        }
                    }
                    Button(deleteTitle(ids.count), systemImage: "trash", role: .destructive) {
                        model.requestOrphanDeletion(Array(ids))
                    }
                    .disabled(model.syncProgress != nil)
                }
            }
        }
        .confirmationDialog(
            prompt,
            isPresented: Binding(
                get: { !model.pendingOrphanDeletion.isEmpty },
                set: { if !$0 { model.pendingOrphanDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                let paths = model.pendingOrphanDeletion
                model.pendingOrphanDeletion = []
                Task { await model.deleteOrphans(paths) }
            }
            Button("Cancel", role: .cancel) { model.pendingOrphanDeletion = [] }
        } message: {
            Text("They are not in your library, so this cannot be undone from Bookshelf. Reading progress and notes (.sdr) stay on the Kindle.")
        }
    }

    private func header(count: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("On the Kindle, not in your library").font(.headline)
                Text("\(count) \(count == 1 ? "file" : "files") — right-click to delete")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !model.orphanSelection.isEmpty {
                Button(deleteTitle(model.orphanSelection.count), role: .destructive) {
                    model.requestOrphanDeletion(Array(model.orphanSelection))
                }
                .disabled(model.syncProgress != nil)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func folder(of file: DeviceFile) -> String {
        let folder = (file.filename as NSString).deletingLastPathComponent
        return folder.isEmpty ? "documents" : folder
    }

    private func deleteTitle(_ count: Int) -> String {
        count == 1 ? "Delete from Kindle…" : "Delete \(count) from Kindle…"
    }

    private var prompt: String {
        let paths = model.pendingOrphanDeletion
        guard paths.count == 1, let file = model.orphans.first(where: { $0.filename == paths[0] }) else {
            return "Delete \(paths.count) files from the Kindle?"
        }
        return "Delete “\(model.orphanTitle(file))” from the Kindle?"
    }
}
