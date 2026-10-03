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

    var body: some View {
        switch layout {
        case .list:
            HStack(spacing: 12) {
                Image(systemName: "folder.fill").font(.title2).foregroundStyle(.yellow)
                    .frame(width: 128, height: 40)
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
                        if let cover = folder.cover { ThumbnailView(item: cover, showsBadges: false) }
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

    var body: some View {
        Button { onPlay() } label: { Label("Play", systemImage: "play.fill") }
        Button { player.playNext(item) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
        Button { player.addToQueue([item]) } label: { Label("Add to Queue", systemImage: "text.badge.plus") }
        Button { onAddToPlaylist([.video(bucket: item.bucket, key: item.key)]) } label: {
            Label("Add to Playlist…", systemImage: "music.note.list")
        }
        Divider()
        Button { UIPasteboard.general.string = item.fileName } label: { Label("Copy File Name", systemImage: "doc.on.doc") }
        if let url = library.shareURL(for: item) {
            ShareLink(item: url) { Label("Share 24h Link", systemImage: "square.and.arrow.up") }
        }
    }
}

struct FolderMenu: View {
    let folder: FolderInfo
    let onAddToPlaylist: ([PlaylistEntry]) -> Void
    @Environment(PlayerController.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Button {
            player.play(library.videos(under: folder.prefix, recursive: true), title: folder.name)
        } label: { Label("Play All", systemImage: "play.fill") }
        Button {
            player.shufflePlay(library.videos(under: folder.prefix, recursive: true), title: folder.name)
        } label: { Label("Shuffle", systemImage: "shuffle") }
        Divider()
        Button {
            onAddToPlaylist([.folder(bucket: library.activeBucket, prefix: folder.prefix, recursive: true)])
        } label: { Label("Add Folder + Subfolders to Playlist…", systemImage: "folder.badge.plus") }
        Button {
            onAddToPlaylist([.folder(bucket: library.activeBucket, prefix: folder.prefix, recursive: false)])
        } label: { Label("Add This Folder Only to Playlist…", systemImage: "folder") }
    }
}

// MARK: - Add to playlist

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
                    Section("Add to existing") {
                        ForEach(store.playlists) { p in
                            Button {
                                store.add(pending.entries, to: p.id)
                                dismiss()
                            } label: {
                                HStack {
                                    Image(systemName: "music.note.list").foregroundStyle(.red)
                                    Text(p.name).foregroundStyle(.primary)
                                    Spacer()
                                    Text("\(p.entries.count) items").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add \(summary)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
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
}

struct VideoSurface: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.backgroundColor = .black
        v.playerLayer.player = player
        v.playerLayer.videoGravity = gravity
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

/// Big translucent "« 30" / "30 »" bubble shown on double-tap, YouTube-style.
struct SeekFlash: View {
    let forward: Bool
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: forward ? "goforward.30" : "gobackward.30").font(.system(size: 34, weight: .semibold))
            Text(forward ? "+30s" : "−30s").font(.caption.weight(.bold))
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
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(prominent ? Color.white : Color(white: 0.18), in: Capsule())
                .foregroundStyle(prominent ? Color.black : Color.white)
        }
        .buttonStyle(.plain)
    }
}
