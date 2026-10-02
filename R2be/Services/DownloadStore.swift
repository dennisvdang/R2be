import CryptoKit
import Foundation
import Observation

/// Offline copies of videos. Files download in a background URLSession (they keep going while the
/// app is closed) into Application Support/Downloads, excluded from iCloud backup. A JSON manifest
/// keeps each download's VideoItem, so the Downloads tab and playback work with no connection.
@Observable
@MainActor
final class DownloadStore: NSObject {
    static let shared = DownloadStore()

    struct Entry: Codable, Identifiable {
        var item: VideoItem
        var fileName: String
        var bytes: Int64
        var added: Date
        var id: String { item.id }
    }

    private(set) var entries: [String: Entry] = [:]            // VideoItem.id → finished download
    private(set) var progress: [String: Double] = [:]          // VideoItem.id → 0...1 while downloading
    private(set) var failed: [String: String] = [:]            // VideoItem.id → error message
    @ObservationIgnored private var pendingItems: [String: VideoItem] = [:]
    @ObservationIgnored private var tasks: [String: URLSessionDownloadTask] = [:]

    /// Set by AppDelegate when iOS wakes the app to finish background downloads.
    @ObservationIgnored var backgroundCompletionHandler: (() -> Void)?

    @ObservationIgnored private var session: URLSession!

    private override init() {
        super.init()
        let config = URLSessionConfiguration.background(withIdentifier: "r2be.downloads")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        session = URLSession(configuration: config, delegate: DownloadDelegate(store: self), delegateQueue: .main)
        load()
        // Reconnect to downloads that were still running when the app last closed.
        session.getAllTasks { [weak self] tasks in
            Task { @MainActor in
                for case let t as URLSessionDownloadTask in tasks {
                    guard let item = Self.decode(t.taskDescription) else { continue }
                    self?.pendingItems[item.id] = item
                    self?.tasks[item.id] = t
                    self?.progress[item.id] = t.progress.fractionCompleted
                }
            }
        }
    }

    // MARK: Queries

    var sortedEntries: [Entry] { entries.values.sorted { $0.added > $1.added } }
    var totalBytes: Int64 { entries.values.reduce(0) { $0 + $1.bytes } }

    func isDownloaded(_ item: VideoItem) -> Bool { entries[item.id] != nil }
    func isDownloading(_ item: VideoItem) -> Bool { progress[item.id] != nil }

    func localURL(for item: VideoItem) -> URL? {
        guard let e = entries[item.id] else { return nil }
        let url = Self.directory.appendingPathComponent(e.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Actions

    /// `remoteURL` is a signed link (made by LibraryStore) good for the whole download.
    func download(_ item: VideoItem, from remoteURL: URL) {
        guard entries[item.id] == nil, tasks[item.id] == nil else { return }
        let task = session.downloadTask(with: remoteURL)
        task.taskDescription = Self.encode(item)
        pendingItems[item.id] = item
        tasks[item.id] = task
        progress[item.id] = 0
        failed[item.id] = nil
        task.resume()
    }

    func cancel(_ item: VideoItem) {
        tasks[item.id]?.cancel()
        clearPending(item.id)
    }

    func remove(_ item: VideoItem) {
        cancel(item)
        if let e = entries.removeValue(forKey: item.id) {
            try? FileManager.default.removeItem(at: Self.directory.appendingPathComponent(e.fileName))
            save()
        }
    }

    func removeAll() {
        for t in tasks.values { t.cancel() }
        tasks = [:]; pendingItems = [:]; progress = [:]; failed = [:]
        entries = [:]
        try? FileManager.default.removeItem(at: Self.directory)
        save()
    }

    // MARK: Delegate callbacks (main queue)

    fileprivate func didProgress(_ description: String?, fraction: Double) {
        guard let item = Self.decode(description), tasks[item.id] != nil || pendingItems[item.id] != nil else { return }
        progress[item.id] = fraction
    }

    /// Called synchronously from didFinishDownloadingTo: the temp file must be moved before returning.
    fileprivate func didFinish(_ description: String?, tempFile: URL) {
        guard let item = Self.decode(description) else { return }
        let ext = (item.key as NSString).pathExtension.lowercased()
        let name = Self.fileName(for: item) + (ext.isEmpty ? "" : "." + ext)
        let dest = Self.directory.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.moveItem(at: tempFile, to: dest)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var excluded = dest
            try? excluded.setResourceValues(values)
            let attrs = try? FileManager.default.attributesOfItem(atPath: dest.path)
            let size = (attrs?[.size] as? NSNumber)?.int64Value ?? item.size
            entries[item.id] = Entry(item: item, fileName: name, bytes: size, added: Date())
            save()
        } catch {
            failed[item.id] = error.localizedDescription
        }
        clearPending(item.id)
    }

    fileprivate func didComplete(_ description: String?, error: Error?, httpStatus: Int?) {
        guard let item = Self.decode(description) else { return }
        if let error, (error as? URLError)?.code != .cancelled {
            failed[item.id] = error.localizedDescription
        } else if let httpStatus, !(200..<300).contains(httpStatus), entries[item.id] == nil {
            failed[item.id] = "Download failed (HTTP \(httpStatus))."
        }
        clearPending(item.id)
    }

    fileprivate func finishBackgroundEvents() {
        backgroundCompletionHandler?()
        backgroundCompletionHandler = nil
    }

    private func clearPending(_ id: String) {
        tasks[id] = nil
        pendingItems[id] = nil
        progress[id] = nil
    }

    // MARK: Persistence

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
    }
    private static var manifestURL: URL { directory.appendingPathComponent("downloads.json") }

    private func load() {
        guard let data = try? Data(contentsOf: Self.manifestURL),
              let list = try? JSONDecoder().decode([Entry].self, from: data) else { return }
        entries = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func save() {
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(Array(entries.values)) {
            try? data.write(to: Self.manifestURL, options: .atomic)
        }
    }

    private static func fileName(for item: VideoItem) -> String {
        SHA256.hash(data: Data(item.id.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func encode(_ item: VideoItem) -> String? {
        (try? JSONEncoder().encode(item)).flatMap { String(data: $0, encoding: .utf8) }
    }

    private static func decode(_ s: String?) -> VideoItem? {
        guard let data = s?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VideoItem.self, from: data)
    }
}

/// URLSession delegate; the session's delegate queue is .main, so it can hop straight to the store.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    weak var store: DownloadStore?
    init(store: DownloadStore) { self.store = store }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let fraction = totalBytesExpectedToWrite > 0 ? Double(totalBytesWritten) / Double(totalBytesExpectedToWrite) : 0
        let description = downloadTask.taskDescription
        MainActor.assumeIsolated { store?.didProgress(description, fraction: fraction) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else { return }   // reported in didCompleteWithError
        let description = downloadTask.taskDescription
        MainActor.assumeIsolated { store?.didFinish(description, tempFile: location) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let status = (task.response as? HTTPURLResponse)?.statusCode
        let description = task.taskDescription
        MainActor.assumeIsolated { store?.didComplete(description, error: error, httpStatus: status) }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { store?.finishBackgroundEvents() }
    }
}
