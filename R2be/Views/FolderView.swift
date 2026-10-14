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
    @AppStorage("flattenFolders") private var flatten = false

    @State private var query = ""
    @State private var scope: SearchScope = .everywhere
    @State private var selection: Set<String>? = nil
    @State private var pendingAdd: PendingPlaylistAdd?
    @State private var randomSeed = 0

    private var layout: GalleryLayout { GalleryLayout(rawValue: layoutRaw) ?? .grid }
    private var sort: SortOrder { SortOrder(rawValue: sortRaw) ?? .nameAsc }
    private var isRoot: Bool { prefix == library.rootPrefix }
    private var title: String {
        isRoot ? library.activeBucket : String(prefix.dropLast().split(separator: "/").last ?? "")
    }
    private var isSearching: Bool { !query.trimmingCharacters(in: .whitespaces).isEmpty }

    private var contents: FolderContents { library.contents(of: prefix) }
    private var visibleVideos: [VideoItem] {
        let base = isSearching ? library.search(query, in: scope == .folder ? prefix : "")
            : flatten ? allVideosHere : contents.videos
        guard sort == .random else { return sort.apply(base) }
        // Stable "random" order: only changes when you tap Reshuffle, not on every redraw.
        let seed = randomSeed
        func rank(_ v: VideoItem) -> Int { var h = Hasher(); h.combine(seed); h.combine(v.id); return h.finalize() }
        return base.sorted { rank($0) < rank($1) }
    }
    private var allVideosHere: [VideoItem] { library.videos(under: prefix, recursive: true) }

    var body: some View {
        let videos = visibleVideos
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if library.isIndexing && library.allVideos.isEmpty {
                    indexingBanner
                } else if let err = library.lastError, library.allVideos.isEmpty {
                    errorBanner(err)
                }

                if !isSearching { header }

                if isSearching {
                    Text("\(videos.count) result\(videos.count == 1 ? "" : "s")")
                        .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 16)
                }

                VideoGallery(
                    folders: isSearching || flatten || !showFolders ? [] : contents.subfolders,
                    videos: videos,
                    layout: layout,
                    showFolderPath: isSearching,
                    selection: selectionBinding,
                    onPlay: play,
                    onAddToPlaylist: { pendingAdd = PendingPlaylistAdd(entries: $0) })

                if !isSearching && contents.subfolders.isEmpty && contents.videos.isEmpty && !library.isIndexing {
                    ContentUnavailableView("No videos here", systemImage: "film.stack",
                                           description: Text("Supported: MP4, MOV, M4V, 3GP, MP3, M4A, FLAC, WAV."))
                        .padding(.top, 40)
                }
            }
            .padding(.bottom, 24)
        }
        .scrollDismissesKeyboard(.immediately)   // hide the keyboard on scroll; the search and results stay
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(isRoot ? .large : .inline)
        // .always pins the search field in the navigation bar so it stays put while scrolling.
        .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search file names")
        .searchScopes($scope) {
            if !isRoot { Text("This folder").tag(SearchScope.folder) }
            Text("Everywhere").tag(SearchScope.everywhere)
        }
        .onAppear { if !isRoot { scope = .folder } }
        .refreshable { await library.refreshAndWait() }
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { if selection != nil { selectionBar(visible: videos) } }
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
                        player.play(allVideosHere, shuffle: false, title: title)
                    }
                    PillButton(title: "Shuffle", systemImage: "shuffle") {
                        player.shufflePlay(allVideosHere, title: title)
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
            Text("Scanning bucket… \(library.indexProgress.formatted()) files · \(library.indexMatches.formatted()) media").font(.footnote)
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
                Toggle("Flatten folders", isOn: $flatten)
                Toggle("Show folders", isOn: $showFolders).disabled(flatten)
                if !isRoot {
                    Divider()
                    Button("Add all videos here to playlist…", systemImage: "text.badge.plus") {
                        pendingAdd = PendingPlaylistAdd(entries: allVideosHere.map { .video(bucket: $0.bucket, key: $0.key) })
                    }
                    RecentPlaylistButton(entries: allVideosHere.map { .video(bucket: $0.bucket, key: $0.key) })
                }
            } label: {
                Image(systemName: layout.symbol)
            }
        }
        // Bulk add: always visible, including while searching.
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                selection = selection == nil ? [] : nil
            } label: {
                if selection == nil {
                    Image(systemName: "checklist")
                } else {
                    Text("Done").bold()
                }
            }
            .accessibilityLabel(selection == nil ? "Select videos" : "Done selecting")
        }
        if isRoot && library.isIndexing && !library.allVideos.isEmpty {
            ToolbarItem(placement: .topBarLeading) { ProgressView() }
        }
    }

    private var selectionBinding: Binding<Set<String>>? {
        guard selection != nil else { return nil }
        return Binding(get: { selection ?? [] }, set: { selection = $0 })
    }

    /// Picks survive changing the search text, so you can select across several searches.
    private var selectedVideos: [VideoItem] {
        guard let selection, !selection.isEmpty else { return [] }
        return library.allVideos.filter { selection.contains($0.id) }
    }

    private func selectionBar(visible: [VideoItem]) -> some View {
        let picked = selectedVideos
        let allVisibleSelected = !visible.isEmpty && visible.allSatisfy { selection?.contains($0.id) ?? false }
        return HStack(spacing: 10) {
            Button(allVisibleSelected ? "None" : "All") {
                let ids = Set(visible.map(\.id))
                selection = allVisibleSelected ? (selection ?? []).subtracting(ids) : (selection ?? []).union(ids)
            }
            .frame(width: 50)
            PillButton(title: "Add \(picked.count) to Playlist", systemImage: "text.badge.plus", prominent: true) {
                pendingAdd = PendingPlaylistAdd(entries: picked.map { .video(bucket: $0.bucket, key: $0.key) })
                selection = nil
            }
            .disabled(picked.isEmpty)
            iconButton("arrow.down.circle", "Download selected", disabled: picked.isEmpty) {
                library.download(picked)
                selection = nil
            }
            iconButton("play.fill", "Play selected", disabled: picked.isEmpty) {
                player.play(picked, title: "Selection")
                selection = nil
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func iconButton(_ symbol: String, _ label: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(Color(white: 0.18), in: Circle())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    private func play(_ item: VideoItem) {
        player.play(visibleVideos, startAt: item, shuffle: false, title: isSearching ? "Search: \(query)" : title)
    }
}
