import Foundation
import Observation

struct FolderInfo: Identifiable, Hashable {
    var prefix: String          // "Shows/Season 1/"
    var name: String            // "Season 1"
    var videoCount: Int         // recursive
    var latest: Date?
    var cover: VideoItem?       // first video, used for the folder thumbnail
    var id: String { prefix }
}

struct FolderContents {
    var subfolders: [FolderInfo] = []
    var videos: [VideoItem] = []
}

/// Cached snapshot of one bucket. The whole key list is pulled once (1000 keys per request) and
/// every folder view, search and playlist expansion is computed locally from it — fast and cheap
/// on R2 Class A/B operations.
struct BucketIndex: Codable {
    var bucket: String
    var videos: [VideoItem]
    var imageKeys: Set<String>
    var builtAt: Date
}

@Observable
@MainActor
final class LibraryStore {
    private(set) var credentials: R2Credentials?
    private(set) var indexes: [String: BucketIndex] = [:]
    var isIndexing = false
    var indexProgress = 0       // keys scanned so far
    var indexMatches = 0        // playable (video/audio) keys found so far
    var lastError: String?

    @ObservationIgnored private var folderCache: [String: FolderContents] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var otherBucketIndexes: [String: BucketIndex] = [:]

    init() {
        credentials = KeychainStore.load()
        if let b = credentials?.bucket, !b.isEmpty { indexes[b] = Self.loadIndex(bucket: b) }
    }

    var isConfigured: Bool { credentials != nil && !(credentials?.bucket.isEmpty ?? true) }
    var client: R2Client? { credentials.map { R2Client(credentials: $0) } }
    var activeBucket: String { credentials?.bucket ?? "" }
    var activeIndex: BucketIndex? { indexes[activeBucket] }
    var allVideos: [VideoItem] { activeIndex?.videos ?? [] }

    // MARK: Credentials

    /// Pass `folders` to change which folders of `new.bucket` get indexed; nil keeps the current choice.
    func save(credentials new: R2Credentials, folders: [String]? = nil) {
        if let folders { Self.setIndexFolders(folders, for: new.bucket) }
        KeychainStore.save(new)
        credentials = new
        folderCache = [:]
        if indexes[new.bucket] == nil { indexes[new.bucket] = Self.loadIndex(bucket: new.bucket) }
        refresh()
    }

    func signOut() {
        KeychainStore.delete()
        credentials = nil
        indexes = [:]
        folderCache = [:]
    }

    // MARK: Indexing

    func refresh() {
        guard let client, isConfigured else { return }
        refreshTask?.cancel()
        let bucket = activeBucket
        let folders = Self.indexFolders(for: bucket)
        isIndexing = true
        indexProgress = 0
        indexMatches = 0
        lastError = nil
        refreshTask = Task {
            do {
                let objects = try await client.listAllObjects(bucket: bucket, prefixes: folders.isEmpty ? [""] : folders,
                                                          include: Self.isIndexable) { scanned, pageKept in
                    let videos = pageKept.filter { MediaTypes.playable.contains(($0.key as NSString).pathExtension.lowercased()) }.count
                    Task { @MainActor [weak self] in
                        self?.indexProgress = scanned
                        self?.indexMatches += videos
                    }
                }
                let index = Self.buildIndex(bucket: bucket, objects: objects)
                self.indexes[bucket] = index
                self.folderCache = [:]
                Self.saveIndex(index)
            } catch is CancellationError {
            } catch {
                self.lastError = error.localizedDescription
            }
            self.isIndexing = false
        }
    }

    func refreshAndWait() async {
        refresh()
        await refreshTask?.value
    }

    func refreshIfStale(maxAge: TimeInterval = 15 * 60) {
        guard isConfigured, !isIndexing else { return }
        if let built = activeIndex?.builtAt, Date().timeIntervalSince(built) < maxAge { return }
        refresh()
    }

    // MARK: Folders to index

    /// Folder prefixes (with trailing "/") chosen for a bucket. Empty means the whole bucket.
    nonisolated static func indexFolders(for bucket: String) -> [String] {
        UserDefaults.standard.stringArray(forKey: "indexFolders." + bucket) ?? []
    }

    /// Stores the choice, dropping any folder already covered by a selected parent.
    nonisolated static func setIndexFolders(_ folders: [String], for bucket: String) {
        let unique = Set(folders.map { $0.hasSuffix("/") ? $0 : $0 + "/" })
        let kept = unique.filter { f in !unique.contains { $0 != f && f.hasPrefix($0) } }.sorted()
        UserDefaults.standard.set(kept, forKey: "indexFolders." + bucket)
    }

    /// Videos, plus images that may be sidecar thumbnails. Everything else is dropped while listing.
    nonisolated static func isIndexable(_ o: R2Object) -> Bool {
        if o.key.hasSuffix("/") { return false }                       // folder placeholder objects
        if o.key.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { return false } // ._AppleDouble, .DS_Store, hidden dirs
        let ext = (o.key as NSString).pathExtension.lowercased()
        return MediaTypes.playable.contains(ext) || MediaTypes.images.contains(ext)
    }

