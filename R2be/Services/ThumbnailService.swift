import AVFoundation
import CryptoKit
import UIKit
import Vision

/// Generates poster frames by streaming just enough of each video (moov atom + one keyframe) from
/// its presigned URL. Results are cached in memory and on disk, keyed by object key + ETag.
actor ThumbnailService {
    static let shared = ThumbnailService()

    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    /// Files that opened but had no frame to show (audio, or video the phone can't decode), so they
    /// aren't fetched again this session. Network failures aren't kept here; they retry.
    private var noFrame: Set<String> = []
    private let limiter = AsyncLimiter(limit: 3)
    private let dir: URL

    /// Vision feature prints of thumbnails (cache key → print), saved beside each thumbnail as
    /// "<key>.print". They power "Looks similar" in Related.
    private var prints: [String: VNFeaturePrintObservation] = [:]
    private var printsLoaded = false

    init() {
        memory.countLimit = 400
        dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    nonisolated static func cacheKey(_ item: VideoItem) -> String {
        let digest = SHA256.hash(data: Data((item.id + "|" + item.etag).utf8))
        return Data(digest).hexString
    }

    /// Synchronous memory-cache peek so scrolling back to a tile never flashes a placeholder.
    nonisolated func cached(_ item: VideoItem) -> UIImage? {
        memory.object(forKey: Self.cacheKey(item) as NSString)
    }

    func thumbnail(for item: VideoItem, videoURL: URL?, sidecarURL: URL?) async -> UIImage? {
        #if DEBUG
        if DemoMode.isOn { return DemoMode.thumbnail(for: item) }
        #endif
        let key = Self.cacheKey(item)
        if let img = memory.object(forKey: key as NSString) { return img }
        let file = dir.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: key as NSString)
            ensurePrint(of: img, key: key)
            return img
        }
        if let task = inflight[key] { return await task.value }
        if noFrame.contains(key) { return nil }

        let task = Task<UIImage?, Never> { [limiter] in
            await limiter.acquire()
            defer { Task { await limiter.release() } }
            if Task.isCancelled { return nil }
            if let sidecarURL, let img = await Self.download(sidecarURL) { return img }
            guard let videoURL else { return nil }
            let (frame, opened) = await Self.grabFrame(url: videoURL, id: item.id)
            if frame == nil, opened { await self.markNoFrame(key) }
            return frame
        }
        inflight[key] = task

        // A tile scrolled off screen cancels its request, so it stops holding a download slot.
        let image = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        inflight[key] = nil
        if let image {
            memory.setObject(image, forKey: key as NSString)
            if let jpg = image.jpegData(compressionQuality: 0.75) { try? jpg.write(to: file, options: .atomic) }
            ensurePrint(of: image, key: key)
        }
        return image
    }

    private func markNoFrame(_ key: String) { noFrame.insert(key) }

    // MARK: Looks similar

    /// Videos whose thumbnails look most like `item`'s, nearest first. Only videos whose thumbnails
    /// have been made (shown at least once) can take part.
    func lookalikes(of item: VideoItem, among videos: [VideoItem]) -> [VideoItem] {
        loadPrintsIfNeeded()
        guard let target = prints[Self.cacheKey(item)] else { return [] }
        var scored: [(video: VideoItem, distance: Float)] = []
        for v in videos where v != item {
            guard let p = prints[Self.cacheKey(v)] else { continue }
            var d: Float = 0
            if (try? target.computeDistance(&d, to: p)) != nil { scored.append((v, d)) }
        }
        return scored.sorted { $0.distance < $1.distance }.map(\.video)
    }

    /// Vision runs in its own task, so it doesn't hold up the thumbnail requests queued behind it.
    private func ensurePrint(of image: UIImage, key: String) {
        let file = dir.appendingPathComponent(key + ".print")
        guard prints[key] == nil, !FileManager.default.fileExists(atPath: file.path),
              let cg = image.cgImage else { return }
        Task.detached(priority: .utility) {
            let request = VNGenerateImageFeaturePrintRequest()
            try? VNImageRequestHandler(cgImage: cg).perform([request])
            guard let print = request.results?.first else { return }
            if let data = try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true) {
                try? data.write(to: file, options: .atomic)
            }
            await self.store(print, key: key)
        }
    }

    private func store(_ print: VNFeaturePrintObservation, key: String) { prints[key] = print }

    private func loadPrintsIfNeeded() {
        guard !printsLoaded else { return }
        printsLoaded = true
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "print" {
            let key = f.deletingPathExtension().lastPathComponent
            guard prints[key] == nil, let data = try? Data(contentsOf: f),
                  let print = try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
            else { continue }
            prints[key] = print
        }
    }

    func clearCache() {
        memory.removeAllObjects()
        noFrame = []
        prints = [:]
        printsLoaded = false
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func download(_ url: URL) async -> UIImage? {
        guard let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: result.0) else { return nil }
        return img.preparingThumbnail(of: CGSize(width: 640, height: 360)) ?? img
    }

    /// A poster frame, and whether the file opened at all (false after a network error).
    private static func grabFrame(url: URL, id: String) async -> (UIImage?, opened: Bool) {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        let opened = duration.isFinite && duration > 0
        if opened {
            await ResumeStore.setDuration(duration, for: id)
        }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 640, height: 360)
        // Loose tolerance = use the nearest keyframe = far fewer bytes downloaded.
        gen.requestedTimeToleranceBefore = CMTime(seconds: 4, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 4, preferredTimescale: 600)
        let at = duration > 0 ? min(max(duration * 0.1, 1), 20) : 1
        if let frame = try? await gen.image(at: CMTime(seconds: at, preferredTimescale: 600)) {
            return (UIImage(cgImage: frame.image), opened)
        }
        if let frame = try? await gen.image(at: .zero) { return (UIImage(cgImage: frame.image), opened) }
        return (nil, opened)
    }
}

/// Tiny async semaphore so we never hammer R2 / the network with dozens of parallel asset loads.
actor AsyncLimiter {
    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit { running += 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { running -= 1 } else { waiters.removeFirst().resume() }
    }
}
