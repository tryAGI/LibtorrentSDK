import Foundation
@_spi(Testing) import LibtorrentSDK

#if canImport(Darwin)
    @main
    struct LibtorrentSDKSmokeTests {
        static func main() async throws {
            try await testNativeSessionDispatchesProgressFromNativeABI()
            try await testNativeSessionForwardsControlRequests()

            print("Tests passed:")
            print("- LibtorrentSDKSmokeTests.testNativeSessionDispatchesProgressFromNativeABI")
            print("- LibtorrentSDKSmokeTests.testNativeSessionForwardsControlRequests")
        }

        private static func testNativeSessionDispatchesProgressFromNativeABI() async throws {
            NativeABISmokeState.shared.reset()

            let session = try NativeLibtorrentSession(library: NativeABISmokeLibrary.make())
            let recorder = LibtorrentEventRecorder()
            let jobId = UUID()

            try await session.start(
                input: LibtorrentJobInput(
                    jobId: jobId,
                    magnetUri: "magnet:?xt=urn:btih:abcdef0123456789",
                    downloadDirectory: URL(fileURLWithPath: "/tmp/advantage-libtorrent-smoke", isDirectory: true)
                ),
                selection: LibtorrentFileSelection(all: true, primaryFileIndex: 0)
            ) { event in
                await recorder.record(event)
            }

            let event = try await recorder.waitForEvent()
            switch event {
            case let .progress(progress):
                try require(progress.jobId == jobId, "Progress event should preserve the job id.")
                try require(progress.status == "downloading", "Progress event should preserve the status.")
                try require(progress.bytesCompleted == 4, "Progress event should preserve bytesCompleted.")
                try require(progress.totalBytes == 8, "Progress event should preserve totalBytes.")
            default:
                throw SmokeFailure("Expected progress event, received \(event).")
            }

            let snapshot = NativeABISmokeState.shared.snapshot()
            try require(snapshot.startRequestCount == 1, "Start should call the native ABI once.")
            try require(
                snapshot.lastStartRequest?.localizedCaseInsensitiveContains(jobId.uuidString) == true,
                "Start request should include the job id."
            )
            try require(
                snapshot.lastStartRequest?.contains("\"all\":true") == true,
                "Start request should include the selected-file policy."
            )
        }

        private static func testNativeSessionForwardsControlRequests() async throws {
            NativeABISmokeState.shared.reset()

            let session = try NativeLibtorrentSession(library: NativeABISmokeLibrary.make())
            let jobId = UUID()

            try await session.applySelection(
                jobId: jobId,
                selection: LibtorrentFileSelection(fileIndexes: [2, 4], globs: ["*.mp3"], primaryFileIndex: 2)
            )
            try await session.pause(jobId: jobId)
            try await session.resume(jobId: jobId)
            try await session.cancel(jobId: jobId)

            let snapshot = NativeABISmokeState.shared.snapshot()
            try require(snapshot.lastSelectionRequest?.localizedCaseInsensitiveContains(jobId.uuidString) == true)
            try require(snapshot.lastSelectionRequest?.contains("\"fileIndexes\":[2,4]") == true)
            try require(snapshot.lastSelectionRequest?.contains("\"globs\":[\"*.mp3\"]") == true)
            try require(snapshot.lastPauseRequest?.localizedCaseInsensitiveContains(jobId.uuidString) == true)
            try require(snapshot.lastResumeRequest?.localizedCaseInsensitiveContains(jobId.uuidString) == true)
            try require(snapshot.lastCancelRequest?.localizedCaseInsensitiveContains(jobId.uuidString) == true)
        }

        private static func require(_ condition: Bool, _ message: String = "Smoke assertion failed.") throws {
            if !condition {
                throw SmokeFailure(message)
            }
        }
    }

    private struct SmokeFailure: Error, CustomStringConvertible {
        let description: String

        init(_ description: String) {
            self.description = description
        }
    }

    private actor LibtorrentEventRecorder {
        private var events: [LibtorrentEvent] = []

        func record(_ event: LibtorrentEvent) {
            events.append(event)
        }

        func waitForEvent(timeout: Duration = .seconds(2)) async throws -> LibtorrentEvent {
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: timeout)

            while events.isEmpty {
                if clock.now >= deadline {
                    throw SmokeFailure("Timed out waiting for a native progress event.")
                }

                try await Task.sleep(for: .milliseconds(10))
            }

            return events.removeFirst()
        }
    }

    private struct NativeABISmokeSnapshot: Sendable {
        let startRequestCount: Int
        let lastStartRequest: String?
        let lastSelectionRequest: String?
        let lastPauseRequest: String?
        let lastResumeRequest: String?
        let lastCancelRequest: String?
    }

    private final class NativeABISmokeState: @unchecked Sendable {
        static let shared = NativeABISmokeState()

        private let lock = NSLock()
        private var callback: NativeLibtorrentLibrary.NativeEventCallback?
        private var context: UnsafeMutableRawPointer?
        private var startRequests: [String] = []
        private var selectionRequests: [String] = []
        private var pauseRequests: [String] = []
        private var resumeRequests: [String] = []
        private var cancelRequests: [String] = []
        private var destroyCount = 0

        func reset() {
            locked {
                callback = nil
                context = nil
                startRequests.removeAll()
                selectionRequests.removeAll()
                pauseRequests.removeAll()
                resumeRequests.removeAll()
                cancelRequests.removeAll()
                destroyCount = 0
            }
        }

        func install(
            callback: NativeLibtorrentLibrary.NativeEventCallback?,
            context: UnsafeMutableRawPointer?
        ) -> OpaquePointer {
            locked {
                self.callback = callback
                self.context = context
            }
            return OpaquePointer(Unmanaged.passUnretained(self).toOpaque())
        }

        func recordDestroy() {
            locked {
                destroyCount += 1
            }
        }

        func recordStart(_ json: String) -> Int32 {
            locked {
                startRequests.append(json)
            }

            emitProgress(jobId: Self.extractJobId(from: json))
            return 0
        }

        func recordSelection(_ json: String) -> Int32 {
            locked {
                selectionRequests.append(json)
            }
            return 0
        }

        func recordPause(_ json: String) -> Int32 {
            locked {
                pauseRequests.append(json)
            }
            return 0
        }

        func recordResume(_ json: String) -> Int32 {
            locked {
                resumeRequests.append(json)
            }
            return 0
        }

        func recordCancel(_ json: String) -> Int32 {
            locked {
                cancelRequests.append(json)
            }
            return 0
        }

        func snapshot() -> NativeABISmokeSnapshot {
            locked {
                NativeABISmokeSnapshot(
                    startRequestCount: startRequests.count,
                    lastStartRequest: startRequests.last,
                    lastSelectionRequest: selectionRequests.last,
                    lastPauseRequest: pauseRequests.last,
                    lastResumeRequest: resumeRequests.last,
                    lastCancelRequest: cancelRequests.last
                )
            }
        }

        func lastError() -> UnsafePointer<CChar>? {
            nil
        }

        private func emitProgress(jobId: String) {
            let json = """
            {"type":"progress","progress":{"jobId":"\(jobId)","status":"downloading","bytesCompleted":4,"totalBytes":8,"percentComplete":50,"files":[]}}
            """

            let target = locked {
                (callback, context)
            }
            guard let callback = target.0 else { return }
            json.withCString { pointer in
                callback(pointer, target.1)
            }
        }

        private func locked<T>(_ body: () -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body()
        }

        private static func extractJobId(from json: String) -> String {
            guard let data = json.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let input = object["input"] as? [String: Any],
                  let jobId = input["jobId"] as? String
            else {
                return UUID().uuidString
            }

            return jobId
        }
    }

    private enum NativeABISmokeLibrary {
        static func make() -> NativeLibtorrentLibrary {
            NativeLibtorrentLibrary(
                create: create,
                destroy: destroy,
                start: start,
                applySelection: applySelection,
                pause: pause,
                resume: resume,
                cancel: cancel,
                lastError: lastError
            )
        }

        private static let create: NativeLibtorrentLibrary.NativeCreate = { callback, context, session in
            session?.pointee = NativeABISmokeState.shared.install(callback: callback, context: context)
            return 0
        }

        private static let destroy: NativeLibtorrentLibrary.NativeDestroy = { _ in
            NativeABISmokeState.shared.recordDestroy()
        }

        private static let start: NativeLibtorrentLibrary.NativeJSONCommand = { _, json in
            guard let json else { return -1 }
            return NativeABISmokeState.shared.recordStart(String(cString: json))
        }

        private static let applySelection: NativeLibtorrentLibrary.NativeJSONCommand = { _, json in
            guard let json else { return -1 }
            return NativeABISmokeState.shared.recordSelection(String(cString: json))
        }

        private static let pause: NativeLibtorrentLibrary.NativeJSONCommand = { _, json in
            guard let json else { return -1 }
            return NativeABISmokeState.shared.recordPause(String(cString: json))
        }

        private static let resume: NativeLibtorrentLibrary.NativeJSONCommand = { _, json in
            guard let json else { return -1 }
            return NativeABISmokeState.shared.recordResume(String(cString: json))
        }

        private static let cancel: NativeLibtorrentLibrary.NativeJSONCommand = { _, json in
            guard let json else { return -1 }
            return NativeABISmokeState.shared.recordCancel(String(cString: json))
        }

        private static let lastError: NativeLibtorrentLibrary.NativeLastError = { _ in
            NativeABISmokeState.shared.lastError()
        }
    }
#else
    @main
    struct LibtorrentSDKSmokeTests {
        static func main() {
            print("Tests passed:")
            print("- LibtorrentSDKSmokeTests.skippedOnNonDarwin")
        }
    }
#endif
