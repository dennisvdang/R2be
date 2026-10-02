import CryptoKit
import Foundation
import Observation
import UIKit

/// Custom folder cover images picked from the photo library. Stored on the phone only
/// (Application Support/FolderCovers), keyed by bucket + folder prefix; nothing goes to R2.
@Observable
@MainActor
final class FolderCoverStore {
    struct Target: Hashable {
        let bucket: String
        let prefix: String
    }

    /// Set by a folder's "Set Cover Image" menu item; RootView shows the photo picker for it.
    var pickerTarget: Target?
    var isPickerPresented = false

    /// Bumped on every change so views showing covers redraw.
    private(set) var revision = 0
    @ObservationIgnored private var cache: [Target: UIImage] = [:]
    @ObservationIgnored private var missing: Set<Target> = []

    func requestPicker(bucket: String, prefix: String) {
        pickerTarget = Target(bucket: bucket, prefix: prefix)
        isPickerPresented = true
    }

    func image(bucket: String, prefix: String) -> UIImage? {
        _ = revision
        let t = Target(bucket: bucket, prefix: prefix)
        if let img = cache[t] { return img }
        if missing.contains(t) { return nil }
        if let data = try? Data(contentsOf: Self.fileURL(for: t)), let img = UIImage(data: data) {
            cache[t] = img
            return img
        }
        missing.insert(t)
        return nil
    }

    func hasCover(bucket: String, prefix: String) -> Bool { image(bucket: bucket, prefix: prefix) != nil }

    /// Saves a downscaled JPEG of the picked photo as the folder's cover.
    func setCover(_ data: Data, for t: Target) {
        guard let original = UIImage(data: data) else { return }
        let img = Self.downscaled(original, maxSide: 1000)
        guard let jpeg = img.jpegData(compressionQuality: 0.85) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? jpeg.write(to: Self.fileURL(for: t), options: .atomic)
        cache[t] = img
        missing.remove(t)
        revision += 1
    }

    func removeCover(bucket: String, prefix: String) {
        let t = Target(bucket: bucket, prefix: prefix)
        try? FileManager.default.removeItem(at: Self.fileURL(for: t))
        cache[t] = nil
        missing.insert(t)
        revision += 1
    }

    // MARK: Files

    private static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FolderCovers", isDirectory: true)
    }

    private static func fileURL(for t: Target) -> URL {
        let digest = SHA256.hash(data: Data((t.bucket + "/" + t.prefix).utf8))
        let name = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(name + ".jpg")
    }

    private static func downscaled(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxSide else { return image }
        let scale = maxSide / longest
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
