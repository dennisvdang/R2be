import AVFoundation
import CryptoKit
import UIKit

/// Generates poster frames by streaming just enough of each video (moov atom + one keyframe) from
/// its presigned URL. Results are cached in memory and on disk, keyed by object key + ETag.
actor ThumbnailService {
    static let shared = ThumbnailService()

    private let memory = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<UIImage?, Never>] = [:]
    private let limiter = AsyncLimiter(limit: 3)
    private let dir: URL

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
        let key = Self.cacheKey(item)
        if let img = memory.object(forKey: key as NSString) { return img }
        let file = dir.appendingPathComponent(key + ".jpg")
        if let data = try? Data(contentsOf: file), let img = UIImage(data: data) {
            memory.setObject(img, forKey: key as NSString)
            return img
        }
        if let task = inflight[key] { return await task.value }

        let task = Task<UIImage?, Never> { [limiter] in
            await limiter.acquire()
            defer { Task { await limiter.release() } }
            if Task.isCancelled { return nil }
            if let sidecarURL, let img = await Self.download(sidecarURL) { return img }
            guard let videoURL else { return nil }
            return await Self.grabFrame(url: videoURL, id: item.id)
        }
        inflight[key] = task
        let image = await task.value
        inflight[key] = nil
        if let image {
            memory.setObject(image, forKey: key as NSString)
            if let jpg = image.jpegData(compressionQuality: 0.75) { try? jpg.write(to: file, options: .atomic) }
        }
        return image
    }

    func clearCache() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private static func download(_ url: URL) async -> UIImage? {
        guard let result = try? await URLSession.shared.data(from: url),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let img = UIImage(data: result.0) else { return nil }
        return img.preparingThumbnail(of: CGSize(width: 640, height: 360)) ?? img
    }

    private static func grabFrame(url: URL, id: String) async -> UIImage? {
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])
        let duration = (try? await asset.load(.duration)).map(CMTimeGetSeconds) ?? 0
        if duration.isFinite, duration > 0 {
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
            return UIImage(cgImage: frame.image)
        }
        if let frame = try? await gen.image(at: .zero) { return UIImage(cgImage: frame.image) }
        return nil
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
