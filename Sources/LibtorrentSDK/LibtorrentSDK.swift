import Foundation

public enum LibtorrentRuntimeError: Error, LocalizedError, Sendable {
    case frameworkUnavailable
    case missingNativeSymbol(String)
    case nativeCallFailed(operation: String, code: Int32, message: String?)
    case invalidNativeEvent(String)

    public var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            "The libtorrent XCFramework is not linked into this iOS build."
        case let .missingNativeSymbol(symbol):
            "The libtorrent native framework is missing required symbol '\(symbol)'."
        case let .nativeCallFailed(operation, code, message):
            if let message, !message.isEmpty {
                "The libtorrent native call '\(operation)' failed with code \(code): \(message)"
            } else {
                "The libtorrent native call '\(operation)' failed with code \(code)."
            }
        case let .invalidNativeEvent(reason):
            "The libtorrent native framework emitted an invalid event: \(reason)"
        }
    }
}

public struct LibtorrentJobInput: Sendable, Equatable, Codable {
    public let jobId: UUID
    public let magnetUri: String?
    public let torrentData: Data?
    public let torrentFileName: String?
    public let downloadDirectory: URL
    public let rateLimits: LibtorrentRateLimits?

    public init(
        jobId: UUID,
        magnetUri: String? = nil,
        torrentData: Data? = nil,
        torrentFileName: String? = nil,
        downloadDirectory: URL,
        rateLimits: LibtorrentRateLimits? = nil
    ) {
        self.jobId = jobId
        self.magnetUri = magnetUri
        self.torrentData = torrentData
        self.torrentFileName = torrentFileName
        self.downloadDirectory = downloadDirectory
        self.rateLimits = rateLimits
    }
}

public struct LibtorrentRateLimits: Sendable, Equatable, Codable {
    public let downloadBytesPerSecond: Int?
    public let uploadBytesPerSecond: Int?

    public init(
        downloadBytesPerSecond: Int? = nil,
        uploadBytesPerSecond: Int? = nil
    ) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
    }

    /// Libtorrent treats zero as unlimited, so use a one-byte cap for
    /// mobile sessions that should not participate in meaningful uploading.
    public static let mobileDownloadOnly = LibtorrentRateLimits(uploadBytesPerSecond: 1)
}

public struct LibtorrentFileSelection: Sendable, Equatable, Codable {
    public let all: Bool
    public let fileIndexes: [Int]
    public let globs: [String]
    public let primaryFileIndex: Int?

    public init(
        all: Bool = false,
        fileIndexes: [Int] = [],
        globs: [String] = [],
        primaryFileIndex: Int? = nil
    ) {
        self.all = all
        self.fileIndexes = fileIndexes
        self.globs = globs
        self.primaryFileIndex = primaryFileIndex
    }
}

public struct LibtorrentFileInfo: Sendable, Equatable, Identifiable, Codable {
    public let id: Int
    public let path: String
    public let sizeBytes: Int64?
    public let bytesCompleted: Int64
    public let percentComplete: Double?
    public let localFileURL: URL?

    public init(
        id: Int,
        path: String,
        sizeBytes: Int64? = nil,
        bytesCompleted: Int64 = 0,
        percentComplete: Double? = nil,
        localFileURL: URL? = nil
    ) {
        self.id = id
        self.path = path
        self.sizeBytes = sizeBytes
        self.bytesCompleted = bytesCompleted
        self.percentComplete = percentComplete
        self.localFileURL = localFileURL
    }
}

public struct LibtorrentProgress: Sendable, Equatable, Codable {
    public let jobId: UUID
    public let status: String
    public let name: String?
    public let infoHash: String?
    public let bytesCompleted: Int64
    public let totalBytes: Int64?
    public let percentComplete: Double?
    public let bytesPerSecond: Double?
    public let peerCount: Int?
    public let files: [LibtorrentFileInfo]

    public init(
        jobId: UUID,
        status: String,
        name: String? = nil,
        infoHash: String? = nil,
        bytesCompleted: Int64 = 0,
        totalBytes: Int64? = nil,
        percentComplete: Double? = nil,
        bytesPerSecond: Double? = nil,
        peerCount: Int? = nil,
        files: [LibtorrentFileInfo] = []
    ) {
        self.jobId = jobId
        self.status = status
        self.name = name
        self.infoHash = infoHash
        self.bytesCompleted = bytesCompleted
        self.totalBytes = totalBytes
        self.percentComplete = percentComplete
        self.bytesPerSecond = bytesPerSecond
        self.peerCount = peerCount
        self.files = files
    }
}

public struct LibtorrentStreamReadiness: Sendable, Equatable, Codable {
    public let jobId: UUID
    public let primaryFileIndex: Int
    public let fileURL: URL
    public let bytesAvailable: Int64
    public let totalBytes: Int64?

    public init(
        jobId: UUID,
        primaryFileIndex: Int,
        fileURL: URL,
        bytesAvailable: Int64,
        totalBytes: Int64? = nil
    ) {
        self.jobId = jobId
        self.primaryFileIndex = primaryFileIndex
        self.fileURL = fileURL
        self.bytesAvailable = bytesAvailable
        self.totalBytes = totalBytes
    }
}

public enum LibtorrentEvent: Sendable, Equatable {
    case progress(LibtorrentProgress)
    case streamReady(LibtorrentStreamReadiness)
    case completed(LibtorrentProgress)
}

public protocol LibtorrentSession: Sendable {
    func start(
        input: LibtorrentJobInput,
        selection: LibtorrentFileSelection?,
        eventHandler: @escaping @Sendable (LibtorrentEvent) async -> Void
    ) async throws

    func applySelection(jobId: UUID, selection: LibtorrentFileSelection) async throws
    func pause(jobId: UUID) async throws
    func resume(jobId: UUID) async throws
    func cancel(jobId: UUID) async throws
}

public enum LibtorrentSessionFactory {
    public static func makeDefault() -> any LibtorrentSession {
        #if canImport(Darwin)
            if let nativeSession = try? NativeLibtorrentSession() {
                return nativeSession
            }
        #endif
        return UnavailableLibtorrentSession()
    }
}

public struct UnavailableLibtorrentSession: LibtorrentSession {
    public init() {}

    public func start(
        input _: LibtorrentJobInput,
        selection _: LibtorrentFileSelection?,
        eventHandler _: @escaping @Sendable (LibtorrentEvent) async -> Void
    ) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }

    public func applySelection(jobId _: UUID, selection _: LibtorrentFileSelection) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }

    public func pause(jobId _: UUID) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }

    public func resume(jobId _: UUID) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }

    public func cancel(jobId _: UUID) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }
}
