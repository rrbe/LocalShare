import Foundation
import ImageIO
import AVFoundation
import UniformTypeIdentifiers

// Per-server, memory-only thumbnails. Socket threads wait here; decoding never runs on MainActor.
final class ThumbnailStore {
    static let pixelSize = 512
    private struct Key: Hashable {
        let path: String
        let modified: Date
        let size: UInt64
        let inode: UInt64
        let generation: Int
    }
    private final class Cached: NSObject {
        let data: Data?
        init(_ data: Data?) { self.data = data }
    }
    private let condition = NSCondition()
    private let slots = DispatchSemaphore(value: 2)
    private let cache = NSCache<NSString, Cached>()
    private var pending = Set<Key>()
    private var revision = 0

    private let generator: (URL) -> Data?

    init(generator: @escaping (URL) -> Data? = ThumbnailStore.generate) {
        self.generator = generator
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 512
    }

    var generation: Int {
        condition.lock(); defer { condition.unlock() }
        return revision
    }

    func clear() {
        condition.lock()
        revision += 1
        cache.removeAllObjects()
        condition.broadcast()
        condition.unlock()
    }

    func thumbnail(for url: URL, generation: Int) -> Data? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              attrs[.type] as? FileAttributeType == .typeRegular,
              let modified = attrs[.modificationDate] as? Date,
              let size = attrs[.size] as? NSNumber,
              let inode = attrs[.systemFileNumber] as? NSNumber else { return nil }
        let key = Key(path: url.path, modified: modified, size: size.uint64Value,
                      inode: inode.uint64Value, generation: generation)
        // JSON avoids ambiguous separators in user-controlled filenames.
        let cacheKey = String(data: try! JSONEncoder().encode([
            key.path, String(modified.timeIntervalSince1970), String(key.size), String(key.inode), String(generation)
        ]), encoding: .utf8)! as NSString
        condition.lock()
        while revision == generation && pending.contains(key) { condition.wait() }
        guard revision == generation else { condition.unlock(); return nil }
        if let cached = cache.object(forKey: cacheKey) { condition.unlock(); return cached.data }
        pending.insert(key)
        condition.unlock()

        slots.wait()
        let data: Data? = autoreleasepool {
            guard self.generation == generation else { return nil }
            return generator(url)
        }
        slots.signal()

        condition.lock()
        defer { pending.remove(key); condition.broadcast(); condition.unlock() }
        guard revision == generation else { return nil }
        cache.setObject(Cached(data), forKey: cacheKey, cost: data?.count ?? 1)
        return data
    }

    static func generate(_ url: URL) -> Data? {
        let category = FileType.category(of: url, isDir: false)
        let image: CGImage?
        switch category {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
            image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixelSize,
                kCGImageSourceShouldCacheImmediately: true
            ] as CFDictionary)
        case .video:
            image = videoFrame(url)
        default:
            return nil
        }
        guard let image else { return nil }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return result as Data
    }

    private static func videoFrame(_ url: URL) -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.maximumSize = CGSize(width: pixelSize, height: pixelSize)
        generator.appliesPreferredTrackTransform = true
        let result = FrameResult()
        generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0.1, preferredTimescale: 600))]) { _, image, _, status, _ in
            result.lock.lock()
            if status == .succeeded { result.image = image }
            result.lock.unlock()
            result.done.signal()
        }
        // A damaged or slow media asset must not occupy a decoder slot indefinitely.
        guard result.done.wait(timeout: .now() + 10) == .success else {
            generator.cancelAllCGImageGeneration()
            return nil
        }
        result.lock.lock(); defer { result.lock.unlock() }
        return result.image
    }

    private final class FrameResult {
        let lock = NSLock()
        let done = DispatchSemaphore(value: 0)
        var image: CGImage?
    }
}
