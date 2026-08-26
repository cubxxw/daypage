import Foundation
import ImageIO
import DayPageModels

struct PhotoMetadata: Equatable, Sendable {
    struct Row: Identifiable, Equatable, Sendable {
        let label: String
        let value: String
        var id: String { label }
    }

    let focalLength: String?
    let aperture: String?
    let shutter: String?
    let iso: Int?
    let pixelWidth: Int?
    let pixelHeight: Int?

    var overlayText: String? {
        let parts = [focalLength, aperture, shutter].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    var rows: [Row] {
        var result: [Row] = []
        if let aperture { result.append(Row(label: "Aperture", value: aperture)) }
        if let shutter { result.append(Row(label: "Shutter", value: shutter)) }
        if let iso { result.append(Row(label: "ISO", value: "\(iso)")) }
        if let focalLength { result.append(Row(label: "Focal Length", value: focalLength)) }
        if let pixelWidth, let pixelHeight {
            result.append(Row(label: "Dimensions", value: "\(pixelWidth) × \(pixelHeight)"))
        }
        return result
    }
}

/// One metadata reader for cards, detail, capture, and sharing.  Metadata is
/// parsed without decoding image pixels, and every floating-point conversion
/// goes through the same non-trapping formatter.
enum PhotoMetadataService {

    static func metadata(at url: URL) async -> PhotoMetadata? {
        guard !Task.isCancelled else { return nil }
        let metadata = autoreleasepool { metadataSync(at: url) }
        guard !Task.isCancelled else { return nil }
        return metadata
    }

    static func metadataSync(at url: URL) -> PhotoMetadata? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        else { return nil }

        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let focal = number(in: exif, key: kCGImagePropertyExifFocalLength as String)
            .flatMap(MemoExifFormat.focalLengthLabel)
        let aperture = number(in: exif, key: kCGImagePropertyExifFNumber as String)
            .flatMap(MemoExifFormat.apertureLabel)
        let shutter = number(in: exif, key: kCGImagePropertyExifExposureTime as String)
            .flatMap(MemoExifFormat.shutterLabel)

        let iso: Int? = {
            guard let value = exif?[kCGImagePropertyExifISOSpeedRatings as String] else { return nil }
            if let values = value as? [Int] { return values.first }
            if let values = value as? [NSNumber] { return values.first?.intValue }
            return nil
        }()

        return PhotoMetadata(
            focalLength: focal,
            aperture: aperture,
            shutter: shutter,
            iso: iso,
            pixelWidth: integer(in: properties, key: kCGImagePropertyPixelWidth as String),
            pixelHeight: integer(in: properties, key: kCGImagePropertyPixelHeight as String)
        )
    }

    private static func number(in dictionary: [String: Any]?, key: String) -> Double? {
        guard let value = dictionary?[key] else { return nil }
        if let value = value as? Double { return value }
        if let value = value as? NSNumber { return value.doubleValue }
        return nil
    }

    private static func integer(in dictionary: [String: Any], key: String) -> Int? {
        guard let value = dictionary[key] else { return nil }
        if let value = value as? Int { return value > 0 ? value : nil }
        if let value = value as? NSNumber {
            let integer = value.intValue
            return integer > 0 ? integer : nil
        }
        return nil
    }
}

/// Non-trapping formatting contract kept as a small namespace so capture,
/// card, detail, sharing, and tests cannot drift into separate EXIF rules.
enum MemoExifFormat {
    static func shutterLabel(exposureTime: Double) -> String? {
        guard exposureTime > 0, exposureTime.isFinite else { return nil }
        if exposureTime < 1 {
            guard let denominator = MemoPresentationSafety.roundedInt(1 / exposureTime),
                  denominator > 1 else { return nil }
            return "1/\(denominator)s"
        }
        guard let seconds = MemoPresentationSafety.roundedInt(exposureTime),
              seconds > 0 else { return nil }
        return "\(seconds)s"
    }

    static func focalLengthLabel(_ focalLength: Double) -> String? {
        guard focalLength > 0,
              let value = MemoPresentationSafety.roundedInt(focalLength) else { return nil }
        return "\(value)mm"
    }

    static func apertureLabel(_ fNumber: Double) -> String? {
        guard fNumber > 0, fNumber.isFinite else { return nil }
        return String(format: "f/%.1f", fNumber)
    }
}
