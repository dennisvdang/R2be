import Foundation
import Observation

/// Remembers playback position and duration per video so you can pick up where you left off.
@MainActor
enum ResumeStore {
    private static let key = "resumePositions.v1"
    private static let durKey = "durations.v1"
    private static var positions: [String: Double] = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
    private static var durations: [String: Double] = UserDefaults.standard.dictionary(forKey: durKey) as? [String: Double] ?? [:]
    private static var pendingSave = false

    /// Bumped whenever progress is saved or cleared. Reading it in the getters below makes any view
    /// that shows a duration or progress bar redraw when they change.
    @Observable final class Changes { var count = 0 }
    private static let changes = Changes()

    static func position(for id: String) -> Double? { positions[id] }
    static func duration(for id: String) -> Double? { _ = changes.count; return durations[id] }

    /// Fraction watched, for the red progress bar under thumbnails.
    static func progress(for id: String) -> Double? {
        _ = changes.count
        guard let p = positions[id], let d = durations[id], d > 0 else { return nil }
        return min(max(p / d, 0), 1)
    }

    static func set(position: Double, duration: Double, for id: String) {
        guard duration.isFinite, duration > 0 else { return }
        durations[id] = duration
        // Treat the last 15 s as "finished" so the next play starts at the beginning.
        if position < 5 || position > duration - 15 { positions[id] = nil } else { positions[id] = position }
        scheduleSave()
    }

    static func setDuration(_ duration: Double, for id: String) {
        guard duration.isFinite, duration > 0, durations[id] != duration else { return }
        durations[id] = duration
        scheduleSave()
    }

    static func clearAll() {
        positions = [:]
        UserDefaults.standard.removeObject(forKey: key)
        changes.count += 1
    }

    private static func scheduleSave() {
        guard !pendingSave else { return }
        pendingSave = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            MainActor.assumeIsolated {
                UserDefaults.standard.set(positions, forKey: key)
                UserDefaults.standard.set(durations, forKey: durKey)
                pendingSave = false
                changes.count += 1
            }
        }
    }
}
