import AVFoundation
import MediaPlayer
import Observation
import SwiftUI // Array.remove(atOffsets:)
import UIKit

/// One shared AVPlayer for the whole app: the full-screen player, the mini player and the Feed
/// all render the same instance, so audio never doubles up and position carries across screens.
@Observable
@MainActor
final class PlayerController {
    let player = AVPlayer()
    let pip = PiPManager()

    private(set) var queue: [VideoItem] = []
    /// Play order as indices into `queue`. Shuffle just permutes this; Up Next reads from it.
    private(set) var order: [Int] = []
    private(set) var position: Int = 0

    /// True while the Feed tab owns the queue; the Feed only drives the player then.
    private(set) var isFeedQueue = false
    private(set) var sourceTitle = ""

    var isPresented = false          // full-screen player sheet
    var startFullscreen = false      // open the player straight into landscape fullscreen (Feed → Expand)
    private(set) var isPlaying = false
    private(set) var isBuffering = false
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    var isScrubbing = false
    var errorMessage: String?

    var shuffle: Bool = UserDefaults.standard.bool(forKey: "shuffle") {
        didSet { UserDefaults.standard.set(shuffle, forKey: "shuffle"); rebuildOrder(keepCurrent: true) }
    }
    var autoplay: Bool = UserDefaults.standard.object(forKey: "autoplay") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoplay, forKey: "autoplay") }
    }
    /// On by default: after the last video the queue starts over, and Up Next shows that wrap-around.
    var loopQueue: Bool = UserDefaults.standard.object(forKey: "loopQueue") as? Bool ?? true {
        didSet { UserDefaults.standard.set(loopQueue, forKey: "loopQueue") }
    }
    var rate: Float = 1.0 {
        didSet { if isPlaying { player.rate = rate }; updateNowPlaying() }
    }

    @ObservationIgnored weak var library: LibraryStore?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var itemStatusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var lastResumeSave = Date.distantPast
    /// When the current item's signed link was made, to replace it before it expires.
    @ObservationIgnored private var linkCreated = Date.distantPast
    @ObservationIgnored private var retriedExpiredLink = false
    /// Byte cache for the current video so rewinds don't re-download (see StreamCache).
    @ObservationIgnored private var streamCache: StreamCache?
    /// After a playback failure the retry skips the cache, in case the cache was the problem.
    @ObservationIgnored private var bypassCacheFor: String?

    /// True once the current link is within 5 minutes of expiring (e.g. paused overnight).
    private var linkIsStale: Bool {
        if let item = current, DownloadStore.shared.isDownloaded(item) { return false }
        let lifetime = library?.streamLinkLifetime ?? 6 * 3600
        return Date().timeIntervalSince(linkCreated) > lifetime - 300
    }

    enum SkipUnit: String, CaseIterable { case seconds, keyframes }

    var skipUnit = SkipUnit(rawValue: UserDefaults.standard.string(forKey: "skipUnit") ?? "") ?? .seconds {
        didSet { UserDefaults.standard.set(skipUnit.rawValue, forKey: "skipUnit"); updateRemoteSkip() }
    }
    var rewindAmount: Double = UserDefaults.standard.object(forKey: "rewindAmount") as? Double ?? 10 {
        didSet { UserDefaults.standard.set(rewindAmount, forKey: "rewindAmount"); updateRemoteSkip() }
    }
    var forwardAmount: Double = UserDefaults.standard.object(forKey: "forwardAmount") as? Double ?? 30 {
        didSet { UserDefaults.standard.set(forwardAmount, forKey: "forwardAmount"); updateRemoteSkip() }
    }

    /// Where an in-flight seek is headed. While set, the time readout holds this value instead of
    /// the player's stale position, so the scrubber doesn't snap back before the seek lands.
    @ObservationIgnored private var seekTarget: Double?
    @ObservationIgnored private var seekGeneration = 0

    init() {
        player.allowsExternalPlayback = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.tick(t) }
        }
        statusObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let status = p.timeControlStatus
            Task { @MainActor in
                self?.isPlaying = status != .paused
                self?.isBuffering = status == .waitingToPlayAtSpecifiedRate
                self?.updateNowPlaying()
            }
        }
        configureRemoteCommands()
        pip.onWillStart = { [weak self] in self?.isPresented = false }
        pip.onRestore = { [weak self] in self?.isPresented = true }

        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.wasPlayingOnResign = self?.isPlaying ?? false }
        }
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.keepPlayingInBackground() }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.pip.reattachLayers() }
        }
    }

    @ObservationIgnored private var wasPlayingOnResign = false

    /// Leaving the app mid-video: automatic PiP gets a moment to start. If it didn't (screen locked,
    /// or PiP off in iOS Settings), the video detaches from its surfaces so the audio keeps playing.
    private func keepPlayingInBackground() {
        guard wasPlayingOnResign else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.pip.isActive, UIApplication.shared.applicationState == .background else { return }
                self.pip.detachLayersForBackground()
                self.player.playImmediately(atRate: self.rate)
            }
        }
    }

    // MARK: - Derived

    var current: VideoItem? {
        guard order.indices.contains(position), queue.indices.contains(order[position]) else { return nil }
        return queue[order[position]]
    }
    var hasNext: Bool { position + 1 < order.count || (loopQueue && !order.isEmpty) || !related.isEmpty }

    /// The next few videos in play order (the rest of the folder or playlist), shown above Related.
    var upNext: [VideoItem] { order.dropFirst(position + 1).prefix(5).map { queue[$0] } }

    // MARK: - Related (plays next once the queue runs out)

    /// Related videos for the current one, revealed 7 at a time (see `relatedBatch`).
    private(set) var related: [VideoItem] = []
    var canShowMoreRelated: Bool {
        let shown = Set(related.map(\.id))
        return (namePool + lookPool + freshPool).contains { !shown.contains($0.id) && $0 != current }
    }
    @ObservationIgnored private var namePool: [VideoItem] = []
    @ObservationIgnored private var lookPool: [VideoItem] = []
    @ObservationIgnored private var freshPool: [VideoItem] = []
    @ObservationIgnored private var nextPart: VideoItem?
    @ObservationIgnored private var relatedFor: String?

    /// Videos shown in Related this session, oldest first; they're less likely to come back.
    @ObservationIgnored private var recentlyShown: [String] = []

    func showMoreRelated() {
        var shown = Set(related.map(\.id))
        if let current { shown.insert(current.id) }
        let plays = PlayCountStore.counts()
        let seen = Set(recentlyShown)
        var rng = SystemRandomNumberGenerator()
        let batch = Self.relatedBatch(
            names: namePool, looks: lookPool, fresh: freshPool,
            pinned: related.isEmpty ? nextPart : nil, excluding: shown,
            weight: { v in ((plays[v.id] ?? 0) > 0 ? 0.35 : 1) * (seen.contains(v.id) ? 0.3 : 1) },
            using: &rng)
        related += batch
        recentlyShown = Array((recentlyShown + batch.map(\.id)).suffix(300))
    }

    /// One batch of Related: `byName` name matches with the next series part pinned first, then
    /// `byFresh` new uploads from other folders and `byLook` look-alikes at random spots. Each pick
    /// is drawn from a window of the strongest remaining candidates, weighted by rank and by
    /// `weight` (lower for videos already played or already shown), so a video gets a different
    /// batch each visit instead of the same top matches. A pool that runs dry is topped up from the others.
    nonisolated static func relatedBatch<R: RandomNumberGenerator>(
        names: [VideoItem], looks: [VideoItem], fresh: [VideoItem], pinned: VideoItem? = nil,
        excluding shown: Set<String>, weight: (VideoItem) -> Double = { _ in 1 },
        byName: Int = 4, byFresh: Int = 1, byLook: Int = 2, using rng: inout R
    ) -> [VideoItem] {
        var taken = shown
        func draw(_ pool: [VideoItem], _ n: Int, window: Int) -> [VideoItem] {
            var candidates = Array(pool.filter { !taken.contains($0.id) }.prefix(max(window, n)))
            var out: [VideoItem] = []
            while out.count < n, !candidates.isEmpty {
                let weights = candidates.enumerated().map { i, v in weight(v) / Double(i + 1) }
                let total = weights.reduce(0, +)

                // With every weight at zero, fall back to the strongest match.
                var pick = 0
                if total > 0 {
                    var r = Double.random(in: 0..<total, using: &rng)
                    pick = weights.firstIndex { r -= $0; return r < 0 } ?? candidates.count - 1
                }
                let v = candidates.remove(at: pick)
                taken.insert(v.id)
                out.append(v)
            }
            return out
        }

        var batch: [VideoItem] = []
        if let pinned, taken.insert(pinned.id).inserted { batch.append(pinned) }
        batch += draw(names, byName - batch.count, window: 3 * byName)
        var extras = draw(fresh, byFresh, window: 40) + draw(looks, byLook, window: 4 * byLook)
        let target = byName + byFresh + byLook
        batch += draw(names, target - batch.count - extras.count, window: 3 * byName)
        extras += draw(looks, target - batch.count - extras.count, window: 4 * byLook)
        extras += draw(fresh, target - batch.count - extras.count, window: 40)

        let first = pinned != nil && batch.first == pinned ? 1 : 0
        for v in extras { batch.insert(v, at: Int.random(in: first...batch.count, using: &rng)) }
        return batch
    }

    private func refreshRelated() {
        guard let item = current, let library, relatedFor != item.id else { return }
        relatedFor = item.id
        related = []
        namePool = library.relatedPool(for: item)
        freshPool = library.freshPool(for: item)
        nextPart = library.nextPart(after: item)
        lookPool = []
        let videos = library.allVideos
        Task {
            let looks = await ThumbnailService.shared.lookalikes(of: item, among: videos)
            guard relatedFor == item.id else { return }
            lookPool = looks
            showMoreRelated()
        }
    }

    // MARK: - Starting playback

    /// Replace the queue and start playing. `start == nil` + shuffle starts at a random video.
    func play(_ items: [VideoItem], startAt start: VideoItem? = nil, shuffle shuffleOverride: Bool? = nil,
              title: String, isFeed: Bool = false, present: Bool = true, keepGivenOrder: Bool = false) {
        guard !items.isEmpty else { return }
        queue = items
        isFeedQueue = isFeed
        sourceTitle = title
        if let shuffleOverride, shuffleOverride != shuffle {
            // Don't rebuild against the old order; buildOrder below handles it.
            withoutRebuild { shuffle = shuffleOverride }
        }
        let randomStart = shuffle && !keepGivenOrder
        let startIndex = start.flatMap { s in items.firstIndex(of: s) } ?? (randomStart ? Int.random(in: 0..<items.count) : 0)
        buildOrder(startingWith: startIndex, shuffled: shuffle && !keepGivenOrder)
        loadCurrent()
        if present { isPresented = true }
    }

    /// Shuffle button on a folder/playlist: random first pick, shuffle stays on for what follows.
    func shufflePlay(_ items: [VideoItem], title: String) {
        play(items, startAt: nil, shuffle: true, title: title)
    }

    /// Play this video now without losing the rest of the queue (used by Related).
    func playNow(_ item: VideoItem) {
        if let qi = queue.firstIndex(of: item), order.contains(qi) { jump(to: item); return }
        playNext(item)
        next()
    }

    func jump(to item: VideoItem) {
        guard let qi = queue.firstIndex(of: item), let p = order.firstIndex(of: qi) else { return }
        saveResume()
        position = p
        loadCurrent()
    }

    /// Queue an item right after the current one (moving it if it's already queued).
    func playNext(_ item: VideoItem) {
        guard !queue.isEmpty else { play([item], title: "Queue"); return }
        guard item != current else { return }
        let qi = queueIndex(for: item)
        if let existing = order.firstIndex(of: qi) {
            order.remove(at: existing)
            if existing < position { position -= 1 }
        }
        order.insert(qi, at: min(position + 1, order.count))
    }

    func addToQueue(_ items: [VideoItem]) {
        guard !queue.isEmpty else { play(items, title: "Queue"); return }
        for i in items {
            let qi = queueIndex(for: i)
            if !order.contains(qi) { order.append(qi) }
        }
    }

    private func queueIndex(for item: VideoItem) -> Int {
        if let i = queue.firstIndex(of: item) { return i }
        queue.append(item)
        return queue.count - 1
    }

    // MARK: - Sleep timer

    enum SleepTimer: Equatable {
        case off
        case at(Date)            // pause at this time
        case endOfVideo          // pause when the current video finishes
    }
    private(set) var sleepTimer: SleepTimer = .off
    @ObservationIgnored private var sleepTask: Task<Void, Never>?

    func setSleepTimer(minutes: Int) {
        let end = Date().addingTimeInterval(TimeInterval(minutes * 60))
        sleepTimer = .at(end)
        sleepTask?.cancel()
        sleepTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Double(minutes * 60)))
            guard !Task.isCancelled else { return }
            self?.sleepTimerFired()
        }
    }

    func setSleepAtEndOfVideo() {
        sleepTask?.cancel()
        sleepTimer = .endOfVideo
    }

    func cancelSleepTimer() {
        sleepTask?.cancel()
        sleepTimer = .off
    }

    private func sleepTimerFired() {
        sleepTimer = .off
        pause()
    }

    // MARK: - Transport

    func togglePlay() { isPlaying ? pause() : resume() }

    func resume() {
        if current == nil { return }
        if linkIsStale { reloadWithFreshLink(); return }
        if duration > 0, currentTime >= duration - 0.5 { seek(to: 0) }
        player.playImmediately(atRate: rate)
    }

    func pause() {
        player.pause()
        saveResume(force: true)
    }

    func skipForward() { skip(forward: true) }
    func skipBackward() { skip(forward: false) }

    private func skip(forward: Bool) {
        let amount = forward ? forwardAmount : rewindAmount
        guard skipUnit == .keyframes else { skip(forward ? amount : -amount); return }
        let from = currentTime
        Task {
            if let t = await keyframeTime(from: from, count: forward ? Int(amount) : -Int(amount)) { seek(to: t) }
            else { skip(forward ? amount : -amount) }
        }
    }

    /// Presentation time `count` keyframes away from `t` (negative = backwards), or nil when the
    /// stream can't expose its sample table (e.g. HLS).
    private func keyframeTime(from t: Double, count: Int) async -> Double? {
        guard let asset = player.currentItem?.asset,
              let track = try? await asset.loadTracks(withMediaType: .video).first,
              (try? await track.load(.canProvideSampleCursors)) == true,
              let cursor = track.makeSampleCursor(presentationTimeStamp: CMTime(seconds: t, preferredTimescale: 600))
        else { return nil }
        let step: Int64 = count > 0 ? 1 : -1
        var found = 0
        while found < abs(count), cursor.stepInPresentationOrder(byCount: step) == step {
            if cursor.currentSampleSyncInfo.sampleIsFullSync.boolValue { found += 1 }
        }
        return found > 0 ? CMTimeGetSeconds(cursor.presentationTimeStamp) : nil
    }

    /// "+30s" / "−3 keyframes", for the double-tap bubble and buttons.
    func skipLabel(forward: Bool) -> String {
        let n = Int(forward ? forwardAmount : rewindAmount)
        return (forward ? "+" : "−") + (skipUnit == .seconds ? "\(n)s" : "\(n) keyframe\(n == 1 ? "" : "s")")
    }

    /// Numbered SF Symbol when one exists for the amount, plain arrow otherwise.
    func skipSymbol(forward: Bool) -> String {
        let n = Int(forward ? forwardAmount : rewindAmount)
        let base = forward ? "goforward" : "gobackward"
        return skipUnit == .seconds && [5, 10, 15, 30, 45, 60].contains(n) ? "\(base).\(n)" : base
    }

    private func updateRemoteSkip() {
        let c = MPRemoteCommandCenter.shared()
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: forwardAmount)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: rewindAmount)]
    }

    private func skip(_ seconds: Double) {
        let target = currentTime + seconds
        if duration > 0, target >= duration { seek(to: max(duration - 0.5, 0)); return }
        seek(to: max(target, 0))
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        seekTarget = seconds
        seekGeneration += 1
        let generation = seekGeneration

        // Up to 1.5 s either way lets AVPlayer land on a nearby keyframe instead of fetching the
        // previous keyframe and decoding forward to the exact frame, so seeks start sooner.
        let tolerance = CMTime(seconds: 1.5, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            Task { @MainActor in

                // Only the latest seek releases the hold; superseded ones finish silently.
                guard let self, generation == self.seekGeneration else { return }
                self.seekTarget = nil
                self.updateNowPlaying()
            }
        }
    }

    @discardableResult
    func next() -> Bool {
        saveResume(force: true)
        if position + 1 < order.count {
            position += 1
        } else if loopQueue, !order.isEmpty {
            position = 0
        } else if let upcoming = related.first {

            // The queue ran out: carry on with the top related video.
            playNext(upcoming)
            position += 1
        } else {
            return false
        }
        loadCurrent()
        return true
    }

    func previous() {
        if currentTime > 5 || position == 0 { seek(to: 0); return }
        saveResume(force: true)
        position -= 1
        loadCurrent()
    }

    func stop() {
        saveResume(force: true)
        player.pause()
        player.replaceCurrentItem(with: nil)
        queue = []; order = []; position = 0
        related = []; namePool = []; lookPool = []; freshPool = []; nextPart = nil; relatedFor = nil
        streamCache?.invalidate()
        streamCache = nil
        cancelSleepTimer()
        isFeedQueue = false
        isPresented = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    // MARK: - Internals

    @ObservationIgnored private var suppressRebuild = false
    private func withoutRebuild(_ body: () -> Void) { suppressRebuild = true; body(); suppressRebuild = false }

    private func buildOrder(startingWith start: Int, shuffled: Bool) {
        if shuffled {
            var rest = queue.indices.filter { $0 != start }
            rest.shuffle()
            order = [start] + rest
            position = 0
        } else {
            // Sequential: earlier items stay reachable with Previous.
            order = Array(queue.indices)
            position = start
        }
    }

    private func rebuildOrder(keepCurrent: Bool, forceShuffle: Bool = false) {
        guard !suppressRebuild, !queue.isEmpty else { return }
        let currentIndex = order.indices.contains(position) ? order[position] : 0
        if shuffle || forceShuffle {
            let played = keepCurrent ? Array(order[..<position]) : []
            var rest = Array(queue.indices).filter { $0 != currentIndex && !played.contains($0) }
            rest.shuffle()
            order = keepCurrent ? played + [currentIndex] + rest : [currentIndex] + rest
            position = keepCurrent ? played.count : 0
        } else {
            order = Array(queue.indices)
            position = currentIndex
        }
    }

    /// Same video, same position, new signed link.
    private func reloadWithFreshLink() {
        saveResume(force: true)
        loadCurrent(isRetry: true)
    }

    private func loadCurrent(isRetry: Bool = false) {
        guard let item = current, let url = library?.streamURL(for: item) else { return }
        linkCreated = Date()
        if !isRetry {
            retriedExpiredLink = false
            bypassCacheFor = nil
            PlayCountStore.increment(item.id)
        }
        errorMessage = nil
        currentTime = 0
        duration = ResumeStore.duration(for: item.id) ?? 0

        let asset = makeAsset(for: item, url: url)
        let playerItem = AVPlayerItem(asset: asset)
        // Stay up to a minute ahead so short drops in Wi-Fi/cellular speed don't stall playback.
        playerItem.preferredForwardBufferDuration = 60

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                             object: playerItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemDidFinish() }
        }
        itemStatusObservation = playerItem.observe(\.status, options: [.new]) { [weak self] it, _ in
            let status = it.status
            let message = it.error?.localizedDescription
            let seconds = CMTimeGetSeconds(it.duration)
            Task { @MainActor in
                guard let self else { return }
                if status == .failed, !self.retriedExpiredLink {
                    // Most often an expired or rejected link: try once more with a fresh one.
                    self.retriedExpiredLink = true
                    self.bypassCacheFor = item.id
                    self.reloadWithFreshLink()
                } else if status == .failed {
                    self.errorMessage = "Can't play this file. \(message ?? "") (MP4/MOV with H.264/HEVC work best.)"
                } else if status == .readyToPlay, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                    ResumeStore.setDuration(seconds, for: item.id)
                }
            }
        }

        seekTarget = nil
        seekGeneration += 1
        player.replaceCurrentItem(with: playerItem)
        if let resume = ResumeStore.position(for: item.id) { seek(to: resume) }
        player.playImmediately(atRate: rate)
        updateNowPlaying()
        loadArtwork(for: item)
        refreshRelated()
    }

    private func makeAsset(for item: VideoItem, url: URL) -> AVURLAsset {
        let enabled = UserDefaults.standard.object(forKey: "rewindCache") as? Bool ?? true
        let usable = enabled && !url.isFileURL
            && bypassCacheFor != item.id && !player.isExternalPlaybackActive   // AirPlay needs the real URL
        guard usable else {
            streamCache?.invalidate()
            streamCache = nil
            return AVURLAsset(url: url)
        }
        if let cache = streamCache, cache.itemID == item.id {
            cache.updateRemoteURL(url)        // same video, fresh link: keep what's cached
        } else {
            streamCache?.invalidate()         // new video: drop the old one's bytes
            streamCache = StreamCache(itemID: item.id, remoteURL: url)
        }
        let cache = streamCache!
        let asset = AVURLAsset(url: cache.assetURL)
        asset.resourceLoader.setDelegate(cache, queue: cache.queue)
        return asset
    }

    private func itemDidFinish() {
        if let item = current { ResumeStore.set(position: duration, duration: duration, for: item.id) }
        if sleepTimer == .endOfVideo { sleepTimerFired(); isPlaying = false; return }
        if autoplay, next() { return }
        isPlaying = false
    }

    private func tick(_ t: CMTime) {
        guard !isScrubbing, seekTarget == nil else { return }
        let s = CMTimeGetSeconds(t)
        if s.isFinite { currentTime = s }
        if let d = player.currentItem?.duration, CMTimeGetSeconds(d).isFinite, CMTimeGetSeconds(d) > 0 {
            duration = CMTimeGetSeconds(d)
        }
        saveResume()
    }

    private func saveResume(force: Bool = false) {
        guard let item = current, duration > 0 else { return }
        if !force, Date().timeIntervalSince(lastResumeSave) < 5 { return }
        lastResumeSave = Date()
        ResumeStore.set(position: currentTime, duration: duration, for: item.id)
    }

    // MARK: - Lock screen / Control Center

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }
        c.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.togglePlay() }; return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in _ = self?.next() }; return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }
        updateRemoteSkip()
        c.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skipForward() }; return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skipBackward() }; return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] e in
            guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            let t = e.positionTime
            Task { @MainActor in self?.seek(to: t) }
            return .success
        }
    }

    @ObservationIgnored private var artwork: MPMediaItemArtwork?

    private func updateNowPlaying() {
        guard let item = current else { return }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: sourceTitle.isEmpty ? item.folderDisplay : sourceTitle,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? Double(rate) : 0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
        ]
        if let artwork { info[MPMediaItemPropertyArtwork] = artwork }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    /// Nonisolated so the handler (called by MediaPlayer on a background queue) isn't main-actor bound.
    nonisolated private static func makeArtwork(_ img: UIImage) -> MPMediaItemArtwork {
        MPMediaItemArtwork(boundsSize: img.size) { _ in img }
    }

    private func loadArtwork(for item: VideoItem) {
        artwork = nil
        guard let img = ThumbnailService.shared.cached(item) else { return }
        artwork = Self.makeArtwork(img)
        updateNowPlaying()
    }
}
