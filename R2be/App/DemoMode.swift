#if DEBUG
import UIKit

/// Screenshot mode, in debug builds only. Launched with `-demoScreen <library|player|feed|playlists>`,
/// the app shows the fake library the screenshots workflow copies into Documents/demo
/// (made by screenshots/make_demo.py) instead of a real bucket, and opens that screen.
enum DemoMode {
    static let screen = UserDefaults.standard.string(forKey: "demoScreen")
    static var isOn: Bool { screen != nil }
    static let bucket = "media"

    private struct Video: Decodable {
        let key: String
        let size: Int64
        let daysAgo: Double
        let duration: Double
        var watched: Double?
    }

    private struct Library: Decodable {
        let videos: [Video]
        let playFrom: String
    }

    private static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("demo")
    }

    private static let content: Library? = (try? Data(contentsOf: dir.appendingPathComponent("library.json")))
        .flatMap { try? JSONDecoder().decode(Library.self, from: $0) }

    static var credentials: R2Credentials {
        R2Credentials(accountId: "demo", accessKeyId: "demo", secretAccessKey: "demo", bucket: bucket)
    }

    static func index() -> BucketIndex {
        let videos = (content?.videos ?? []).map {
            VideoItem(bucket: bucket, key: $0.key, size: $0.size,
                      lastModified: Date().addingTimeInterval(-$0.daysAgo * 86_400), etag: "demo")
        }
        return BucketIndex(bucket: bucket, videos: videos, imageKeys: [], builtAt: Date())
    }

    static func thumbnail(for item: VideoItem) -> UIImage? {
        UIImage(contentsOfFile: dir.appendingPathComponent(item.title + ".jpg").path)
    }

    static func streamURL(for item: VideoItem) -> URL {
        dir.appendingPathComponent(item.title + ".mp4")
    }

    /// Seeds watch progress, starts playback for the player screen, and returns the tab to show.
    @MainActor static func start(library: LibraryStore, player: PlayerController) -> AppTab {
        for v in content?.videos ?? [] {
            let id = bucket + "/" + v.key
            if let w = v.watched { ResumeStore.set(position: v.duration * w, duration: v.duration, for: id) }
            else { ResumeStore.setDuration(v.duration, for: id) }
        }
        switch screen {
        case "player":
            if let key = content?.playFrom, let item = library.video(bucket: bucket, key: key) {
                let folder = library.videos(under: item.folder, recursive: false)
                player.play(folder, startAt: item, shuffle: false, title: String(item.folderDisplay.split(separator: "/").last ?? ""))

                // Paused, the player keeps its controls on screen.
                Task { @MainActor in
                    try? await Task.sleep(for: .seconds(2))
                    player.pause()
                }
            }
            return .library
        case "feed": return .feed
        case "playlists": return .playlists
        default: return .library
        }
    }
}
#endif
