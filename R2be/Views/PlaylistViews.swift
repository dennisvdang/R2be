import SwiftUI

struct PlaylistsView: View {
    @Environment(PlaylistStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player

    @State private var creating = false
    @State private var newName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""
    @State private var mergeMode = false
    @State private var mergeSelection: Set<UUID> = []
    @State private var mergeName = ""
    @State private var askMergeName = false

    var body: some View {
        List {
            if store.playlists.isEmpty {
                ContentUnavailableView {
                    Label("No playlists yet", systemImage: "music.note.list")
                } description: {
                    Text("Tap ☑︎ in the Library to pick videos, or long-press a video → Add to Playlist. Nothing in R2 is changed.")
                } actions: {
                    Button("New Playlist") { creating = true }.buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }
            ForEach(store.playlists) { p in
                let videos = library.resolve(p)
                if mergeMode {
                    Button {
                        if mergeSelection.contains(p.id) { mergeSelection.remove(p.id) } else { mergeSelection.insert(p.id) }
                    } label: {
                        HStack {
                            Image(systemName: mergeSelection.contains(p.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(mergeSelection.contains(p.id) ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
                            PlaylistRow(playlist: p, videos: videos, isFavorites: store.isFavorites(p.id))
                        }
                    }
                    .buttonStyle(.plain)
                } else {
                    NavigationLink(value: p.id) { PlaylistRow(playlist: p, videos: videos, isFavorites: store.isFavorites(p.id)) }
                        .swipeActions(edge: .trailing) {
                            if !store.isFavorites(p.id) {
                                Button(role: .destructive) { store.delete(p.id) } label: { Label("Delete", systemImage: "trash") }
                            }
                            Button { renameText = p.name; renaming = p } label: { Label("Rename", systemImage: "pencil") }
                        }
                        .swipeActions(edge: .leading) {
                            Button { player.shufflePlay(videos, context: .playlist(p.id), title: p.name) } label: {
                                Label("Shuffle", systemImage: "shuffle")
                            }
                            .tint(.red)
                        }
                        .contextMenu {
                            Button("Play", systemImage: "play.fill") { player.play(videos, shuffle: false, context: .playlist(p.id), title: p.name) }
                            Button("Shuffle", systemImage: "shuffle") { player.shufflePlay(videos, context: .playlist(p.id), title: p.name) }
                            Button("Rename", systemImage: "pencil") { renameText = p.name; renaming = p }
                            Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate(p.id) }
                            if !store.isFavorites(p.id) {
                                Button("Delete", systemImage: "trash", role: .destructive) { store.delete(p.id) }
                            }
                        }
                }
            }
        }
        .navigationTitle("Playlists")
        .navigationDestination(for: UUID.self) { PlaylistDetailView(playlistID: $0) }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                if store.playlists.count > 1 {
                    Button(mergeMode ? "Cancel" : "Combine") {
                        mergeMode.toggle()
                        mergeSelection = []
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                if mergeMode {
                    Button("Combine \(mergeSelection.count)") { mergeName = ""; askMergeName = true }
                        .disabled(mergeSelection.count < 2)
                } else {
                    Button { newName = ""; creating = true } label: { Image(systemName: "plus") }
                }
            }
        }
        .alert("New Playlist", isPresented: $creating) {
            TextField("Name", text: $newName)
            Button("Create") { store.create(name: newName) }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Save") { if let r = renaming { store.rename(r.id, to: renameText) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Combine into new playlist", isPresented: $askMergeName) {
            TextField("Name", text: $mergeName)
            Button("Combine") {
                let ordered = store.playlists.map(\.id).filter(mergeSelection.contains)
                store.merge(ordered, name: mergeName.isEmpty ? "Combined" : mergeName)
                mergeMode = false
                mergeSelection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The originals are kept.")
        }
    }
}

private struct PlaylistRow: View {
    let playlist: Playlist
    let videos: [VideoItem]
    var isFavorites = false

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let first = videos.first { ThumbnailView(item: first, showsBadges: false) }
                else {
                    Color(white: 0.15).aspectRatio(16 / 9, contentMode: .fit)
                        .overlay(Image(systemName: isFavorites ? "heart.fill" : "music.note.list").foregroundStyle(isFavorites ? Color.red : Color.secondary))
                }
            }
            .frame(width: 104)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .trailing) {
                Text("\(videos.count)").font(.caption.weight(.bold))
                    .frame(maxHeight: .infinity).frame(width: 34)
                    .background(.black.opacity(0.7))
                    .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 8, topTrailingRadius: 8))
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    if isFavorites { Image(systemName: "heart.fill").font(.caption).foregroundStyle(.red) }
                    Text(playlist.name).font(.body.weight(.medium)).lineLimit(1)
                }
                Text(sourceSummary).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var sourceSummary: String {
        let folders = playlist.entries.filter { if case .folder = $0 { return true }; return false }.count
        let files = playlist.entries.count - folders
        var parts = ["\(videos.count) videos"]
        if folders > 0 { parts.append("\(folders) live folder\(folders == 1 ? "" : "s")") }
        if files > 0 && folders > 0 { parts.append("\(files) files") }
        return parts.joined(separator: " · ")
    }
}

struct PlaylistDetailView: View {
    let playlistID: UUID
    @Environment(PlaylistStore.self) private var store
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @AppStorage("galleryLayout") private var layoutRaw = GalleryLayout.grid.rawValue

