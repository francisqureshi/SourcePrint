import Foundation

/// Identifies the output as it existed when a render completed.
public struct RenderOutputFingerprint: Codable, Equatable {
    public let size: Int64
    public let modifiedTime: TimeInterval
    public let fileNumber: UInt64

    public static func capture(at url: URL) -> RenderOutputFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date,
              let number = attributes[.systemFileNumber] as? NSNumber else { return nil }
        // Store subsecond precision independently of the project date encoder.
        return RenderOutputFingerprint(
            size: size.int64Value,
            modifiedTime: modified.timeIntervalSince1970,
            fileNumber: number.uint64Value
        )
    }
}
