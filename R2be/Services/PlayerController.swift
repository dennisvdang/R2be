import AVFoundation
import MediaPlayer
import Observation
import SwiftUI // Array.remove(atOffsets:)
import UIKit

/// Where the current queue came from. The Feed tab only drives the player while context == .feed.
enum PlaybackContext: Equatable {
    case none
    case folder(String)
    case playlist(UUID)
    case search
    case feed
    case selection
}

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
    private(set) var context: PlaybackContext = .none
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

    /// True once the current link is within 5 minutes of expiring (e.g. paused overnight).
    private var linkIsStale: Bool {
        let lifetime = library?.streamLinkLifetime ?? 6 * 3600
        return Date().timeIntervalSince(linkCreated) > lifetime - 300
    }

    static let skipInterval: Double = 30

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
    }

    // MARK: - Derived

    var current: VideoItem? {
        guard order.indices.contains(position), queue.indices.contains(order[position]) else { return nil }
        return queue[order[position]]
    }
    /// Positions in `order` that will play after the current one, in play order. With loop on this
    /// wraps around, so starting on the last video still lists everything before it.
    private var upNextPositions: [Int] {
        guard order.indices.contains(position) else { return [] }
        let after = Array((position + 1)..<order.count)
        return loopQueue ? after + Array(0..<position) : after
    }
    var upNext: [VideoItem] { upNextPositions.map { queue[order[$0]] } }
    var hasNext: Bool { position + 1 < order.count || (loopQueue && !order.isEmpty) }
    var hasPrevious: Bool { position > 0 || currentTime > 5 }

    // MARK: - Starting playback

    /// Replace the queue and start playing. `start == nil` + shuffle starts at a random video.
    func play(_ items: [VideoItem], startAt start: VideoItem? = nil, shuffle shuffleOverride: Bool? = nil,
              context: PlaybackContext, title: String, present: Bool = true, keepGivenOrder: Bool = false) {
        guard !items.isEmpty else { return }
        queue = items
        self.context = context
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
    func shufflePlay(_ items: [VideoItem], context: PlaybackContext, title: String) {
        play(items, startAt: nil, shuffle: true, context: context, title: title)
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
        guard !queue.isEmpty else { play([item], context: .selection, title: "Queue"); return }
        guard item != current else { return }
        let qi = queueIndex(for: item)
        if let existing = order.firstIndex(of: qi) {
            order.remove(at: existing)
            if existing < position { position -= 1 }
        }
        order.insert(qi, at: min(position + 1, order.count))
    }

    func addToQueue(_ items: [VideoItem]) {
        guard !queue.isEmpty else { play(items, context: .selection, title: "Queue"); return }
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

    func removeFromUpNext(at offsets: IndexSet) {
        let positions = upNextPositions
        let absolute = IndexSet(offsets.compactMap { positions.indices.contains($0) ? positions[$0] : nil })
        position -= absolute.count(in: 0..<position)
        order.remove(atOffsets: absolute)
    }

    func reshuffle() {
        guard !order.isEmpty else { return }
        rebuildOrder(keepCurrent: true, forceShuffle: true)
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

    func skip(_ seconds: Double) {
        let target = currentTime + seconds
        if duration > 0, target >= duration { seek(to: max(duration - 0.5, 0)); return }
        seek(to: max(target, 0))
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in self?.updateNowPlaying() }
        }
    }

    @discardableResult
    func next() -> Bool {
        saveResume(force: true)
        if position + 1 < order.count {
            position += 1
        } else if loopQueue, !order.isEmpty {
            // Keep the same order so what plays matches what Up Next showed. Reshuffle is in Up Next.
            position = 0
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
        cancelSleepTimer()
        context = .none
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
        if !isRetry { retriedExpiredLink = false }
        errorMessage = nil
        currentTime = 0
        duration = ResumeStore.duration(for: item.id) ?? 0

        let asset = AVURLAsset(url: url)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 10

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
                    self.reloadWithFreshLink()
                } else if status == .failed {
                    self.errorMessage = "Can't play this file. \(message ?? "") (MP4/MOV with H.264/HEVC work best.)"
                } else if status == .readyToPlay, seconds.isFinite, seconds > 0 {
                    self.duration = seconds
                    ResumeStore.setDuration(seconds, for: item.id)
                }
            }
        }

        player.replaceCurrentItem(with: playerItem)
        if let resume = ResumeStore.position(for: item.id) {
            player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            currentTime = resume
        }
        player.playImmediately(atRate: rate)
        updateNowPlaying()
        loadArtwork(for: item)
    }

    private func itemDidFinish() {
        if let item = current { ResumeStore.set(position: duration, duration: duration, for: item.id) }
        if sleepTimer == .endOfVideo { sleepTimerFired(); isPlaying = false; return }
        if autoplay, next() { return }
        isPlaying = false
    }

    private func tick(_ t: CMTime) {
        guard !isScrubbing else { return }
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
        c.skipForwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        c.skipBackwardCommand.preferredIntervals = [NSNumber(value: Self.skipInterval)]
        c.skipForwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(PlayerController.skipInterval) }; return .success }
        c.skipBackwardCommand.addTarget { [weak self] _ in Task { @MainActor in self?.skip(-PlayerController.skipInterval) }; return .success }
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
