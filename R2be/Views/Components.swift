import AVKit
import SwiftUI

// MARK: - Thumbnail

struct ThumbnailView: View {
    let item: VideoItem
    var showsBadges = true
    @Environment(LibraryStore.self) private var library
    @AppStorage("thumbnailsEnabled") private var thumbnailsEnabled = true
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.16), Color(white: 0.09)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
                    .transition(.opacity)
            } else {
                Image(systemName: "film").font(.title2).foregroundStyle(.white.opacity(0.25))
            }
        }
        .aspectRatio(16 / 9, contentMode: .fit)
        .clipped()
        .overlay(alignment: .bottomTrailing) {
            if showsBadges, let d = ResumeStore.duration(for: item.id) {
                Text(Format.duration(d))
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 4))
                    .padding(5)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showsBadges { DownloadBadge(item: item).padding(5) }
        }
        .overlay(alignment: .bottom) {
            if showsBadges, let p = ResumeStore.progress(for: item.id) {
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Rectangle().fill(.white.opacity(0.3))
                        Rectangle().fill(.red).frame(width: g.size.width * p)
                    }
                }
                .frame(height: 3)
            }
        }
        .task(id: item.id) {
            if image == nil { image = ThumbnailService.shared.cached(item) }
            guard image == nil, thumbnailsEnabled else { return }
            let img = await ThumbnailService.shared.thumbnail(
                for: item, videoURL: library.streamURL(for: item), sidecarURL: library.sidecarThumbnailURL(for: item))
            withAnimation(.easeOut(duration: 0.2)) { image = img }
        }
    }
}

/// Small corner badge: a ring while downloading, a filled arrow once saved for offline.
struct DownloadBadge: View {
    let item: VideoItem
    private var store: DownloadStore { .shared }

    var body: some View {
        if store.isDownloaded(item) {
            Image(systemName: "arrow.down.circle.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.white, Color.black.opacity(0.6))
        } else if let p = store.progress[item.id] {
            Circle().trim(from: 0, to: max(p, 0.03))
                .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: 14, height: 14)
                .padding(2)
                .background(.black.opacity(0.6), in: Circle())
        }
    }
}

// MARK: - Gallery

/// Renders a mixed list of folders and videos in any of the four layouts.
struct VideoGallery: View {
    var folders: [FolderInfo] = []
    let videos: [VideoItem]
    let layout: GalleryLayout
    var showFolderPath = false
    var selection: Binding<Set<String>>? = nil
    let onPlay: (VideoItem) -> Void
    var onAddToPlaylist: ([PlaylistEntry]) -> Void = { _ in }

    private var columns: [GridItem] {
        let n: Int
        switch layout {
        case .list, .cards: n = 1
        case .grid: n = 2
        case .compactGrid: n = 3
        }
        return Array(repeating: GridItem(.flexible(), spacing: layout == .compactGrid ? 4 : 12, alignment: .top), count: n)
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: layout == .list ? 0 : (layout == .compactGrid ? 4 : 16)) {
            ForEach(folders) { f in
                NavigationLink(value: FolderRoute(prefix: f.prefix)) {
                    FolderCell(folder: f, layout: layout)
                }
                .buttonStyle(.plain)
                .contextMenu { FolderMenu(folder: f, onAddToPlaylist: onAddToPlaylist) }
            }
            ForEach(videos) { v in
                let selected = selection?.wrappedValue.contains(v.id) ?? false
                Button {
                    if let selection {
                        if selected { selection.wrappedValue.remove(v.id) } else { selection.wrappedValue.insert(v.id) }
                    } else {
                        onPlay(v)
                    }
                } label: {
                    VideoCell(item: v, layout: layout, showFolderPath: showFolderPath)
                        .overlay(alignment: .topLeading) {
                            if selection != nil {
                                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                                    .font(.title3).symbolRenderingMode(.palette)
                                    .foregroundStyle(Color.white, selected ? Color.red : Color.black.opacity(0.4))
                                    .padding(6)
                            }
                        }
                }
                .buttonStyle(.plain)
                .contextMenu { VideoMenu(item: v, onPlay: { onPlay(v) }, onAddToPlaylist: onAddToPlaylist) }
            }
        }
        .padding(.horizontal, layout == .compactGrid ? 4 : (layout == .list ? 0 : 12))
    }
}

