import AVFoundation
import XCTest
@testable import YouTubePod

final class YouTubeDataClientTests: XCTestCase {
    override func tearDown() {
        URLProtocolStub.handler = nil
        super.tearDown()
    }

    func testPopularVideoDTOConversion() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/youtube/v3/videos")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertNil(query?.first { $0.name == "key" })
            XCTAssertEqual(query?.first { $0.name == "maxResults" }?.value, "20")
            let payload = #"""
            {"items":[{"id":"dQw4w9WgXcQ","snippet":{"title":"Music &amp; Talk","channelTitle":"Channel","channelId":"channel-123","publishedAt":"2026-08-15T00:00:00Z","thumbnails":{"high":{"url":"https://example.com/cover.jpg"}}},"statistics":{"viewCount":"12345"},"contentDetails":{"duration":"PT1H2M3S"}}]}
            """#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        let videos = try await client.popularVideos(regionCode: "JP")

        XCTAssertEqual(videos.count, 1)
        XCTAssertEqual(videos[0].id, "dQw4w9WgXcQ")
        XCTAssertEqual(videos[0].title, "Music & Talk")
        XCTAssertEqual(videos[0].channelID, "channel-123")
        XCTAssertEqual(videos[0].viewCount, 12_345)
        XCTAssertEqual(videos[0].duration, 3_723)
        XCTAssertEqual(videos[0].broadcastStatus, .none)
        XCTAssertTrue(videos[0].supportsAudioExtraction)
    }

    func testLiveVideoDTOIsMarkedUnsupportedForAudioExtraction() async throws {
        URLProtocolStub.handler = { request in
            let payload = #"""
            {"items":[{"id":"livevideo01","snippet":{"title":"Live","channelTitle":"Channel","publishedAt":"2026-08-15T00:00:00Z","liveBroadcastContent":"live","thumbnails":{}},"statistics":{"viewCount":"12"},"contentDetails":{"duration":"PT0S"}}]}
            """#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        let videos = try await client.popularVideos(regionCode: "JP")

        XCTAssertEqual(videos.first?.broadcastStatus, .live)
        XCTAssertEqual(videos.first?.duration, 0)
        XCTAssertFalse(try XCTUnwrap(videos.first).supportsAudioExtraction)
    }

    func testSearchUsesYouTubeSearchThenFetchesVideoDetails() async throws {
        let requestCount = LockedCounter()
        URLProtocolStub.handler = { request in
            requestCount.increment()
            let payload: String
            switch request.url?.path {
            case "/youtube/v3/search":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "q" }?.value, "Swift 音声")
                XCTAssertEqual(query?.first { $0.name == "type" }?.value, "video")
                payload = #"{"items":[{"id":{"videoId":"searchvid01"}}]}"#
            case "/youtube/v3/videos":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "id" }?.value, "searchvid01")
                payload = #"{"items":[{"id":"searchvid01","snippet":{"title":"Search result","channelTitle":"Channel","publishedAt":"2026-08-15T00:00:00Z","thumbnails":{}},"statistics":{"viewCount":"99"},"contentDetails":{"duration":"PT2M"}}]}"#
            default:
                throw URLError(.unsupportedURL)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        let videos = try await client.searchVideos(query: "  Swift 音声  ")

        XCTAssertEqual(requestCount.value, 2)
        XCTAssertEqual(videos.map(\.id), ["searchvid01"])
        XCTAssertEqual(videos.first?.duration, 120)
    }

    func testBlankSearchDoesNotSendARequest() async throws {
        URLProtocolStub.handler = { _ in
            XCTFail("Blank searches must not consume YouTube API quota")
            throw URLError(.badURL)
        }
        let client = makeClient()

        let videos = try await client.searchVideos(query: "  \n ")

        XCTAssertTrue(videos.isEmpty)
    }

    func testPopularVideosUsesFifteenMinuteSessionCacheUntilCleared() async throws {
        let requestCount = LockedCounter()
        URLProtocolStub.handler = { request in
            requestCount.increment()
            let payload = #"{"items":[]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let sessionID = UUID()
        let client = YouTubeDataClient(
            credentialProvider: {
                YouTubeCredential(accessToken: "token", accountID: "account", sessionID: sessionID)
            },
            session: URLSession(configuration: configuration)
        )

        _ = try await client.popularVideos(regionCode: "JP")
        _ = try await client.popularVideos(regionCode: "JP")
        XCTAssertEqual(requestCount.value, 1)

        await client.clearCache()
        _ = try await client.popularVideos(regionCode: "JP")
        XCTAssertEqual(requestCount.value, 2)
    }

    func testQuotaErrorIsMappedFrom403() async {
        URLProtocolStub.handler = { request in
            let payload = #"{"error":{"message":"quota exceeded"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.popularVideos(regionCode: "JP")
            XCTFail("Expected quota error")
        } catch CatalogError.quotaOrPermission(let detail) {
            XCTAssertEqual(detail, "quota exceeded")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testNetworkFailureIsMappedForOfflineUI() async {
        URLProtocolStub.handler = { _ in throw URLError(.notConnectedToInternet) }
        let client = makeClient()

        do {
            _ = try await client.popularVideos(regionCode: "JP")
            XCTFail("Expected network error")
        } catch CatalogError.network(let detail) {
            XCTAssertFalse(detail.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMissingOAuthCredentialDoesNotSendNetworkRequest() async {
        URLProtocolStub.handler = { _ in
            XCTFail("Request must not be sent without OAuth")
            throw URLError(.userAuthenticationRequired)
        }
        let client = makeClient(token: nil)

        do {
            _ = try await client.popularVideos(regionCode: "JP")
            XCTFail("Expected authentication error")
        } catch CatalogError.authenticationRequired {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func test401InvalidatesAuthentication() async {
        let invalidation = LockedCounter()
        URLProtocolStub.handler = { request in
            let payload = #"{"error":{"message":"expired"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let client = YouTubeDataClient(
            credentialProvider: { YouTubeCredential(accessToken: "expired", accountID: "account", sessionID: UUID()) },
            authenticationFailureHandler: { invalidation.increment() },
            session: URLSession(configuration: configuration)
        )

        _ = try? await client.popularVideos(regionCode: "JP")

        XCTAssertEqual(invalidation.value, 1)
    }

    func testSubscriptionUploadsSkipsUnavailablePlaylistItems() async throws {
        URLProtocolStub.handler = { request in
            let payload: String
            switch request.url?.path {
            case "/youtube/v3/subscriptions":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "maxResults" }?.value, "50")
                XCTAssertEqual(query?.first { $0.name == "order" }?.value, "unread")
                XCTAssertNil(query?.first { $0.name == "pageToken" })
                payload = #"{"items":[{"snippet":{"resourceId":{"channelId":"channel-1"}}}]}"#
            case "/youtube/v3/channels":
                payload = #"{"items":[{"contentDetails":{"relatedPlaylists":{"uploads":"uploads-1"}}}]}"#
            case "/youtube/v3/playlistItems":
                payload = #"{"items":[{"contentDetails":null},{"contentDetails":{"videoId":null}},{"contentDetails":{"videoId":"video-1"}}]}"#
            case "/youtube/v3/videos":
                payload = #"{"items":[{"id":"video-1","snippet":{"title":"Available video","channelTitle":"Channel","publishedAt":"2026-08-15T00:00:00Z","thumbnails":{}},"statistics":{"viewCount":"10"},"contentDetails":{"duration":"PT3M"}}]}"#
            default:
                throw URLError(.unsupportedURL)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        let videos = try await client.subscriptionUploads()

        XCTAssertEqual(videos.map(\.id), ["video-1"])
    }

    func testSubscriptionUploadsPagePassesTokenAndReturnsNextToken() async throws {
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/youtube/v3/subscriptions")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "pageToken" }?.value, "incoming-page")
            XCTAssertEqual(query?.first { $0.name == "order" }?.value, "unread")
            let payload = #"{"nextPageToken":"outgoing-page","items":[]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        let page = try await client.subscriptionUploadsPage(pageToken: "incoming-page")

        XCTAssertTrue(page.videos.isEmpty)
        XCTAssertEqual(page.nextPageToken, "outgoing-page")
    }

    func testSubscriptionUploadsAggregatesEverySubscriptionPageAndRemovesDuplicates() async throws {
        URLProtocolStub.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let pageToken = query?.first { $0.name == "pageToken" }?.value
            let payload: String
            switch request.url?.path {
            case "/youtube/v3/subscriptions" where pageToken == nil:
                payload = #"{"nextPageToken":"page-2","items":[{"snippet":{"resourceId":{"channelId":"channel-1"}}}]}"#
            case "/youtube/v3/subscriptions" where pageToken == "page-2":
                payload = #"{"items":[{"snippet":{"resourceId":{"channelId":"channel-2"}}}]}"#
            case "/youtube/v3/channels":
                let channelID = query?.first { $0.name == "id" }?.value
                payload = channelID == "channel-1"
                    ? #"{"items":[{"contentDetails":{"relatedPlaylists":{"uploads":"uploads-1"}}}]}"#
                    : #"{"items":[{"contentDetails":{"relatedPlaylists":{"uploads":"uploads-2"}}}]}"#
            case "/youtube/v3/playlistItems":
                let playlistID = query?.first { $0.name == "playlistId" }?.value
                payload = playlistID == "uploads-1"
                    ? #"{"items":[{"contentDetails":{"videoId":"sharedvideo"}},{"contentDetails":{"videoId":"oldervideo1"}}]}"#
                    : #"{"items":[{"contentDetails":{"videoId":"sharedvideo"}},{"contentDetails":{"videoId":"newervideo1"}}]}"#
            case "/youtube/v3/videos":
                let ids = Set((query?.first { $0.name == "id" }?.value ?? "").split(separator: ",").map(String.init))
                var items: [String] = []
                if ids.contains("sharedvideo") {
                    items.append(#"{"id":"sharedvideo","snippet":{"title":"Shared","channelTitle":"Channel","publishedAt":"2026-08-14T00:00:00Z","thumbnails":{}},"statistics":{"viewCount":"1"},"contentDetails":{"duration":"PT1M"}}"#)
                }
                if ids.contains("oldervideo1") {
                    items.append(#"{"id":"oldervideo1","snippet":{"title":"Older","channelTitle":"Channel","publishedAt":"2026-08-13T00:00:00Z","thumbnails":{}},"statistics":{"viewCount":"1"},"contentDetails":{"duration":"PT1M"}}"#)
                }
                if ids.contains("newervideo1") {
                    items.append(#"{"id":"newervideo1","snippet":{"title":"Newer","channelTitle":"Channel","publishedAt":"2026-08-15T00:00:00Z","thumbnails":{}},"statistics":{"viewCount":"1"},"contentDetails":{"duration":"PT1M"}}"#)
                }
                payload = "{\"items\":[\(items.joined(separator: ","))]}"
            default:
                throw URLError(.unsupportedURL)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        let videos = try await client.subscriptionUploads()

        XCTAssertEqual(videos.map(\.id), ["newervideo1", "sharedvideo", "oldervideo1"])
    }

    func testSubscriptionUploadsStopsWhenYouTubeRepeatsAPageToken() async throws {
        let subscriptionRequests = LockedCounter()
        URLProtocolStub.handler = { request in
            guard request.url?.path == "/youtube/v3/subscriptions" else {
                throw URLError(.unsupportedURL)
            }
            subscriptionRequests.increment()
            let payload = #"{"nextPageToken":"same-token","items":[]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        let videos = try await client.subscriptionUploads()

        XCTAssertTrue(videos.isEmpty)
        XCTAssertEqual(subscriptionRequests.value, 2)
    }

    func testChannelVideosUsesUploadsPlaylistAndReturnsPagedDetails() async throws {
        URLProtocolStub.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let payload: String
            switch request.url?.path {
            case "/youtube/v3/channels":
                XCTAssertEqual(query?.first { $0.name == "id" }?.value, "channel-123")
                payload = #"{"items":[{"contentDetails":{"relatedPlaylists":{"uploads":"uploads-123"}}}]}"#
            case "/youtube/v3/playlistItems":
                XCTAssertEqual(query?.first { $0.name == "playlistId" }?.value, "uploads-123")
                XCTAssertEqual(query?.first { $0.name == "pageToken" }?.value, "incoming-page")
                payload = #"{"nextPageToken":"outgoing-page","items":[{"contentDetails":{"videoId":"channelvid1"}}]}"#
            case "/youtube/v3/videos":
                XCTAssertEqual(query?.first { $0.name == "id" }?.value, "channelvid1")
                payload = #"{"items":[{"id":"channelvid1","snippet":{"title":"Channel video","channelTitle":"Test channel","channelId":"channel-123","publishedAt":"2026-08-15T00:00:00Z","thumbnails":{}},"statistics":{"viewCount":"321"},"contentDetails":{"duration":"PT4M"}}]}"#
            default:
                throw URLError(.unsupportedURL)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        let page = try await client.channelVideosPage(
            channelID: "channel-123",
            pageToken: "incoming-page"
        )

        XCTAssertEqual(page.videos.map(\.id), ["channelvid1"])
        XCTAssertEqual(page.videos.first?.channelID, "channel-123")
        XCTAssertEqual(page.nextPageToken, "outgoing-page")
    }

    func testBlankChannelIDDoesNotSendARequest() async {
        URLProtocolStub.handler = { _ in
            XCTFail("Blank channel IDs must not send a YouTube API request")
            throw URLError(.badURL)
        }
        let client = makeClient()

        do {
            _ = try await client.channelVideosPage(channelID: "  \n ", pageToken: nil)
            XCTFail("Expected invalid request")
        } catch CatalogError.invalidRequest {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeClient(token: String? = "test-token") -> YouTubeDataClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        return YouTubeDataClient(
            credentialProvider: {
                token.map {
                    YouTubeCredential(accessToken: $0, accountID: "test-account", sessionID: UUID())
                }
            },
            session: URLSession(configuration: configuration)
        )
    }
}

final class AudioExtractionIntegrationTests: XCTestCase {
    func testPublicVideoExtractsAsM4AAudioOnlyWhenEnabled() async throws {
        try requireNetworkIntegration()
        let source = try XCTUnwrap(URL(string: "https://www.youtube.com/watch?v=jNQXAC9IVRw"))
        let extracted = try await extractAndValidate(source)
        defer { try? FileManager.default.removeItem(at: extracted.fileURL.deletingLastPathComponent()) }

        XCTAssertEqual(extracted.videoID, "jNQXAC9IVRw")
    }

    func testConfiguredShortsExtractsAsM4AAudioOnlyWhenEnabled() async throws {
        try requireNetworkIntegration()
        let source = try configuredURL(
            named: "YOUTUBEPOD_TEST_SHORTS_URL",
            purpose: "a public Shorts URL"
        )
        let extracted = try await extractAndValidate(source)
        defer { try? FileManager.default.removeItem(at: extracted.fileURL.deletingLastPathComponent()) }

        XCTAssertEqual(extracted.videoID, YouTubeURLParser.videoID(from: source.absoluteString))
    }

    func testConfiguredLongVideoIsAtLeastThirtyMinutesAndAudioOnlyWhenEnabled() async throws {
        try requireNetworkIntegration()
        let source = try configuredURL(
            named: "YOUTUBEPOD_TEST_LONG_URL",
            purpose: "a public video URL of at least 30 minutes"
        )
        let extracted = try await extractAndValidate(source)
        defer { try? FileManager.default.removeItem(at: extracted.fileURL.deletingLastPathComponent()) }

        XCTAssertGreaterThanOrEqual(extracted.duration, 30 * 60)
    }

    func testConfiguredDownloadCanBeCancelledWithoutLeavingTemporaryFiles() async throws {
        try requireNetworkIntegration()
        let source = try configuredURL(
            named: "YOUTUBEPOD_TEST_CANCEL_URL",
            purpose: "a sufficiently long public video URL"
        )
        let before = extractorTemporaryDirectories()
        let extractor = PythonAudioExtractor()
        let extraction = Task {
            try await extractor.extract(from: source) { _ in }
        }

        try await Task.sleep(for: .milliseconds(500))
        await extractor.cancel()

        do {
            let extracted = try await extraction.value
            try? FileManager.default.removeItem(at: extracted.fileURL.deletingLastPathComponent())
            XCTFail("The configured video completed before cancellation could be verified")
        } catch ExtractionError.cancelled {
            // Expected.
        } catch {
            XCTFail("Expected ExtractionError.cancelled, got: \(error)")
        }

        for _ in 0..<50 where extractorTemporaryDirectories() != before {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(extractorTemporaryDirectories(), before)
    }

    private func extractAndValidate(_ source: URL) async throws -> ExtractedAudio {
        let extracted = try await PythonAudioExtractor().extract(from: source) { _ in }
        XCTAssertEqual(extracted.fileURL.pathExtension.lowercased(), "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: extracted.fileURL.path))

        let asset = AVURLAsset(url: extracted.fileURL)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(videoTracks.isEmpty)
        XCTAssertFalse(audioTracks.isEmpty)
        return extracted
    }

    private func requireNetworkIntegration() throws {
        guard ProcessInfo.processInfo.environment["YOUTUBEPOD_RUN_NETWORK_INTEGRATION"] == "1" else {
            throw XCTSkip("Use the YouTubePodIntegration scheme to run on-device extraction tests.")
        }
    }

    private func configuredURL(named name: String, purpose: String) throws -> URL {
        let rawValue = ProcessInfo.processInfo.environment[name]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !rawValue.isEmpty, !rawValue.hasPrefix("$("), let url = URL(string: rawValue) else {
            throw XCTSkip("Set \(name) to \(purpose).")
        }
        return url
    }

    private func extractorTemporaryDirectories() -> Set<String> {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory,
            includingPropertiesForKeys: nil
        )) ?? []
        return Set(urls.lazy.filter { $0.lastPathComponent.hasPrefix("YouTubePod-") }.map(\.path))
    }
}

final class PythonAudioExtractorCleanupTests: XCTestCase {
    func testStartupCleanupRemovesOnlyExtractionWorkingDirectories() throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
        let extractionDirectory = temporaryDirectory
            .appendingPathComponent("YouTubePod-\(UUID().uuidString)", isDirectory: true)
        let unrelatedDirectory = temporaryDirectory
            .appendingPathComponent("YouTubePod-LibraryTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: extractionDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: extractionDirectory)
            try? FileManager.default.removeItem(at: unrelatedDirectory)
        }

        PythonAudioExtractor.removeStaleWorkingDirectories()

        XCTAssertFalse(FileManager.default.fileExists(atPath: extractionDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedDirectory.path))
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }
    func increment() { lock.withLock { storage += 1 } }
}

private final class URLProtocolStub: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.badServerResponse) }
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
