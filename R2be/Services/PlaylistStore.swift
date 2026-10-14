import Foundation
import Observation
import SwiftUI // Array.move(fromOffsets:toOffset:)

/// App-side playlists, saved as JSON in Application Support. R2 is never modified.
@Observable
@MainActor
final class PlaylistStore {
    private(set) var playlists: [Playlist] = []

    /// Built-in playlist that always exists, so there's somewhere to save videos from day one.
    static let favoritesID = UUID(uuidString: "00000000-0000-0000-0000-00000000FA7E")!

    private let fileURL: URL

    /// Set when a saved file exists but couldn't be backed up, so nothing saves over it.
    @ObservationIgnored private var readOnly = false

    init(fileURL: URL = PlaylistStore.defaultFileURL) {
        self.fileURL = fileURL
        load()
        ensureFavorites()
    }

    func isFavorites(_ id: Playlist.ID) -> Bool { id == Self.favoritesID }

    /// The playlist videos were most recently added to, offered as a one-tap option in menus.
    private(set) var recentID: Playlist.ID? = UserDefaults.standard.string(forKey: "recentPlaylistID").flatMap { UUID(uuidString: $0) }
    var recentPlaylist: Playlist? { recentID.flatMap(playlist) }

    private func markRecent(_ id: Playlist.ID) {
        recentID = id
        UserDefaults.standard.set(id.uuidString, forKey: "recentPlaylistID")
    }

    /// Videos in `entries` that aren't in the playlist yet.
    func newEntries(_ entries: [PlaylistEntry], for id: Playlist.ID) -> [PlaylistEntry] {
        let existing = Set(playlist(id)?.entries.map(\.id) ?? [])
        return Self.dedupe(entries).filter { !existing.contains($0.id) }
    }

    func playlist(_ id: Playlist.ID) -> Playlist? { playlists.first { $0.id == id } }

    @discardableResult
    func create(name: String, entries: [PlaylistEntry] = []) -> Playlist {
        let p = Playlist(name: Self.cleanName(name) ?? "New Playlist", entries: Self.dedupe(entries))
        playlists.insert(p, at: playlists.first?.id == Self.favoritesID ? 1 : 0)   // Favorites stays on top
        if !entries.isEmpty { markRecent(p.id) }
        save()
        return p
    }

    func rename(_ id: Playlist.ID, to name: String) {
        guard let name = Self.cleanName(name) else { return }
        mutate(id) { $0.name = name }
    }

    /// The name with surrounding spaces removed; nil when nothing is left.
    private static func cleanName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func delete(_ id: Playlist.ID) {
        guard id != Self.favoritesID else { return }
        playlists.removeAll { $0.id == id }
        save()
    }

    func add(_ entries: [PlaylistEntry], to id: Playlist.ID) {
        markRecent(id)
        mutate(id) { $0.entries = Self.dedupe($0.entries + entries) }
    }

    func remove(entryIDs: Set<String>, from id: Playlist.ID) {
        mutate(id) { $0.entries.removeAll { entryIDs.contains($0.id) } }
    }

    func move(in id: Playlist.ID, from: IndexSet, to: Int) {
        mutate(id) { $0.entries.move(fromOffsets: from, toOffset: to) }
    }

    /// Combine several playlists into a new one (sources are left untouched).
    @discardableResult
    func merge(_ ids: [Playlist.ID], name: String) -> Playlist {
        let entries = ids.compactMap(playlist).flatMap(\.entries)
        return create(name: name, entries: entries)
    }

    func duplicate(_ id: Playlist.ID) {
        guard let p = playlist(id) else { return }
        create(name: p.name + " copy", entries: p.entries)
    }

    private func ensureFavorites() {
        if let i = playlists.firstIndex(where: { $0.id == Self.favoritesID }) {
            if i != 0 { playlists.insert(playlists.remove(at: i), at: 0); save() }
        } else {
            playlists.insert(Playlist(id: Self.favoritesID, name: "Favorites"), at: 0)
            save()
        }
    }

    private func mutate(_ id: Playlist.ID, _ change: (inout Playlist) -> Void) {
        guard let i = playlists.firstIndex(where: { $0.id == id }) else { return }
        change(&playlists[i])
        playlists[i].updated = Date()
        save()
    }

    private static func dedupe(_ entries: [PlaylistEntry]) -> [PlaylistEntry] {
        var seen = Set<String>()
        return entries.filter { seen.insert($0.id).inserted }
    }

    // MARK: Persistence

    nonisolated static var defaultFileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("playlists.json")
    }

    /// Where an unreadable save file is copied before a fresh list replaces it.
    var backupURL: URL { fileURL.deletingPathExtension().appendingPathExtension("corrupt.json") }

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            playlists = try JSONDecoder().decode([Playlist].self, from: Data(contentsOf: fileURL))
        } catch {
            try? FileManager.default.removeItem(at: backupURL)
            readOnly = (try? FileManager.default.copyItem(at: fileURL, to: backupURL)) == nil
        }
    }

    private func save() {
        guard !readOnly else { return }
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(playlists) { try? data.write(to: fileURL, options: .atomic) }
    }
}
