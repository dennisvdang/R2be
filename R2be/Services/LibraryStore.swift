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
    private(set) var connections: [R2Credentials]
    private(set) var activeBucket: String
    private(set) var indexes: [String: BucketIndex] = [:]
    var isIndexing = false
    var indexProgress = 0
    var lastError: String?

    @ObservationIgnored private var folderCache: [String: FolderContents] = [:]
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var otherBucketIndexes: [String: BucketIndex] = [:]

    /// Pages listed so far by an unfinished refresh. A refresh that dies when the phone locks
    /// picks up from here instead of starting over.
    /// ponytail: kept in memory only, so a refresh restarts if iOS kills the app; persist it if that bites.
    @ObservationIgnored private var partial: PartialIndex?

    private struct PartialIndex {
        let bucket: String
        let prefix: String
        var videos: [VideoItem] = []
        var imageKeys = Set<String>()
        var scanned = 0
        var token: String?
    }

    private static let activeBucketKey = "activeBucket"

    init() {
        let saved = KeychainStore.load()
        let last = UserDefaults.standard.string(forKey: Self.activeBucketKey)
        connections = saved
        activeBucket = saved.first { $0.bucket == last }?.bucket ?? saved.first?.bucket ?? ""
        if !activeBucket.isEmpty { indexes[activeBucket] = Self.loadIndex(bucket: activeBucket) }
    }

    var credentials: R2Credentials? { connections.first { $0.bucket == activeBucket } }
    var isConfigured: Bool { credentials != nil }

    /// The folder the active bucket is limited to; the Library opens here.
    var rootPrefix: String { credentials?.rootPrefix ?? "" }
    var activeIndex: BucketIndex? { indexes[activeBucket] }
    var allVideos: [VideoItem] { activeIndex?.videos ?? [] }

    /// Each bucket signs with its own token, so playlists can mix buckets.
    func client(for bucket: String) -> R2Client? {
        connections.first { $0.bucket == bucket }.map { R2Client(credentials: $0) }
    }

    // MARK: Connections

    /// Adds a connection, or replaces the one saved under `replacing`, and makes it active.
    func save(credentials new: R2Credentials, replacing old: String? = nil) {
        connections.removeAll { $0.bucket == new.bucket || $0.bucket == old }
        connections.append(new)
        KeychainStore.save(connections)
        select(bucket: new.bucket, forceRefresh: true)
    }

    func select(bucket: String, forceRefresh: Bool = false) {
        guard connections.contains(where: { $0.bucket == bucket }) else { return }
        activeBucket = bucket
        UserDefaults.standard.set(bucket, forKey: Self.activeBucketKey)
        folderCache = [:]
        lastError = nil
        if indexes[bucket] == nil { indexes[bucket] = Self.loadIndex(bucket: bucket) }
        if forceRefresh || isIndexing { refresh() } else { refreshIfStale() }
    }

    func remove(bucket: String) {
        connections.removeAll { $0.bucket == bucket }
        KeychainStore.save(connections)
        indexes[bucket] = nil
        if activeBucket == bucket {
            refreshTask?.cancel()
            isIndexing = false
            activeBucket = ""
            if let next = connections.first { select(bucket: next.bucket) }
        }
    }

    func signOut() {
        refreshTask?.cancel()
        isIndexing = false
        KeychainStore.delete()
        connections = []
        activeBucket = ""
        indexes = [:]
        folderCache = [:]
    }

    // MARK: Indexing

    func refresh() {
        guard let client = client(for: activeBucket) else { return }
        refreshTask?.cancel()
        let bucket = activeBucket
        let prefix = rootPrefix
        let resume = partial.flatMap { $0.bucket == bucket && $0.prefix == prefix ? $0 : nil }
            ?? PartialIndex(bucket: bucket, prefix: prefix)
        isIndexing = true
        indexProgress = resume.scanned
        lastError = nil
        refreshTask = Task {
            var run = resume
            do {
                repeat {
                    let page = try await client.listObjects(bucket: bucket, prefix: prefix, continuationToken: run.token)
                    try Task.checkCancellation()
                    let part = Self.buildIndex(bucket: bucket, objects: page.objects)
                    run.videos += part.videos
                    run.imageKeys.formUnion(part.imageKeys)
                    run.scanned += page.objects.count
                    run.token = page.isTruncated ? page.nextContinuationToken : nil
                    self.partial = run
                    self.indexProgress = run.scanned
                } while run.token != nil

                self.partial = nil
                let index = BucketIndex(bucket: bucket, videos: run.videos, imageKeys: run.imageKeys, builtAt: Date())
                self.indexes[bucket] = index
                self.folderCache = [:]
                Self.saveIndex(index)
            } catch {
                if !Task.isCancelled { self.lastError = error.localizedDescription }

                // R2 rejected the saved page token; the next refresh starts clean.
                if case .http(400, _)? = error as? R2Error { self.partial = nil }
            }

            // A newer refresh (e.g. after switching buckets) owns the indexing state now.
            if !Task.isCancelled { self.isIndexing = false }
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

    nonisolated static func buildIndex(bucket: String, objects: [R2Object]) -> BucketIndex {
        var videos: [VideoItem] = []
        var images = Set<String>()
        for o in objects {
            if o.key.hasSuffix("/") { continue }                       // folder placeholder objects
            if o.key.split(separator: "/").contains(where: { $0.hasPrefix(".") }) { continue } // ._AppleDouble, .DS_Store, hidden dirs
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

    func streamURL(for item: VideoItem) -> URL? {
        let hours = UserDefaults.standard.double(forKey: "presignHours")
        return client(for: item.bucket)?.presignedURL(bucket: item.bucket, key: item.key, expires: (hours > 0 ? hours : 6) * 3600)
    }

    /// 24-hour link for the share sheet.
    func shareURL(for item: VideoItem) -> URL? {
        client(for: item.bucket)?.presignedURL(bucket: item.bucket, key: item.key, expires: 24 * 3600)
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
        return client(for: item.bucket)?.presignedURL(bucket: item.bucket, key: hit, expires: 24 * 3600)
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
