import SwiftUI

enum FeedSource: Hashable {
    case all, recent
    case folder(String)
    case playlist(UUID)
}

/// Vertical, full-height, swipe-to-next video feed (Shorts/Reels style) over any folder or playlist.
/// It drives the shared PlayerController with isFeedQueue set, so the mini player and full
/// player stay in sync if you leave the tab or expand a video.
struct FeedView: View {
    let isActiveTab: Bool

    @Environment(LibraryStore.self) private var library
    @Environment(PlaylistStore.self) private var playlists
    @Environment(PlayerController.self) private var player

    @State private var source: FeedSource = .all
    @State private var items: [VideoItem] = []
    @State private var activeID: String?
    @State private var pendingAdd: PendingPlaylistAdd?

    private var isFeedLive: Bool { player.isFeedQueue }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black
            if items.isEmpty {
                ContentUnavailableView(library.isIndexing ? "Indexing…" : "Nothing to show",
                                       systemImage: "rectangle.stack.badge.play",
                                       description: Text("Pick a source from the menu above."))
            } else {
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            FeedPage(item: item,
                                     isLive: isFeedLive && player.current == item,
                                     start: { start(at: item) },
                                     save: { pendingAdd = PendingPlaylistAdd(entries: [.video(bucket: item.bucket, key: item.key)]) })
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(item.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .scrollPosition(id: $activeID)
                .scrollIndicators(.hidden)
            }
            topBar
        }
        .toolbarBackground(.black, for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
        .sheet(item: $pendingAdd) { AddToPlaylistSheet(pending: $0) }
        .onAppear { if items.isEmpty { rebuild(autostart: false) } }
        .onChange(of: library.allVideos.count) { _, _ in if items.isEmpty { rebuild(autostart: false) } }
        .onChange(of: isActiveTab) { _, active in
            if active {
                if isFeedLive { player.resume() }
                else if !player.isPlaying, let first = currentItem ?? items.first { start(at: first) }
            } else if isFeedLive {
                player.pause()
            }
        }
        .onChange(of: activeID) { _, id in
            guard isActiveTab, let id, let item = items.first(where: { $0.id == id }) else { return }
            if isFeedLive { if player.current != item { player.jump(to: item) } }
            else { start(at: item) }
        }
        .onChange(of: player.current) { _, cur in
            // Autoplay-next (or Next pressed in the full player) scrolls the feed along.
            guard isFeedLive, let cur, cur.id != activeID, items.contains(cur) else { return }
            withAnimation(.easeInOut(duration: 0.35)) { activeID = cur.id }
        }
    }

    private var currentItem: VideoItem? { activeID.flatMap { id in items.first { $0.id == id } } }

    private var sourceName: String {
        switch source {
        case .all: return "All videos"
        case .recent: return "Recently added"
        case .folder(let p): return String(p.dropLast().split(separator: "/").last ?? "Folder")
        case .playlist(let id): return playlists.playlist(id)?.name ?? "Playlist"
        }
    }

