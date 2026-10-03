import Foundation

/// A playable video object in a bucket.
struct VideoItem: Identifiable, Hashable, Codable, Sendable {
    var bucket: String
    var key: String
    var size: Int64
    var lastModified: Date?
    var etag: String

    var id: String { bucket + "/" + key }
    var fileName: String { key.split(separator: "/").last.map(String.init) ?? key }
    var title: String {
        let name = fileName
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }
    /// Folder prefix including trailing slash ("" for bucket root).
    var folder: String {
        guard let slash = key.lastIndex(of: "/") else { return "" }
        return String(key[...slash])
    }
    var folderDisplay: String { folder.isEmpty ? "/" : String(folder.dropLast()) }
}

enum MediaTypes {
    /// Video and audio formats AVPlayer can stream natively. Only these are indexed and shown;
    /// everything else in the bucket is skipped. MKV/AVI/WebM need transcoding to MP4 first.
    static let playable: Set<String> = ["mp4", "m4v", "mov", "m3u8", "3gp",
                                        "mp3", "m4a", "flac", "wav"]
    static let images: Set<String> = ["jpg", "jpeg", "png", "webp"]
}

/// One entry in an app-side playlist. Nothing is ever written to R2 — entries are just references.
enum PlaylistEntry: Codable, Hashable, Identifiable, Sendable {
    case video(bucket: String, key: String)
    /// A live folder reference: re-expanded every time, so new uploads appear automatically.
    case folder(bucket: String, prefix: String, recursive: Bool)

    var id: String {
        switch self {
        case .video(let b, let k): return "v:\(b)/\(k)"
        case .folder(let b, let p, let r): return "f:\(r ? "r" : "n"):\(b)/\(p)"
        }
    }
    var bucket: String {
        switch self { case .video(let b, _), .folder(let b, _, _): return b }
    }
}

struct Playlist: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var entries: [PlaylistEntry] = []
    var created = Date()
    var updated = Date()
}

enum SortOrder: String, CaseIterable, Identifiable, Codable {
    case nameAsc, nameDesc, newest, oldest, largest, smallest, random
    var id: String { rawValue }
    var label: String {
        switch self {
        case .nameAsc: return "Name A–Z"
        case .nameDesc: return "Name Z–A"
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .largest: return "Largest"
        case .smallest: return "Smallest"
        case .random: return "Random"
        }
    }

    func apply(_ items: [VideoItem]) -> [VideoItem] {
        switch self {
        case .nameAsc: return items.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .nameDesc: return items.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedDescending }
        case .newest: return items.sorted { ($0.lastModified ?? .distantPast) > ($1.lastModified ?? .distantPast) }
        case .oldest: return items.sorted { ($0.lastModified ?? .distantPast) < ($1.lastModified ?? .distantPast) }
        case .largest: return items.sorted { $0.size > $1.size }
        case .smallest: return items.sorted { $0.size < $1.size }
        case .random: return items.shuffled()
        }
    }
}

enum GalleryLayout: String, CaseIterable, Identifiable {
    case list, compactGrid, grid, cards
    var id: String { rawValue }
    var label: String {
        switch self {
        case .list: return "List"
        case .compactGrid: return "Small grid"
        case .grid: return "Grid"
        case .cards: return "Feed cards"
        }
    }
    var symbol: String {
        switch self {
        case .list: return "list.bullet"
        case .compactGrid: return "square.grid.3x3"
        case .grid: return "square.grid.2x2"
        case .cards: return "rectangle.grid.1x2"
        }
    }
}

enum Format {
    static func bytes(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "--:--" }
        let s = Int(seconds.rounded(.down))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    static func relative(_ date: Date?) -> String {
        guard let date else { return "" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f.localizedString(for: date, relativeTo: Date())
    }
}

/// Case/diacritic-insensitive, all-tokens-must-match filename search.
enum SearchMatcher {
    static func normalize(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: ".", with: " ")
    }
    static func matches(_ item: VideoItem, tokens: [String]) -> Bool {
        let hay = normalize(item.key)
        return tokens.allSatisfy { hay.contains($0) }
    }
    static func tokens(_ query: String) -> [String] {
        normalize(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }
}
