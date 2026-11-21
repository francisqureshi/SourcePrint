import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Identifies the output as it existed when a render completed.
public struct RenderOutputFingerprint: Codable, Equatable {
    public let size: Int64
    public let modifiedTime: TimeInterval
    public let fileNumber: UInt64

    public static func capture(at url: URL) -> RenderOutputFingerprint? {
        try? fileSnapshot(at: url).fingerprint
    }

    // FileManager.attributesOfItem also reads extended attributes on macOS. Those
    // can block on provenance checks even when ordinary media reads are available.
    // stat supplies exactly the filesystem fields needed by render validation.
    static func fileSnapshot(at url: URL) throws -> (fingerprint: RenderOutputFingerprint, device: UInt64) {
        var info = stat()
        guard url.withUnsafeFileSystemRepresentation({ path in
            guard let path else { return false }
            return stat(path, &info) == 0
        }) else {
            let code: CocoaError.Code
            switch errno {
            case ENOENT, ENOTDIR: code = .fileReadNoSuchFile
            case EACCES, EPERM: code = .fileReadNoPermission
            default: code = .fileReadUnknown
            }
            throw CocoaError(code, userInfo: [NSFilePathErrorKey: url.path])
        }
        #if canImport(Darwin)
        let modified = info.st_mtimespec
        #else
        let modified = info.st_mtim
        #endif
        return (RenderOutputFingerprint(size: Int64(info.st_size),
            modifiedTime: Double(modified.tv_sec) + Double(modified.tv_nsec) / 1_000_000_000,
            fileNumber: UInt64(info.st_ino)), UInt64(info.st_dev))
    }
}