    private var topBar: some View {
        HStack {
            Menu {
                Picker("Source", selection: Binding(get: { source }, set: { source = $0; rebuild(autostart: isActiveTab) })) {
                    Label("All videos", systemImage: "square.stack").tag(FeedSource.all)
                    Label("Recently added", systemImage: "clock").tag(FeedSource.recent)
                }
                if !playlists.playlists.isEmpty {
                    Section("Playlists") {
                        ForEach(playlists.playlists) { p in
                            Button(p.name) { source = .playlist(p.id); rebuild(autostart: isActiveTab) }
                        }
                    }
                }
                let folders = library.contents(of: library.rootPrefix).subfolders
                if !folders.isEmpty {
                    Section("Folders") {
                        ForEach(folders) { f in
                            Button(f.name) { source = .folder(f.prefix); rebuild(autostart: isActiveTab) }
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(sourceName).font(.headline)
                    Image(systemName: "chevron.down").font(.caption.weight(.bold))
                }
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(.black.opacity(0.4), in: Capsule())
            }
            Spacer()
            Button {
                rebuild(autostart: isActiveTab)
            } label: {
                Image(systemName: "shuffle").font(.headline)
                    .padding(9).background(.black.opacity(0.4), in: Circle())
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.top, 6)
    }

    private func rebuild(autostart: Bool) {
        var list: [VideoItem]
        switch source {
        case .all: list = library.allVideos
        case .recent:
            list = Array(library.allVideos.sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }.prefix(300))
        case .folder(let p): list = library.videos(under: p, recursive: true)
        case .playlist(let id): list = playlists.playlist(id).map(library.resolve) ?? []
        }
        if source != .recent { list.shuffle() }
        items = Array(list.prefix(2000))
        // Start the new queue before moving the scroll position so onChange(activeID) sees it as current.
        if autostart, let first = items.first { start(at: first) }
        activeID = items.first?.id
    }

    private func start(at item: VideoItem) {
        player.play(items, startAt: item, title: sourceName, isFeed: true, present: false, keepGivenOrder: true)
    }
}

private struct FeedPage: View {
    let item: VideoItem
    let isLive: Bool
    let start: () -> Void
    let save: () -> Void

    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @AppStorage("feedFill") private var fill = false
    @AppStorage("disableShare") private var disableShare = true
    @State private var flash: Bool?
    @State private var flashTask: Task<Void, Never>?
    @State private var scrubFraction: Double?     // 0...1 while the progress bar is being dragged

    var body: some View {
        ZStack {
            Color.black
            if isLive {
                VideoSurface(player: player.player, gravity: fill ? .resizeAspectFill : .resizeAspect, pip: player.pip)
            } else {
                ThumbnailView(item: item, showsBadges: false)
            }

            HStack(spacing: 0) { tapZone(false); tapZone(true) }

            if !isLive || !player.isPlaying {
                Image(systemName: "play.fill").font(.system(size: 54)).foregroundStyle(.white.opacity(0.85))
                    .shadow(radius: 8).allowsHitTesting(false)
            } else if player.isBuffering {
                ProgressView().controlSize(.large).tint(.white).allowsHitTesting(false)
            }

            if let flash {
                HStack {
                    if flash { Spacer() }
                    SeekFlash(forward: flash).padding(.horizontal, 30)
                    if !flash { Spacer() }
                }
                .allowsHitTesting(false)
            }

            VStack {
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Label(item.folderDisplay, systemImage: "folder.fill")
                            .font(.caption.weight(.semibold)).lineLimit(1)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.15), in: Capsule())
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(3)
                        if isLive {
                            Text("\(Format.duration(player.currentTime)) / \(Format.duration(player.duration))")
                                .font(.caption.monospacedDigit()).foregroundStyle(.white.opacity(0.75))
                        }
                    }
                    .shadow(radius: 4)
                    Spacer(minLength: 16)
                    actionRail
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)

                progress
            }
            .foregroundStyle(.white)
        }
        .clipped()
        .pinchToFill($fill)
    }

    private var actionRail: some View {
        VStack(spacing: 20) {
            railButton(player.skipSymbol(forward: false), player.skipLabel(forward: false)) { if isLive { player.skipBackward() } }
            railButton(player.skipSymbol(forward: true), player.skipLabel(forward: true)) { if isLive { player.skipForward() } }
            railButton("text.badge.plus", "Save", action: save)
            if !disableShare, let url = library.shareURL(for: item) {
                ShareLink(item: url) { railLabel("arrowshape.turn.up.right.fill", "Share") }
            }
            railButton("arrow.up.left.and.arrow.down.right", "Expand") {
                if !isLive { start() }
                player.startFullscreen = true
                player.isPresented = true
            }
        }
    }

    private func railButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { railLabel(symbol, label) }
    }

    private func railLabel(_ symbol: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 24, weight: .semibold))
            Text(label).font(.caption2.weight(.semibold))
        }
        .shadow(radius: 4)
        .foregroundStyle(.white)
    }

    /// Scrubbable progress bar: drag (or tap) anywhere along it. The touch area is much taller
    /// than the thin bar, and the drag takes priority over the Feed's vertical paging.
    @ViewBuilder private var progress: some View {
        Scrubber(fraction: $scrubFraction, enabled: isLive)
        .frame(height: 30)
        .overlay(alignment: .top) {
            if let f = scrubFraction {
                Text("\(Format.duration(f * player.duration)) / \(Format.duration(player.duration))")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.black.opacity(0.7), in: Capsule())
                    .offset(y: -36)
                    .allowsHitTesting(false)
            }
        }
    }

    private func tapZone(_ forward: Bool) -> some View {
        Color.clear.contentShape(Rectangle())
            .onTapGesture(count: 2) {
                guard isLive else { return }
                forward ? player.skipForward() : player.skipBackward()
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation(.spring(duration: 0.25)) { flash = forward }
                flashTask?.cancel()
                flashTask = Task {
                    try? await Task.sleep(for: .milliseconds(650))
                    if !Task.isCancelled { withAnimation { flash = nil } }
                }
            }
            .onTapGesture { isLive ? player.togglePlay() : start() }
    }
}