    enum Tab: String, CaseIterable { case videos = "Videos", sources = "Sources" }
    @State private var tab: Tab = .videos
    @State private var pendingAdd: PendingPlaylistAdd?
    @State private var addingVideos = false
    @State private var query = ""

    private var playlist: Playlist? { store.playlist(playlistID) }
    private var videos: [VideoItem] {
        guard let playlist else { return [] }
        let all = library.resolve(playlist)
        let tokens = SearchMatcher.tokens(query)
        return tokens.isEmpty ? all : all.filter { SearchMatcher.matches($0, tokens: tokens) }
    }

    var body: some View {
        Group {
            if let playlist {
                switch tab {
                case .videos: videosTab(playlist)
                case .sources: sourcesTab(playlist)
                }
            } else {
                ContentUnavailableView("Playlist deleted", systemImage: "trash")
            }
        }
        .navigationTitle(playlist?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented).frame(width: 200)
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Add videos…", systemImage: "plus.rectangle.on.rectangle") { addingVideos = true }
                    if tab == .videos {
                        Picker("Layout", selection: $layoutRaw) {
                            ForEach(GalleryLayout.allCases) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
                        }
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .sheet(item: $pendingAdd) { AddToPlaylistSheet(pending: $0) }
        .sheet(isPresented: $addingVideos) { VideoPickerSheet(playlistID: playlistID) }
    }

    private func videosTab(_ p: Playlist) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 10) {
                    PillButton(title: "Play", systemImage: "play.fill", prominent: true) {
                        player.play(videos, shuffle: false, context: .playlist(p.id), title: p.name)
                    }
                    PillButton(title: "Shuffle", systemImage: "shuffle") {
                        player.shufflePlay(videos, context: .playlist(p.id), title: p.name)
                    }
                }
                .padding(.horizontal, 16)
                .disabled(videos.isEmpty)

                VideoGallery(videos: videos,
                             layout: GalleryLayout(rawValue: layoutRaw) ?? .grid,
                             showFolderPath: true,
                             onPlay: { v in player.play(videos, startAt: v, context: .playlist(p.id), title: p.name) },
                             onAddToPlaylist: { pendingAdd = PendingPlaylistAdd(entries: $0) })

                if videos.isEmpty && query.isEmpty {
                    ContentUnavailableView {
                        Label("Empty playlist", systemImage: "music.note.list")
                    } description: {
                        Text("Pick videos from your library to add here.")
                    } actions: {
                        Button("Add videos…") { addingVideos = true }.buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search this playlist")
    }

    private func sourcesTab(_ p: Playlist) -> some View {
        List {
            Section {
                ForEach(p.entries) { entry in
                    SourceRow(entry: entry)
                }
                .onDelete { idx in store.remove(entryIDs: Set(idx.map { p.entries[$0].id }), from: p.id) }
                .onMove { store.move(in: p.id, from: $0, to: $1) }
            } footer: {
                Text("Drag to change play order, or delete to remove. Videos are never added twice.")
            }
            Section {
                Button { addingVideos = true } label: { Label("Add videos…", systemImage: "plus.rectangle.on.rectangle") }
            }
        }
        .environment(\.editMode, .constant(.active))
    }
}

private struct SourceRow: View {
    let entry: PlaylistEntry
    @Environment(LibraryStore.self) private var library

