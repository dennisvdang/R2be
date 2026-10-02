import SwiftUI

enum SearchScope: Hashable { case folder, everywhere }

struct FolderView: View {
    let prefix: String

    @Environment(LibraryStore.self) private var library
    @Environment(PlayerController.self) private var player
    @Environment(PlaylistStore.self) private var playlists
    @AppStorage("galleryLayout") private var layoutRaw = GalleryLayout.grid.rawValue
    @AppStorage("sortOrder") private var sortRaw = SortOrder.nameAsc.rawValue
    @AppStorage("foldersFirst") private var showFolders = true

    @State private var query = ""
    @State private var scope: SearchScope = .everywhere
    @State private var selection: Set<String>? = nil
    @State private var pendingAdd: PendingPlaylistAdd?
    @State private var randomSeed = 0

    private var layout: GalleryLayout { GalleryLayout(rawValue: layoutRaw) ?? .grid }
    private var sort: SortOrder { SortOrder(rawValue: sortRaw) ?? .nameAsc }
    private var isRoot: Bool { prefix.isEmpty }
    private var title: String {
        isRoot ? library.activeBucket : String(prefix.dropLast().split(separator: "/").last ?? "")
    }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var contents: FolderContents { library.contents(of: prefix) }
    private var visibleVideos: [VideoItem] {
        let base = isSearching ? library.search(query, in: scope == .folder ? prefix : "") : contents.videos
        guard sort == .random else { return sort.apply(base) }
        // Stable "random" order: only changes when you tap Reshuffle, not on every redraw.
        let seed = randomSeed
        func rank(_ v: VideoItem) -> Int { var h = Hasher(); h.combine(seed); h.combine(v.id); return h.finalize() }
        return base.sorted { rank($0) < rank($1) }
    }
    private var allVideosHere: [VideoItem] { library.videos(under: prefix, recursive: true) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if library.isIndexing && library.allVideos.isEmpty {
                    indexingBanner
                } else if let err = library.lastError, library.allVideos.isEmpty {
                    errorBanner(err)
                }

                if !isSearching { header }

                if isSearching {
                    Text("\(visibleVideos.count) result\(visibleVideos.count == 1 ? "" : "s")")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                }

                VideoGallery(
                    folders: isSearching || !showFolders ? [] : contents.subfolders,
                    videos: visibleVideos,
                    layout: layout,
                    showFolderPath: isSearching,
                    selection: selectionBinding,
                    onPlay: play,
                    onAddToPlaylist: { pendingAdd = PendingPlaylistAdd(entries: $0) })

                if !isSearching && contents.subfolders.isEmpty && contents.videos.isEmpty && !library.isIndexing {
                    ContentUnavailableView("No videos here", systemImage: "film.stack",
                                           description: Text("Supported: MP4, MOV, M4V, HLS (.m3u8)."))
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 24)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: isRoot ? .always : .automatic),
                    prompt: "Search file names")
        .searchScopes($scope) {
            if !isRoot { Text("This folder").tag(SearchScope.folder) }
            Text("Everywhere").tag(SearchScope.everywhere)
        }
        .onAppear { if !isRoot { scope = .folder } }
        .refreshable { await library.refreshAndWait() }
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { if selection != nil { selectionBar } }
        .sheet(item: $pendingAdd) { AddToPlaylistSheet(pending: $0) }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            let total = allVideosHere.count
            if total > 0 {
                Text("\(total) video\(total == 1 ? "" : "s")" + (contents.subfolders.isEmpty ? "" : " · \(contents.subfolders.count) folders"))
                    .font(.footnote).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    PillButton(title: "Play all", systemImage: "play.fill", prominent: true) {
                        player.play(allVideosHere, shuffle: false, context: .folder(prefix), title: title)
                    }
                    PillButton(title: "Shuffle", systemImage: "shuffle") {
                        player.shufflePlay(allVideosHere, context: .folder(prefix), title: title)
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var indexingBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Scanning bucket… \(library.indexProgress.formatted()) files · \(library.indexMatches.formatted()) videos").font(.footnote)
        }
        .padding(.horizontal, 16)
    }

    private func errorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Couldn't load bucket", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(message).font(.footnote).foregroundStyle(.secondary)
            Button("Retry") { library.refresh() }
        }
        .padding(12)
        .background(Color(white: 0.12), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Picker("Layout", selection: $layoutRaw) {
                    ForEach(GalleryLayout.allCases) { Label($0.label, systemImage: $0.symbol).tag($0.rawValue) }
                }
                Picker("Sort", selection: $sortRaw) {
                    ForEach(SortOrder.allCases) { Text($0.label).tag($0.rawValue) }
                }
                if sort == .random { Button("Reshuffle order", systemImage: "dice") { randomSeed += 1 } }
                Toggle("Show folders", isOn: $showFolders)
                Divider()
                Button(selection == nil ? "Select videos" : "Done selecting",
                       systemImage: "checkmark.circle") {
                    selection = selection == nil ? [] : nil
                }
                if !isRoot {
                    Button("Add folder to playlist…", systemImage: "folder.badge.plus") {
                        pendingAdd = PendingPlaylistAdd(entries: [.folder(bucket: library.activeBucket, prefix: prefix, recursive: true)])
                    }
                }
            } label: {
                Image(systemName: layout.symbol)
            }
        }
        if isRoot && library.isIndexing && !library.allVideos.isEmpty {
            ToolbarItem(placement: .topBarLeading) { ProgressView() }
        }
    }

    private var selectionBinding: Binding<Set<String>>? {
        guard selection != nil else { return nil }
        return Binding(get: { selection ?? [] }, set: { selection = $0 })
    }

    private var selectedVideos: [VideoItem] {
        guard let selection else { return [] }
        return visibleVideos.filter { selection.contains($0.id) }
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Button(selectedVideos.count == visibleVideos.count ? "None" : "All") {
                selection = selectedVideos.count == visibleVideos.count ? [] : Set(visibleVideos.map(\.id))
            }
            .frame(width: 50)
            PillButton(title: "Play \(selectedVideos.count)", systemImage: "play.fill", prominent: true) {
                player.play(selectedVideos, context: .selection, title: "Selection")
                selection = nil
            }
            .disabled(selectedVideos.isEmpty)
            PillButton(title: "Playlist", systemImage: "text.badge.plus") {
                pendingAdd = PendingPlaylistAdd(entries: selectedVideos.map { .video(bucket: $0.bucket, key: $0.key) })
                selection = nil
            }
            .disabled(selectedVideos.isEmpty)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func play(_ item: VideoItem) {
        player.play(visibleVideos, startAt: item, context: isSearching ? .search : .folder(prefix),
                    title: isSearching ? "Search: \(query)" : title)
    }
}
