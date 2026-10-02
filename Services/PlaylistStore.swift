import Foundation
import Observation
import SwiftUI // Array.move(fromOffsets:toOffset:)

/// App-side playlists, saved as JSON in Application Support. R2 is never modified.
@Observable
@MainActor
final class PlaylistStore {
    private(set) var playlists: [Playlist] = []

    init() { load() }

    func playlist(_ id: Playlist.ID) -> Playlist? { playlists.first { $0.id == id } }

    @discardableResult
    func create(name: String, entries: [PlaylistEntry] = []) -> Playlist {
        let p = Playlist(name: name.isEmpty ? "New Playlist" : name, entries: Self.dedupe(entries))
        playlists.insert(p, at: 0)
        save()
        return p
    }

    func rename(_ id: Playlist.ID, to name: String) { mutate(id) { $0.name = name } }

    func delete(_ id: Playlist.ID) {
        playlists.removeAll { $0.id == id }
        save()
    }

    func add(_ entries: [PlaylistEntry], to id: Playlist.ID) {
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

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("playlists.json")
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let list = try? JSONDecoder().decode([Playlist].self, from: data) else { return }
        playlists = list
    }

    private func save() {
        if let data = try? JSONEncoder().encode(playlists) { try? data.write(to: fileURL, options: .atomic) }
    }
}
