import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Keeps the parts of the current video you've already streamed on disk, so rewinding (or seeking
/// back into anything already played) is served from the phone instead of R2.
///
/// The player is handed a `r2cache://` URL; AVFoundation then asks this resource loader for byte
/// ranges. Ranges already on disk are answered from a sparse temp file; missing ones are fetched
/// from the real signed https URL with a Range request, passed to the player and written to the file
/// as they arrive. One instance per video: the file is deleted when the video changes (`invalidate`).
/// Writing stops once `maxBytes` are cached; playback then simply continues from the network.
final class StreamCache: NSObject, AVAssetResourceLoaderDelegate, URLSessionDataDelegate {
    static let scheme = "r2cache"

    let itemID: String
    private(set) var remoteURL: URL
    private let fileURL: URL
    private let maxBytes: Int64
    private let contentType: String
    /// Pass this as the resource loader's delegate queue; all state below is touched only on it.
    let queue = DispatchQueue(label: "r2be.streamcache")
    private var session: URLSession!
    private var invalidated = false

    private var handle: FileHandle?
    private var contentLength: Int64?
    private var ranges: [Range<Int64>] = []          // cached byte ranges, sorted and merged
    private var cachedBytes: Int64 = 0
    private var pending: [Pending] = []

    private final class Pending {
        let loading: AVAssetResourceLoadingRequest
        var next: Int64                  // next byte the player still needs
        var end: Int64?                  // exclusive; nil = to end of file (length not known yet)
        var task: URLSessionDataTask?
        init(_ loading: AVAssetResourceLoadingRequest, next: Int64, end: Int64?) {
            self.loading = loading; self.next = next; self.end = end
        }
    }