    var body: some View {
        switch entry {
        case .video(let b, let k):
            if let v = library.video(bucket: b, key: k) {
                HStack(spacing: 10) {
                    ThumbnailView(item: v, showsBadges: false).frame(width: 80).clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading) {
                        Text(v.title).font(.subheadline).lineLimit(1)
                        Text(v.folderDisplay).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            } else {
                Label("Missing: \(k)", systemImage: "exclamationmark.triangle").foregroundStyle(.secondary).font(.caption)
            }
        case .folder(let b, let prefix, let recursive):
            let count = library.videos(under: prefix, recursive: recursive, bucket: b).count
            HStack(spacing: 10) {
                Image(systemName: recursive ? "folder.fill.badge.plus" : "folder.fill").foregroundStyle(.yellow).frame(width: 80)
                VStack(alignment: .leading) {
                    Text(prefix.isEmpty ? "/ (bucket root)" : String(prefix.dropLast())).font(.subheadline).lineLimit(2)
                    Text("\(count) videos · \(recursive ? "incl. subfolders" : "this folder only")\(b == library.activeBucket ? "" : " · \(b)")")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Browse the bucket's folders and tick individual videos to add to a playlist. Videos already in
/// the playlist show as added and can't be picked again.
struct VideoPickerSheet: View {
    let playlistID: UUID
    @Environment(\.dismiss) private var dismiss
    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var store
    @State private var picked: Set<String> = []   // VideoItem.id

    private var existing: Set<String> {
        guard let p = store.playlist(playlistID) else { return [] }
        return Set(library.resolve(p).map(\.id))
    }

    var body: some View {
        let alreadyIn = self.existing
        NavigationStack {
            VideoPickerLevel(prefix: "", picked: $picked, existing: alreadyIn)
                .navigationDestination(for: FolderRoute.self) {
                    VideoPickerLevel(prefix: $0.prefix, picked: $picked, existing: alreadyIn)
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Add \(picked.count)") {
                            let entries = library.allVideos.filter { picked.contains($0.id) }
                                .map { PlaylistEntry.video(bucket: $0.bucket, key: $0.key) }
                            store.add(store.newEntries(entries, for: playlistID), to: playlistID)
                            dismiss()
                        }
                        .bold()
                        .disabled(picked.isEmpty)
                    }
                }
        }
    }
}

private struct VideoPickerLevel: View {
    let prefix: String
    @Binding var picked: Set<String>
    let existing: Set<String>
    @Environment(LibraryStore.self) private var library
    @State private var query = ""

    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        let contents = library.contents(of: prefix)
        let videos = isSearching ? library.search(query, in: prefix) : SortOrder.nameAsc.apply(contents.videos)
        let pickable = videos.filter { !existing.contains($0.id) }
        let allPicked = !pickable.isEmpty && pickable.allSatisfy { picked.contains($0.id) }
        List {
            if !isSearching && !contents.subfolders.isEmpty {
                Section("Folders") {
                    ForEach(contents.subfolders) { f in
                        NavigationLink(value: FolderRoute(prefix: f.prefix)) {
                            HStack {
                                Image(systemName: "folder.fill").foregroundStyle(.yellow)
                                Text(f.name).lineLimit(1)
                                Spacer()
                                let n = library.videos(under: f.prefix, recursive: true).filter { picked.contains($0.id) }.count
                                if n > 0 { Text("\(n) picked").font(.caption).foregroundStyle(.red) }
                                Text("\(f.videoCount)").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            if !videos.isEmpty {
                Section {
                    ForEach(videos) { row($0) }
                } header: {
                    HStack {
                        Text(isSearching ? "\(videos.count) results" : "Videos in this folder")
                        Spacer()
                        if !pickable.isEmpty {
                            Button(allPicked ? "Deselect all" : "Select all") {
                                let ids = Set(pickable.map(\.id))
                                picked = allPicked ? picked.subtracting(ids) : picked.union(ids)
                            }
                            .font(.caption.weight(.semibold))
                            .textCase(nil)
                        }
                    }
                }
            } else if isSearching || contents.subfolders.isEmpty {
                ContentUnavailableView(isSearching ? "No matches" : "No videos here", systemImage: "film.stack")
            }
        }
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search this folder")
        .navigationTitle(prefix.isEmpty ? library.activeBucket : String(prefix.dropLast().split(separator: "/").last ?? ""))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func row(_ v: VideoItem) -> some View {
        let added = existing.contains(v.id)
        let on = added || picked.contains(v.id)
        return Button {
            if picked.contains(v.id) { picked.remove(v.id) } else { picked.insert(v.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(added ? Color.secondary : (on ? Color.red : Color.secondary))
                ThumbnailView(item: v, showsBadges: false).frame(width: 80).clipShape(RoundedRectangle(cornerRadius: 6))
                VStack(alignment: .leading, spacing: 2) {
                    Text(v.title).font(.subheadline).lineLimit(2).foregroundStyle(Color.primary)
                    Text(added ? "Already in playlist" : (isSearching ? v.folderDisplay : Format.bytes(v.size)))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(added)
    }
}