    nonisolated static func buildIndex(bucket: String, objects: [R2Object]) -> BucketIndex {
        var videos: [VideoItem] = []
        var images = Set<String>()
        for o in objects where isIndexable(o) {
            let ext = (o.key as NSString).pathExtension.lowercased()
            if MediaTypes.playable.contains(ext) {
                videos.append(VideoItem(bucket: bucket, key: o.key, size: o.size, lastModified: o.lastModified, etag: o.etag))
            } else if MediaTypes.images.contains(ext) {
                images.insert(o.key)
            }
        }
        return BucketIndex(bucket: bucket, videos: videos, imageKeys: images, builtAt: Date())
    }

    // MARK: Browsing

    func contents(of prefix: String) -> FolderContents {
        if let cached = folderCache[prefix] { return cached }
        var direct: [VideoItem] = []
        var folders: [String: FolderInfo] = [:]
        for v in allVideos where v.key.hasPrefix(prefix) {
            let rest = v.key.dropFirst(prefix.count)
            if let slash = rest.firstIndex(of: "/") {
                let name = String(rest[..<slash])
                let sub = prefix + name + "/"
                var f = folders[sub] ?? FolderInfo(prefix: sub, name: name, videoCount: 0, latest: nil, cover: nil)
                f.videoCount += 1
                if (v.lastModified ?? .distantPast) > (f.latest ?? .distantPast) { f.latest = v.lastModified }
                if f.cover == nil || v.fileName.localizedStandardCompare(f.cover!.fileName) == .orderedAscending { f.cover = v }
                folders[sub] = f
            } else {
                direct.append(v)
            }
        }
        let result = FolderContents(
            subfolders: folders.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending },
            videos: direct)
        folderCache[prefix] = result
        return result
    }

    func videos(under prefix: String, recursive: Bool, bucket: String? = nil) -> [VideoItem] {
        let source = index(for: bucket ?? activeBucket)?.videos ?? []
        let filtered = source.filter { v in
            guard v.key.hasPrefix(prefix) else { return false }
            return recursive || !v.key.dropFirst(prefix.count).contains("/")
        }
        return filtered.sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
    }

    func search(_ query: String, in prefix: String = "") -> [VideoItem] {
        let tokens = SearchMatcher.tokens(query)
        guard !tokens.isEmpty else { return [] }
        return allVideos.filter { $0.key.hasPrefix(prefix) && SearchMatcher.matches($0, tokens: tokens) }
    }

    func video(bucket: String, key: String) -> VideoItem? {
        index(for: bucket)?.videos.first { $0.key == key }
    }

    /// Expands playlist entries into a de-duplicated, ordered list of videos that still exist.
    func resolve(_ playlist: Playlist) -> [VideoItem] {
        var seen = Set<String>()
        var out: [VideoItem] = []
        for entry in playlist.entries {
            let items: [VideoItem]
            switch entry {
            case .video(let b, let k): items = video(bucket: b, key: k).map { [$0] } ?? []
            case .folder(let b, let p, let r): items = videos(under: p, recursive: r, bucket: b)
            }
            for i in items where seen.insert(i.id).inserted { out.append(i) }
        }
        return out
    }

    private func index(for bucket: String) -> BucketIndex? {
        if let i = indexes[bucket] { return i }
        if let i = otherBucketIndexes[bucket] { return i }
        // Playlists may reference another bucket you indexed earlier; load its cached snapshot
        // without touching observed state (this can run during a view update).
        if let i = Self.loadIndex(bucket: bucket) { otherBucketIndexes[bucket] = i; return i }
        return nil
    }

    // MARK: URLs

    /// How long a stream link stays valid (Settings → Stream link lifetime, default 6 h).
    var streamLinkLifetime: TimeInterval {
        let hours = UserDefaults.standard.double(forKey: "presignHours")
        return (hours > 0 ? hours : 6) * 3600
    }

    /// A fresh signed link every call. Playlists store only bucket + key, never a link, so they
    /// can't go stale; the player asks for a new link each time it loads a video.
    func streamURL(for item: VideoItem) -> URL? {
        client?.presignedURL(bucket: item.bucket, key: item.key, expires: streamLinkLifetime)
    }

    /// Optional sidecar thumbnail: "clip.jpg" or "clip.mp4.jpg" next to "clip.mp4", or a
    /// "thumbs/" subfolder variant. If none exists, a frame is grabbed from the video.
    func sidecarThumbnailURL(for item: VideoItem) -> URL? {
        guard let images = index(for: item.bucket)?.imageKeys, !images.isEmpty else { return nil }
        let base: String = item.folder + item.title
        let thumbsBase: String = item.folder + "thumbs/" + item.title
        var candidates: [String] = []
        for ext in ["jpg", "jpeg", "png", "webp"] {
            candidates.append(base + "." + ext)
            candidates.append(item.key + "." + ext)
            candidates.append(thumbsBase + "." + ext)
        }
        guard let hit = candidates.first(where: images.contains) else { return nil }
        return client?.presignedURL(bucket: item.bucket, key: hit, expires: 24 * 3600)
    }

    // MARK: Persistence

    nonisolated private static func indexURL(bucket: String) -> URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let safe = bucket.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? bucket
        return dir.appendingPathComponent("index-\(safe).json")
    }

    nonisolated private static func loadIndex(bucket: String) -> BucketIndex? {
        guard let data = try? Data(contentsOf: indexURL(bucket: bucket)) else { return nil }
        return try? JSONDecoder().decode(BucketIndex.self, from: data)
    }

    nonisolated private static func saveIndex(_ index: BucketIndex) {
        if let data = try? JSONEncoder().encode(index) { try? data.write(to: indexURL(bucket: index.bucket), options: .atomic) }
    }
}
