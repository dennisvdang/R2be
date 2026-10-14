import Foundation

/// How many times each video has been played on this phone; Related favors less-played videos.
/// A play counts once per time a video is started, not per resume or seek.
enum PlayCountStore {
    private static let key = "playCounts"

    static func counts() -> [String: Int] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: Int] ?? [:]
    }

    static func increment(_ id: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        all[id, default: 0] += 1
        UserDefaults.standard.set(all, forKey: key)
    }
}
