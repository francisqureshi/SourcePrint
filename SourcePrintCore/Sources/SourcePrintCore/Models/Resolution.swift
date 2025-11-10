import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Cross-platform resolution representation (replaces CGSize)
/// Provides compatibility with CoreGraphics.CGSize on Apple platforms
public struct Resolution: Equatable, Hashable {
    public let width: Double
    public let height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }

    /// Create from integer dimensions
    public init(width: Int, height: Int) {
        self.width = Double(width)
        self.height = Double(height)
    }

    #if canImport(CoreGraphics)
    /// Create from CGSize (Apple platforms only)
    public init(_ cgSize: CGSize) {
        self.width = Double(cgSize.width)
        self.height = Double(cgSize.height)
    }

    /// Convert to CGSize (Apple platforms only)
    public var cgSize: CGSize {
        CGSize(width: width, height: height)
    }
    #endif

    /// Common resolutions for convenience
    public static let hd720 = Resolution(width: 1280, height: 720)
    public static let hd1080 = Resolution(width: 1920, height: 1080)
    public static let uhd4k = Resolution(width: 3840, height: 2160)
    public static let dci4k = Resolution(width: 4096, height: 2160)

    /// Aspect ratio as a decimal
    public var aspectRatio: Double {
        guard height > 0 else { return 0 }
        return width / height
    }

    /// Common aspect ratio string (e.g., "16:9", "4:3")
    public var aspectRatioString: String {
        let ratio = aspectRatio
        if abs(ratio - 16.0/9.0) < 0.01 { return "16:9" }
        if abs(ratio - 4.0/3.0) < 0.01 { return "4:3" }
        if abs(ratio - 21.0/9.0) < 0.01 { return "21:9" }
        if abs(ratio - 1.0) < 0.01 { return "1:1" }
        return String(format: "%.2f:1", ratio)
    }
}

// MARK: - CustomStringConvertible

extension Resolution: CustomStringConvertible {
    public var description: String {
        "\(Int(width))×\(Int(height))"
    }
}

// MARK: - Codable (with backward compatibility)

extension Resolution: Codable {
    public init(from decoder: Decoder) throws {
        // Try array format first (old .w2 files: [1920, 1080])
        if let container = try? decoder.singleValueContainer(),
           let array = try? container.decode([Double].self),
           array.count == 2 {
            self.width = array[0]
            self.height = array[1]
            return
        }

        // Fall back to dictionary format (new .w2 files: {width: 1920, height: 1080})
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.width = try container.decode(Double.self, forKey: .width)
        self.height = try container.decode(Double.self, forKey: .height)
    }

    public func encode(to encoder: Encoder) throws {
        // Always encode as dictionary (new format)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(width, forKey: .width)
        try container.encode(height, forKey: .height)
    }

    private enum CodingKeys: String, CodingKey {
        case width
        case height
    }
}
