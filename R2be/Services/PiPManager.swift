import AVKit
import Observation
import UIKit

/// Picture in Picture for the shared player. Every on-screen video surface (full player, mini
/// player, Feed) registers its AVPlayerLayer; the most recent one that's in a window is the PiP
/// source. PiP starts from the player's PiP button, or automatically when the app goes to the
/// background while a video is playing. The PiP window itself is the system's: drag it anywhere,
/// pinch to resize, or push it to the screen edge to tuck it away.
@Observable
final class PiPManager: NSObject, AVPictureInPictureControllerDelegate {
    private(set) var isActive = false
    private(set) var isPossible = false

    static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Called on the main thread. Starting PiP closes the full-screen player so you can use the
    /// app underneath; tapping "back to app" in the PiP window reopens it.
    @ObservationIgnored var onWillStart: (@MainActor () -> Void)?
    @ObservationIgnored var onRestore: (@MainActor () -> Void)?

    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private weak var sourceLayer: AVPlayerLayer?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?
    @ObservationIgnored private var candidates: [WeakLayer] = []

    private struct WeakLayer { weak var layer: AVPlayerLayer? }

    // MARK: Surfaces

    func register(_ layer: AVPlayerLayer) {
        candidates.removeAll { $0.layer == nil || $0.layer === layer }
        candidates.append(WeakLayer(layer: layer))
        if !isActive { attach(layer) }
    }

    func unregister(_ layer: AVPlayerLayer) {
        candidates.removeAll { $0.layer == nil || $0.layer === layer }
        guard layer === sourceLayer, !isActive else { return }
        if let next = candidates.last(where: { Self.isOnScreen($0.layer) })?.layer { attach(next) } else { detach() }
    }

    private func attach(_ layer: AVPlayerLayer) {
        guard Self.isSupported, layer !== sourceLayer,
              let c = AVPictureInPictureController(playerLayer: layer) else { return }
        sourceLayer = layer
        c.delegate = self
        c.canStartPictureInPictureAutomaticallyFromInline = true
        controller = c
        possibleObservation = c.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { [weak self] c, _ in
            let possible = c.isPictureInPicturePossible
            DispatchQueue.main.async { self?.isPossible = possible }
        }
    }

    private func detach() {
        possibleObservation = nil
        controller = nil
        sourceLayer = nil
        isPossible = false
    }

    private static func isOnScreen(_ layer: AVPlayerLayer?) -> Bool {
        (layer?.delegate as? UIView)?.window != nil
    }

    // MARK: Control

    func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive { controller.stopPictureInPicture() } else { controller.startPictureInPicture() }
    }

    // MARK: AVPictureInPictureControllerDelegate (always called on the main thread)

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        MainActor.assumeIsolated { onWillStart?() }
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        // The surface PiP started from may be gone (full player closed); move to one that's showing.
        if !Self.isOnScreen(sourceLayer) {
            if let next = candidates.last(where: { Self.isOnScreen($0.layer) })?.layer { attach(next) } else { detach() }
        }
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    failedToStartPictureInPictureWithError error: Error) {
        isActive = false
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        MainActor.assumeIsolated { onRestore?() }
        completionHandler(true)
    }
}
