import Foundation

public struct PublishRecord: Codable, Identifiable {
    public let id: UUID
    public let renderID: UUID
    public let sourceURL: URL
    public let destinationURL: URL
    public var date: Date
    public var state: String
    public var outputFingerprint: RenderOutputFingerprint?
    public var message: String?

    public init(render: PrintRecord, destinationURL: URL) {
        id = UUID()
        renderID = render.id
        sourceURL = render.outputURL
        self.destinationURL = destinationURL
        date = Date()
        state = "pending"
    }
}

public struct PublishItem: Identifiable {
    public var id: UUID { render.id }
    public let render: PrintRecord
    public let destination: URL
    public let previousDestination: RenderOutputFingerprint?

    public init(render: PrintRecord, destination: URL, previousDestination: RenderOutputFingerprint?) {
        self.render = render
        self.destination = destination
        self.previousDestination = previousDestination
    }
}

public enum PublishService {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        public init(_ message: String) { errorDescription = message }
    }

    public static func prepare(_ renders: [PrintRecord], directory: URL, protectedURLs: [URL]) throws -> [PublishItem] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw Failure("Choose an available Publish Folder in Overview.")
        }
        let protected = Set(protectedURLs.map { $0.resolvingSymlinksInPath().path.lowercased() })
        var destinations = Set<String>()
        return try renders.map { render in
            let target = directory.appendingPathComponent(render.outputURL.lastPathComponent)
            let path = target.resolvingSymlinksInPath().path.lowercased()
            guard path != render.outputURL.resolvingSymlinksInPath().path.lowercased(), !protected.contains(path) else {
                throw Failure("The publish destination for \(render.ocfFileName) conflicts with a source or output file.")
            }
            guard destinations.insert(path).inserted else {
                throw Failure("Multiple jobs would publish to \(target.lastPathComponent). Publish these jobs to separate folders.")
            }
            guard render.success, let saved = render.outputFingerprint,
                  RenderOutputFingerprint.capture(at: render.outputURL) == saved else {
                throw Failure("\(render.ocfFileName) has no verified output available. Render it again before publishing.")
            }
            let previous = RenderOutputFingerprint.capture(at: target)
            if fm.fileExists(atPath: target.path) {
                let values = try target.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true, previous != nil else {
                    throw Failure("The destination for \(render.ocfFileName) is not a regular writable file.")
                }
            }
            return PublishItem(render: render, destination: target, previousDestination: previous)
        }
    }

    /// Install on the destination volume first. The caller saves the successful
    /// publish event before deleting the original output.
    public static func install(_ item: PublishItem) throws -> RenderOutputFingerprint {
        let fm = FileManager.default
        guard let saved = item.render.outputFingerprint,
              RenderOutputFingerprint.capture(at: item.render.outputURL) == saved else {
            throw Failure("The rendered output changed after review.")
        }
        let staging = item.destination.deletingLastPathComponent()
            .appendingPathComponent(".sourceprint-publish-\(UUID().uuidString).mov")
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: item.render.outputURL, to: staging)
        guard RenderOutputFingerprint.capture(at: item.render.outputURL) == saved,
              RenderOutputFingerprint.capture(at: staging)?.size == saved.size else {
            throw Failure("The output changed while it was being copied.")
        }
        guard RenderOutputFingerprint.capture(at: item.destination) == item.previousDestination else {
            throw Failure("The publish destination changed after review. Review it again.")
        }
        if item.previousDestination != nil {
            _ = try fm.replaceItemAt(item.destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: item.destination)
        }
        guard let published = RenderOutputFingerprint.capture(at: item.destination) else {
            throw Failure("Could not verify the published output.")
        }
        return published
    }

    public static func removeOriginal(_ item: PublishItem) throws {
        guard RenderOutputFingerprint.capture(at: item.render.outputURL) == item.render.outputFingerprint else {
            throw Failure("Published successfully. The original changed and was retained in Output.")
        }
        try FileManager.default.removeItem(at: item.render.outputURL)
    }
}
