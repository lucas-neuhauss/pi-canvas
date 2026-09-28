import Foundation
import CoreGraphics
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

/// Content-addressed storage for the files nodes own — today, images dropped on
/// the canvas.
///
/// Assets live outside the workspace files so the layouts stay small and
/// readable, and they are named by SHA-256 so dropping the same image twice
/// stores one copy. A node stores only the file name, so the store can move
/// with the user's home directory without breaking a canvas.
final class AssetStore {

    let directory: URL

    static var defaultDirectory: URL {
        LayoutStore.defaultDirectory.appendingPathComponent("assets", isDirectory: true)
    }

    init(directory: URL? = nil) {
        let directory = directory ?? AssetStore.defaultDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory
    }

    enum StoreError: LocalizedError {
        case notAnImage(URL)
        case unreadable(URL)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notAnImage(let url):
                return "\(url.lastPathComponent) is not an image"
            case .unreadable(let url):
                return "\(url.lastPathComponent) could not be read"
            case .writeFailed(let reason):
                return "could not save the asset: \(reason)"
            }
        }
    }

    // MARK: - Storing

    /// Copies the bytes of `sourceURL` into the store and returns the stored
    /// file name (`<sha256>.<ext>`). Storing the same bytes twice writes once.
    @discardableResult
    func store(contentsOf sourceURL: URL) throws -> String {
        let data: Data
        do {
            data = try Data(contentsOf: sourceURL)
        } catch {
            throw StoreError.unreadable(sourceURL)
        }
        guard let fileExtension = AssetStore.imageFileExtension(of: sourceURL) else {
            throw StoreError.notAnImage(sourceURL)
        }
        return try store(data: data, fileExtension: fileExtension)
    }

    /// Stores raw bytes under their SHA-256 name, deduplicated by hash.
    @discardableResult
    func store(data: Data, fileExtension: String) throws -> String {
        let name = AssetStore.fileName(for: data, fileExtension: fileExtension)
        let destination = url(for: name)
        guard !FileManager.default.fileExists(atPath: destination.path) else { return name }
        do {
            try data.write(to: destination, options: .atomic)
        } catch {
            throw StoreError.writeFailed(error.localizedDescription)
        }
        return name
    }

    // MARK: - Access

    func url(for name: String) -> URL {
        directory.appendingPathComponent(name)
    }

    func remove(_ name: String) {
        try? FileManager.default.removeItem(at: url(for: name))
    }

    /// Drops assets no node references any more, so closing an image node (and
    /// deleting its top-level cache) does not leave the bytes forever.
    func prune(keeping names: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        for name in files where !names.contains(name) {
            try? FileManager.default.removeItem(at: url(for: name))
        }
    }

    // MARK: - Names and image inspection

    /// The content-addressed name for some bytes: the SHA-256 hex digest plus
    /// the source extension.
    static func fileName(for data: Data, fileExtension: String) -> String {
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let fileExtension = fileExtension.lowercased()
        return fileExtension.isEmpty ? hex : "\(hex).\(fileExtension)"
    }

    /// The lowercased file extension when the URL names an image, else nil.
    /// UTType rather than a hard-coded list, so HEIC and friends work too.
    static func imageFileExtension(of url: URL) -> String? {
        let fileExtension = url.pathExtension.lowercased()
        guard !fileExtension.isEmpty,
              let type = UTType(filenameExtension: fileExtension),
              type.conforms(to: .image) else { return nil }
        return fileExtension
    }

    /// Pixel dimensions of an image, without decoding it. Nil when the file is
    /// not a readable image.
    static func pixelSize(ofImageAt url: URL) -> CGSize? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue,
              width > 0, height > 0 else { return nil }
        return CGSize(width: width, height: height)
    }
}