    init(itemID: String, remoteURL: URL, maxBytes: Int64 = 500 * 1024 * 1024) {
        self.itemID = itemID
        self.remoteURL = remoteURL
        self.maxBytes = maxBytes
        let ext = remoteURL.pathExtension.lowercased()
        contentType = UTType(filenameExtension: ext)?.identifier ?? UTType.mpeg4Movie.identifier
        let name = String(itemID.hashValue.magnitude, radix: 16)
        fileURL = Self.directory.appendingPathComponent(name + ".part")
        super.init()
        let ops = OperationQueue()
        ops.underlyingQueue = queue
        ops.maxConcurrentOperationCount = 1
        session = URLSession(configuration: .default, delegate: self, delegateQueue: ops)
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: fileURL)
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forUpdating: fileURL)
    }

    /// The URL to give AVURLAsset (same path, custom scheme so requests come to this loader).
    var assetURL: URL {
        var c = URLComponents(url: remoteURL, resolvingAgainstBaseURL: false)
        c?.scheme = Self.scheme
        return c?.url ?? remoteURL
    }

    /// New signed link for the same video (the old one expired); cached bytes are kept.
    func updateRemoteURL(_ url: URL) { queue.async { self.remoteURL = url } }

    /// Stop everything and delete the cached bytes.
    func invalidate() {
        queue.async {
            self.invalidated = true
            for p in self.pending { p.task?.cancel(); if !p.loading.isFinished { p.loading.finishLoading() } }
            self.pending = []
            self.session.invalidateAndCancel()
            try? self.handle?.close()
            self.handle = nil
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }

    /// Remove leftovers from a previous run (e.g. the app was killed mid-video).
    static func clearAll() {
        try? FileManager.default.removeItem(at: directory)
    }

    private static var directory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlaybackCache", isDirectory: true)
    }

    // MARK: AVAssetResourceLoaderDelegate (called on `queue`)

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        guard !invalidated else { return false }
        var start: Int64 = 0
        var end: Int64? = nil
        if let d = loadingRequest.dataRequest {
            start = d.requestedOffset
            if !d.requestsAllDataToEndOfResource { end = d.requestedOffset + Int64(d.requestedLength) }
        } else {
            end = 2   // info-only request: fetch a couple of bytes to learn the length
        }
        let p = Pending(loadingRequest, next: start, end: end)
        pending.append(p)
        fillContentInfo(p)
        serve(p)
        return true
    }

    func resourceLoader(_ resourceLoader: AVAssetResourceLoader, didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        if let i = pending.firstIndex(where: { $0.loading === loadingRequest }) {
            pending[i].task?.cancel()
            pending.remove(at: i)
        }
    }

    // MARK: Serving

    private func fillContentInfo(_ p: Pending) {
        guard let info = p.loading.contentInformationRequest, let length = contentLength,
              info.contentLength == 0 else { return }
        info.contentType = contentType
        info.contentLength = length
        info.isByteRangeAccessSupported = true
    }

    /// Answer as much as possible from disk, then fetch the next missing stretch from R2.
    private func serve(_ p: Pending) {
        guard pending.contains(where: { $0 === p }) else { return }
        if p.end == nil, let length = contentLength { p.end = length }
        if p.loading.contentInformationRequest != nil && contentLength == nil {
            fetch(p, from: p.next, to: p.end)          // need the headers first
            return
        }
        while let end = p.end, p.next < end, let r = ranges.first(where: { $0.contains(p.next) }) {
            let upTo = min(end, r.upperBound, p.next + 1024 * 1024)
            guard let data = read(from: p.next, count: Int(upTo - p.next)), !data.isEmpty else { break }
            p.loading.dataRequest?.respond(with: data)
            p.next += Int64(data.count)
        }
        if let end = p.end, p.next >= end {
            finish(p, error: nil)
            return
        }
        // Fetch up to the next cached stretch (or the end) — no point re-downloading what's on disk.
        let nextCached = ranges.first(where: { $0.lowerBound > p.next })?.lowerBound
        let stop = [p.end, nextCached].compactMap { $0 }.min()
        fetch(p, from: p.next, to: stop)
    }

    private func fetch(_ p: Pending, from start: Int64, to end: Int64?) {
        guard !invalidated else { finish(p, error: nil); return }
        var req = URLRequest(url: remoteURL)
        if let end, end > start {
            req.setValue("bytes=\(start)-\(end - 1)", forHTTPHeaderField: "Range")
        } else {
            req.setValue("bytes=\(start)-", forHTTPHeaderField: "Range")
        }
        let task = session.dataTask(with: req)
        p.task = task
        task.resume()
    }

    private func finish(_ p: Pending, error: Error?) {
        if !p.loading.isFinished {
            if let error { p.loading.finishLoading(with: error) } else { p.loading.finishLoading() }
        }
        pending.removeAll { $0 === p }
    }

    private func owner(of task: URLSessionTask) -> Pending? { pending.first { $0.task === task } }

    // MARK: URLSessionDataDelegate (called on `queue`)

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let p = owner(of: dataTask), let http = response as? HTTPURLResponse else {
            completionHandler(.cancel); return
        }
        guard (200..<300).contains(http.statusCode) else {
            finish(p, error: NSError(domain: "R2be.StreamCache", code: http.statusCode,
                                     userInfo: [NSLocalizedDescriptionKey: "R2 returned HTTP \(http.statusCode)"]))
            completionHandler(.cancel); return
        }
        if contentLength == nil {
            // "Content-Range: bytes 0-1/123456" → 123456; a plain 200 gives the full length.
            if let cr = http.value(forHTTPHeaderField: "Content-Range"), let total = cr.split(separator: "/").last,
               let n = Int64(total) {
                contentLength = n
            } else if http.statusCode == 200, http.expectedContentLength > 0 {
                contentLength = http.expectedContentLength
            }
            for other in pending { fillContentInfo(other) }
        }
        if http.statusCode == 200, p.next != 0 {
            // Server ignored the Range header; can't use this response safely.
            finish(p, error: NSError(domain: "R2be.StreamCache", code: -1,
                                     userInfo: [NSLocalizedDescriptionKey: "Range requests not supported"]))
            completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let p = owner(of: dataTask) else { return }
        let offset = p.next
        // Info-only requests carry no data request; just cache what arrives.
        if let end = p.end, p.loading.dataRequest != nil {
            let wanted = Int(max(0, min(Int64(data.count), end - offset)))
            if wanted > 0 { p.loading.dataRequest?.respond(with: data.prefix(wanted)) }
        } else if p.loading.dataRequest != nil {
            p.loading.dataRequest?.respond(with: data)
        }
        write(data, at: offset)
        p.next += Int64(data.count)
        if let end = p.end, p.next >= end {
            dataTask.cancel()
            finish(p, error: nil)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let p = owner(of: task) else { return }
        p.task = nil
        if let error, (error as? URLError)?.code != .cancelled {
            finish(p, error: error)
        } else if p.loading.contentInformationRequest != nil && contentLength == nil {
            finish(p, error: NSError(domain: "R2be.StreamCache", code: -2,
                                     userInfo: [NSLocalizedDescriptionKey: "Couldn't read the video's size"]))
        } else if p.loading.dataRequest == nil {
            fillContentInfo(p)
            finish(p, error: nil)
        } else {
            serve(p)   // reached a cached stretch (or the end): continue from disk / next gap
        }
    }

    // MARK: Disk

    private func read(from offset: Int64, count: Int) -> Data? {
        guard let handle, count > 0 else { return nil }
        do {
            try handle.seek(toOffset: UInt64(offset))
            return try handle.read(upToCount: count)
        } catch { return nil }
    }

    private func write(_ data: Data, at offset: Int64) {
        guard let handle, !data.isEmpty, cachedBytes + Int64(data.count) <= maxBytes else { return }
        do {
            try handle.seek(toOffset: UInt64(offset))
            try handle.write(contentsOf: data)
        } catch { return }
        insert(offset..<(offset + Int64(data.count)))
    }

    private func insert(_ new: Range<Int64>) {
        ranges = Self.merging(new, into: ranges)
        cachedBytes = ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    /// `ranges` with `new` added, sorted, with overlapping and touching ranges joined.
    static func merging(_ new: Range<Int64>, into ranges: [Range<Int64>]) -> [Range<Int64>] {
        var merged = new
        var kept: [Range<Int64>] = []
        for r in ranges {
            if r.upperBound < merged.lowerBound || r.lowerBound > merged.upperBound {
                kept.append(r)
            } else {
                merged = min(r.lowerBound, merged.lowerBound)..<max(r.upperBound, merged.upperBound)
            }
        }
        kept.append(merged)
        return kept.sorted { $0.lowerBound < $1.lowerBound }
    }
}
