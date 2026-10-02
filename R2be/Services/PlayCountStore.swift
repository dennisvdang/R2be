import Foundation

/// How many times each video has been played on this phone (shown as "N views" in the player).
/// A play counts once per time a video is started, not per resume or seek.
enum PlayCountStore {
    private static let key = "playCounts"

    static func count(for id: String) -> Int {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Int])?[id] ?? 0
    }

    static func increment(_ id: String) {
        var all = (UserDefaults.standard.dictionary(forKey: key) as? [String: Int]) ?? [:]
        all[id, default: 0] += 1
        UserDefaults.standard.set(all, forKey: key)
    }

    static func label(for id: String) -> String {
        let n = count(for: id)
        return n == 1 ? "1 view" : "\(n.formatted()) views"
    }
}
