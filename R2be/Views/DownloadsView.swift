import SwiftUI

/// Videos saved on the phone for offline playback, plus ones still downloading.
struct DownloadsView: View {
    @Environment(PlayerController.self) private var player
    @State private var store = DownloadStore.shared
    @State private var confirmRemoveAll = false

    private var downloaded: [VideoItem] { store.sortedEntries.map(\.item) }
    private struct Running: Identifiable { let id: String; let fraction: Double }
    private struct Failure: Identifiable { let id: String; let message: String }

    private var inProgress: [Running] {
        store.progress.map { Running(id: $0.key, fraction: $0.value) }.sorted { $0.id < $1.id }
    }
    private var failures: [Failure] {
        store.failed.map { Failure(id: $0.key, message: $0.value) }.sorted { $0.id < $1.id }
    }

    var body: some View {
        List {
            if downloaded.isEmpty && inProgress.isEmpty {
                ContentUnavailableView {
                    Label("No downloads", systemImage: "arrow.down.circle")
                } description: {
                    Text("Long-press a video → Download, or select several in the Library and tap ↓. Downloads play without a connection.")
                }
                .listRowBackground(Color.clear)
            }

            if !inProgress.isEmpty {
                Section("Downloading") {
                    ForEach(inProgress) { row in
                        HStack(spacing: 10) {
                            ProgressView(value: row.fraction).frame(width: 80)
                            Text(VideoItem.title(fromPath: row.id)).font(.subheadline).lineLimit(1)
                            Spacer()
                            Text("\(Int(row.fraction * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if !failures.isEmpty {
                Section("Failed") {
                    ForEach(failures) { f in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(VideoItem.title(fromPath: f.id)).font(.subheadline).lineLimit(1)
                            Text(f.message).font(.caption).foregroundStyle(.red).lineLimit(2)
                        }
                    }
                }
            }

            if !downloaded.isEmpty {
                Section {
                    HStack(spacing: 10) {
                        PillButton(title: "Play all", systemImage: "play.fill", prominent: true) {
                            player.play(downloaded, shuffle: false, title: "Downloads")
                        }
                        PillButton(title: "Shuffle", systemImage: "shuffle") {
                            player.shufflePlay(downloaded, title: "Downloads")
                        }
                    }
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))

                    ForEach(store.sortedEntries) { e in
                        Button {
                            player.play(downloaded, startAt: e.item, shuffle: false, title: "Downloads")
                        } label: {
                            HStack(spacing: 10) {
                                ThumbnailView(item: e.item).frame(width: 112).clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(e.item.title).font(.subheadline).lineLimit(2)
                                    Text("\(e.item.folderDisplay) · \(Format.bytes(e.bytes))")
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                        }
                        .buttonStyle(.plain)
                        .swipeActions {
                            Button(role: .destructive) { store.remove(e.item) } label: { Label("Remove", systemImage: "trash") }
                        }
                    }
                } header: {
                    Text("\(downloaded.count) on this iPhone · \(Format.bytes(store.totalBytes))")
                } footer: {
                    Text("Swipe left to remove a download. Downloads are kept on the phone only and don't count toward iCloud backup.")
                }
            }
        }
        .navigationTitle("Downloads")
        .toolbar {
            if !downloaded.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Remove all", role: .destructive) { confirmRemoveAll = true }
                }
            }
        }
        .confirmationDialog("Remove all \(downloaded.count) downloads from this iPhone?", isPresented: $confirmRemoveAll,
                            titleVisibility: .visible) {
            Button("Remove all", role: .destructive) { store.removeAll() }
        }
    }
}

/// Menu items for downloading one or more videos, used in long-press menus and the player's menu.
struct DownloadMenuItems: View {
    let items: [VideoItem]
    @Environment(LibraryStore.self) private var library
    @State private var store = DownloadStore.shared

    var body: some View {
        if items.count == 1, let item = items.first {
            if store.isDownloaded(item) {
                Button(role: .destructive) { store.remove(item) } label: { Label("Remove Download", systemImage: "trash") }
            } else if store.isDownloading(item) {
                Button { store.cancel(item) } label: {
                    Label("Cancel Download (\(Int((store.progress[item.id] ?? 0) * 100))%)", systemImage: "xmark.circle")
                }
            } else {
                Button { library.download([item]) } label: { Label("Download", systemImage: "arrow.down.circle") }
            }
        } else if !items.isEmpty {
            let remaining = items.filter { !store.isDownloaded($0) && !store.isDownloading($0) }
            Button { library.download(remaining) } label: {
                Label(remaining.isEmpty ? "All Downloaded" : "Download \(remaining.count) Videos", systemImage: "arrow.down.circle")
            }
            .disabled(remaining.isEmpty)
        }
    }
}
