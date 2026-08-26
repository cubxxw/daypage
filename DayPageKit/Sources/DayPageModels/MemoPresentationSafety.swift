import Foundation

/// Values read from the Markdown Vault are user-editable and may also arrive
/// from import or sync.  This namespace is the single boundary between those
/// permissive persistence values and APIs that require finite, bounded input.
/// It never rewrites the Vault; callers either render a validated value or
/// degrade by omitting the invalid field.
public enum MemoPresentationSafety {

    /// Converts an already-rounded floating-point value without trapping.
    /// `Int(exactly:)` is important here: `isFinite` alone is insufficient for
    /// values such as `1e300`, which are finite but outside `Int`'s range.
    public static func roundedInt(_ value: Double) -> Int? {
        guard value.isFinite else { return nil }
        return Int(exactly: value.rounded())
    }

    /// A duration suitable for playback and formatting.
    public static func duration(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// A coordinate suitable for MapKit and URL construction.
    public static func coordinate(latitude: Double?, longitude: Double?) -> MemoCoordinate? {
        guard let latitude,
              let longitude,
              latitude.isFinite,
              longitude.isFinite,
              (-90.0 ... 90.0).contains(latitude),
              (-180.0 ... 180.0).contains(longitude)
        else { return nil }
        return MemoCoordinate(latitude: latitude, longitude: longitude)
    }

    /// Accept only Vault-relative attachment paths.  Missing files are still a
    /// recoverable presentation state, but absolute paths and traversal are not
    /// allowed to escape the Vault root.
    public static func relativeAttachmentPath(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.hasPrefix("\\"),
              !trimmed.contains("\0")
        else { return nil }

        let components = trimmed
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { return nil }
        return components.joined(separator: "/")
    }
}

public struct MemoCoordinate: Equatable, Sendable {
    public let latitude: Double
    public let longitude: Double

    public init(latitude: Double, longitude: Double) {
        self.latitude = latitude
        self.longitude = longitude
    }
}

public extension Memo.Location {
    var presentationCoordinate: MemoCoordinate? {
        MemoPresentationSafety.coordinate(latitude: lat, longitude: lng)
    }
}

public extension Memo.Attachment {
    var presentationDuration: Double? {
        MemoPresentationSafety.duration(duration)
    }

    var presentationFile: String? {
        MemoPresentationSafety.relativeAttachmentPath(file)
    }
}