struct FolderRoute: Hashable { let prefix: String }

struct VideoCell: View {
    let item: VideoItem
    let layout: GalleryLayout
    var showFolderPath = false

    private var meta: String {
        var parts: [String] = []
        if showFolderPath { parts.append(item.folderDisplay) }
        parts.append(Format.bytes(item.size))
        if let d = item.lastModified { parts.append(Format.relative(d)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        switch layout {
        case .list:
            HStack(spacing: 12) {
                ThumbnailView(item: item).frame(width: 128).clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.title).font(.subheadline.weight(.medium)).lineLimit(2)
                    Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .contentShape(Rectangle())
        case .compactGrid:
            VStack(alignment: .leading, spacing: 3) {
                ThumbnailView(item: item).clipShape(RoundedRectangle(cornerRadius: 6))
                Text(item.title).font(.caption2).lineLimit(1).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        case .grid:
            VStack(alignment: .leading, spacing: 6) {
                ThumbnailView(item: item).clipShape(RoundedRectangle(cornerRadius: 10))
                Text(item.title).font(.footnote.weight(.medium)).lineLimit(2)
                Text(meta).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        case .cards:
            VStack(alignment: .leading, spacing: 8) {
                ThumbnailView(item: item).clipShape(RoundedRectangle(cornerRadius: 14))
                HStack(alignment: .top, spacing: 10) {
                    Circle().fill(Color(white: 0.2)).frame(width: 34, height: 34)
                        .overlay(Image(systemName: "folder.fill").font(.caption).foregroundStyle(.secondary))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                        Text([item.folderDisplay, Format.bytes(item.size), Format.relative(item.lastModified)]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
    }
}

struct FolderCell: View {
    let folder: FolderInfo
    let layout: GalleryLayout
    @Environment(LibraryStore.self) private var library
    @Environment(FolderCoverStore.self) private var covers

    private var customCover: UIImage? { covers.image(bucket: library.activeBucket, prefix: folder.prefix) }

    /// A picked photo, cropped to the 16:9 tile.
    private func coverImage(_ img: UIImage) -> some View {
        Color.clear
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay(Image(uiImage: img).resizable().scaledToFill())
            .clipped()
    }

    var body: some View {
        switch layout {
        case .list:
            HStack(spacing: 12) {
                Group {
                    if let img = customCover {
                        coverImage(img).frame(width: 128).clipShape(RoundedRectangle(cornerRadius: 8))
                    } else {
                        Image(systemName: "folder.fill").font(.title2).foregroundStyle(.yellow)
                            .frame(width: 128, height: 40)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(.subheadline.weight(.medium)).lineLimit(1)
                    Text("\(folder.videoCount) videos").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        default:
            VStack(alignment: .leading, spacing: layout == .compactGrid ? 3 : 6) {
                ZStack {
                    // Stacked-cards look so folders read differently from videos at a glance.
                    RoundedRectangle(cornerRadius: 8).fill(Color(white: 0.22)).padding(.horizontal, 10).offset(y: -6)
                    Group {
                        if let img = customCover { coverImage(img) }
                        else if let cover = folder.cover { ThumbnailView(item: cover, showsBadges: false) }
                        else { Color(white: 0.15).aspectRatio(16 / 9, contentMode: .fit) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: layout == .cards ? 14 : 8))
                    .overlay(alignment: .bottomTrailing) {
                        Label("\(folder.videoCount)", systemImage: "play.rectangle.on.rectangle.fill")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(.black.opacity(0.75), in: Capsule())
                            .padding(5)
                    }
                }
                .padding(.top, 6)
                Label(folder.name, systemImage: "folder.fill")
                    .font(layout == .compactGrid ? .caption2 : .footnote.weight(.medium))
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - Context menus

struct VideoMenu: View {
    let item: VideoItem
    let onPlay: () -> Void
    let onAddToPlaylist: ([PlaylistEntry]) -> Void
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @AppStorage("disableShare") private var disableShare = true

    var body: some View {
        Button { onPlay() } label: { Label("Play", systemImage: "play.fill") }
        Button { player.playNext(item) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue([item]) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
        Button { onAddToPlaylist([.video(bucket: item.bucket, key: item.key)]) } label: {
            Label("Add to Playlist…", systemImage: "music.note.list")
        }
        RecentPlaylistButton(entries: [.video(bucket: item.bucket, key: item.key)])
        DownloadMenuItems(items: [item])
        Divider()
        Button { UIPasteboard.general.string = item.fileName } label: { Label("Copy File Name", systemImage: "doc.on.doc") }
        if !disableShare, let url = library.shareURL(for: item) {
            ShareLink(item: url) { Label("Share 24h Link", systemImage: "square.and.arrow.up") }
        }
    }
}

struct FolderMenu: View {
    let folder: FolderInfo
    let onAddToPlaylist: ([PlaylistEntry]) -> Void
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(FolderCoverStore.self) private var covers

    var body: some View {
        let videos = library.videos(under: folder.prefix, recursive: true)
        let entries = videos.map { PlaylistEntry.video(bucket: $0.bucket, key: $0.key) }
        Button {
            player.play(videos, title: folder.name)
        } label: { Label("Play All", systemImage: "play.fill") }
        Button {
            player.shufflePlay(videos, title: folder.name)
        } label: { Label("Shuffle", systemImage: "shuffle") }
        Divider()
        Button {
            onAddToPlaylist(entries)
        } label: { Label("Add All \(folder.videoCount) Videos to Playlist…", systemImage: "text.badge.plus") }
        RecentPlaylistButton(entries: entries)
        DownloadMenuItems(items: videos)
        Divider()
        Button {
            covers.requestPicker(bucket: library.activeBucket, prefix: folder.prefix)
        } label: { Label("Set Cover Image…", systemImage: "photo") }
        if covers.hasCover(bucket: library.activeBucket, prefix: folder.prefix) {
            Button(role: .destructive) {
                covers.removeCover(bucket: library.activeBucket, prefix: folder.prefix)
            } label: { Label("Remove Cover Image", systemImage: "trash") }
        }
    }
}

// MARK: - Add to playlist

/// Menu item shown right under "Add to Playlist…": one tap adds to the playlist used last.
struct RecentPlaylistButton: View {
    let entries: [PlaylistEntry]
    @Environment(PlaylistStore.self) private var store

    var body: some View {
        if let p = store.recentPlaylist {
            let fresh = store.newEntries(entries, for: p.id)
            Button {
                store.add(fresh, to: p.id)
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } label: {
                Label(fresh.isEmpty ? "Already in \(p.name)" : "Add to \(p.name)",
                      systemImage: store.isFavorites(p.id) ? "heart" : "music.note")
            }
            .disabled(fresh.isEmpty)
        }
    }
}

struct PendingPlaylistAdd: Identifiable {
    let id = UUID()
    let entries: [PlaylistEntry]
}

struct AddToPlaylistSheet: View {
    let pending: PendingPlaylistAdd
    @Environment(PlaylistStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""

    private var summary: String {
        let folders = pending.entries.filter { if case .folder = $0 { return true } else { return false } }.count
        let videos = pending.entries.count - folders
        return [videos > 0 ? "\(videos) video\(videos == 1 ? "" : "s")" : nil,
                folders > 0 ? "\(folders) folder\(folders == 1 ? "" : "s")" : nil]
            .compactMap { $0 }.joined(separator: " + ")
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("New playlist name", text: $newName)
                            .submitLabel(.done)
                            .onSubmit(createNew)
                        Button("Create", action: createNew).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                } footer: {
                    Text("Playlists live in the app only. Nothing in your bucket is moved or changed.")
                }
                if !store.playlists.isEmpty {
                    Section {
                        ForEach(store.playlists) { p in
                            let fresh = store.newEntries(pending.entries, for: p.id)
                            Button {
                                store.add(fresh, to: p.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: store.isFavorites(p.id) ? "heart.fill" : "music.note.list").foregroundStyle(.red)
                                    Text(p.name).foregroundStyle(fresh.isEmpty ? Color.secondary : Color.primary)
                                    Spacer()
                                    Text(addLabel(fresh: fresh.count, total: pending.entries.count))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .disabled(fresh.isEmpty)
                        }
                    } header: {
                        Text("Add to existing")
                    } footer: {
                        Text("Videos already in a playlist are skipped, so nothing is added twice.")
                    }
                }
            }
            .navigationTitle("Add \(summary)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }

    private func addLabel(fresh: Int, total: Int) -> String {
        if fresh == 0 { return total == 1 ? "Already added" : "All already added" }
        if fresh == total { return "+\(fresh)" }
        return "+\(fresh) new · \(total - fresh) already added"
    }

    private func createNew() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.create(name: name, entries: pending.entries)
        dismiss()
    }
}

// MARK: - Video surface

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    /// When set, this surface offers itself as the Picture in Picture source while it's on screen.
    weak var pip: PiPManager?

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard let pip else { return }
        if window != nil { pip.register(playerLayer) } else { pip.unregister(playerLayer) }
    }
}

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect
    var pip: PiPManager? = nil

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
        v.pip = pip
        return v
    }

    func updateUIView(_ v: PlayerLayerView, context: Context) {
        if v.playerLayer.player !== player { v.playerLayer.player = player }
        if v.playerLayer.videoGravity != gravity {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.25)
            v.playerLayer.videoGravity = gravity
            CATransaction.commit()
        }
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemRed
        v.prioritizesVideoDevices = true
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

extension View {
    /// Spread two fingers on a video to fill the screen (cropping the edges); pinch to fit the whole frame again.
    func pinchToFill(_ fill: Binding<Bool>) -> some View {
        simultaneousGesture(
            MagnifyGesture().onEnded { v in
                let wantFill = v.magnification > 1.1 ? true : v.magnification < 0.9 ? false : fill.wrappedValue
                guard wantFill != fill.wrappedValue else { return }
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                withAnimation { fill.wrappedValue = wantFill }
            })
    }
}

/// Progress bar you drag or tap anywhere along to seek; its whole frame is the touch area, so make
/// the frame as tall as the strip that should scrub. Built from SwiftUI views rather than Slider so
/// its drag wins over the swipe-to-change-video gestures on the video behind it.
struct Scrubber: View {
    /// 0...1 while dragging, nil otherwise; read it to show the time under the finger.
    @Binding var fraction: Double?
    var enabled = true
    var onEnd: () -> Void = {}
    @Environment(PlayerController.self) private var player

    var body: some View {
        let live = enabled && player.duration > 0
        let dragging = fraction != nil
        GeometryReader { g in
            let p = fraction ?? (live ? min(player.currentTime / player.duration, 1) : 0)
            let bar: CGFloat = dragging ? 6 : 3
            let knob: CGFloat = dragging ? 16 : 10
            ZStack(alignment: .bottomLeading) {
                Color.clear
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.25))
                    Capsule().fill(.red).frame(width: max(g.size.width * p, bar))
                    if live {
                        Circle().fill(.white)
                            .frame(width: knob, height: knob)
                            .offset(x: min(max(g.size.width * p - knob / 2, 0), g.size.width - knob))
                            .shadow(radius: 2)
                    }
                }
                .frame(height: bar)
                .padding(.bottom, 6)
                .animation(.easeOut(duration: 0.15), value: dragging)
            }
            .contentShape(Rectangle())
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        guard live else { return }
                        player.isScrubbing = true
                        fraction = Self.clamped(v.location.x / max(g.size.width, 1))
                    }
                    .onEnded { v in
                        guard live else { return }

                        // Seek before clearing, so the bar holds the drop point until playback lands there.
                        player.seek(to: Self.clamped(v.location.x / max(g.size.width, 1)) * player.duration)
                        player.isScrubbing = false
                        fraction = nil
                        onEnd()
                    })
        }
    }

    private static func clamped(_ x: Double) -> Double { min(max(x, 0), 1) }
}

/// Big translucent skip bubble shown on double-tap, YouTube-style.
struct SeekFlash: View {
    let forward: Bool
    @Environment(PlayerController.self) private var player
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: player.skipSymbol(forward: forward)).font(.system(size: 34, weight: .semibold))
            Text(player.skipLabel(forward: forward)).font(.caption.weight(.bold))
        }
        .foregroundStyle(.white)
        .padding(22)
        .background(.black.opacity(0.45), in: Circle())
        .transition(.scale.combined(with: .opacity))
    }
}

struct PillButton: View {
    let title: String
    let systemImage: String
    var prominent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(prominent ? Color.white : Color(white: 0.18), in: Capsule())
                .foregroundStyle(prominent ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}
