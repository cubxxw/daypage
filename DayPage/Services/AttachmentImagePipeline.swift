import UIKit
import ImageIO
import DayPageStorage

/// Bounded, process-wide image pipeline for attachment presentation.
///
/// Original files remain untouched in the Vault.  UI surfaces receive a
/// display-sized decode, avoiding the hundreds-of-megabytes-per-photo cost of
/// `Data(contentsOf:) + UIImage(data:)`.  `NSCache` is thread-safe, costed by
/// decoded bytes, and purged immediately on a memory warning.
final class AttachmentImagePipeline: @unchecked Sendable {
    static let shared = AttachmentImagePipeline()

    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 24
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    private var memoryWarningToken: NSObjectProtocol?

    private init() {
        memoryWarningToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.removeAllImages()
            SentryReporter.breadcrumb(
                category: "memo-detail.media",
                level: .warning,
                message: "attachment image cache purged after memory warning"
            )
        }
    }

    deinit {
        if let memoryWarningToken {
            NotificationCenter.default.removeObserver(memoryWarningToken)
        }
    }

    func image(at url: URL, maxPixelSize: Int) async -> UIImage? {
        let boundedPixelSize = min(4_096, max(1, maxPixelSize))
        let key = "\(url.standardizedFileURL.path)#\(boundedPixelSize)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard !Task.isCancelled else { return nil }

        let image: UIImage? = autoreleasepool {
            guard let source = CGImageSourceCreateWithURL(
                url as CFURL,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: boundedPixelSize,
            ]
            guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(
                source, 0, options as CFDictionary
            ) else { return nil }
            return UIImage(cgImage: thumbnail)
        }

        guard !Task.isCancelled, let image else { return nil }
        cache.setObject(image, forKey: key, cost: decodedCost(of: image))
        return image
    }

    func removeAllImages() {
        cache.removeAllObjects()
    }

    private func decodedCost(of image: UIImage) -> Int {
        guard let cgImage = image.cgImage else { return 0 }
        let (cost, overflow) = cgImage.bytesPerRow.multipliedReportingOverflow(by: cgImage.height)
        return overflow ? 0 : cost
    }
}
