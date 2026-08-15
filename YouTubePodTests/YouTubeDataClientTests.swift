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

    func testPopularVideosCacheExpiresAtFifteenMinuteBoundary() async throws {
        let requestCount = LockedCounter()
        let clock = LockedDate(Date(timeIntervalSince1970: 1_000))
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
            session: URLSession(configuration: configuration),
            cacheLifetime: 15 * 60,
            now: { clock.value }
        )

        _ = try await client.popularVideos(regionCode: "JP")
        clock.advance(by: 15 * 60 - 1)
        _ = try await client.popularVideos(regionCode: "JP")
        XCTAssertEqual(requestCount.value, 1)

        clock.advance(by: 1)
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

    func testRateLimitErrorIsMappedFrom429() async {
        URLProtocolStub.handler = { request in
            let payload = #"{"error":{"message":"rate limited"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.popularVideos(regionCode: "JP")
            XCTFail("Expected quota or rate-limit error")
        } catch CatalogError.quotaOrPermission(let detail) {
            XCTAssertEqual(detail, "rate limited")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testServerErrorIsMappedFrom500() async {
        URLProtocolStub.handler = { request in
            let payload = #"{"error":{"message":"backend unavailable"}}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.popularVideos(regionCode: "JP")
            XCTFail("Expected server error")
        } catch CatalogError.server(let detail) {
            XCTAssertEqual(detail, "backend unavailable")
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
                XCTAssertEqual(query?.first { $0.name == "maxResults" }?.value, "20")
                XCTAssertEqual(query?.first { $0.name == "order" }?.value, "unread")
                XCTAssertNil(query?.first { $0.name == "pageToken" })
                payload = #"{"items":[{"snippet":{"resourceId":{"channelId":"channel-1"}}}]}"#
            case "/youtube/v3/channels":
                payload = #"{"items":[{"contentDetails":{"relatedPlaylists":{"uploads":"uploads-1"}}}]}"#
            case "/youtube/v3/playlistItems":
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
                XCTAssertEqual(query?.first { $0.name == "maxResults" }?.value, "3")
                payload = #"{"items":[{"contentDetails":null},{"contentDetails":{"videoId":null}},{"contentDetails":{"videoId":"video-1"}}]}"#
            case "/youtube/v3/videos":
                payload = #"{"items":[{"id":"video-1","snippet":{"title":"Available video","channelTitle":"Channel","publishedAt":"2026-08-15T00:00:00Z","thumbnails":{}},"statistics":{"viewCount":"10"},"contentDetails":{"duration":"PT3M"}}]}"#
            default:
                throw URLError(.unsupportedURL)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        let videos = try await client.subscriptionUploadsPage(pageToken: nil).videos

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

    func testSubscriptionPageDoesNotAutomaticallyFollowNextPage() async throws {
        let subscriptionRequests = LockedCounter()
        URLProtocolStub.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let pageToken = query?.first { $0.name == "pageToken" }?.value
            let payload: String
            switch request.url?.path {
            case "/youtube/v3/subscriptions" where pageToken == nil:
                subscriptionRequests.increment()
                payload = #"{"nextPageToken":"page-2","items":[{"snippet":{"resourceId":{"channelId":"channel-1"}}}]}"#
            case "/youtube/v3/channels":
                payload = #"{"items":[{"contentDetails":{"relatedPlaylists":{"uploads":"uploads-1"}}}]}"#
            case "/youtube/v3/playlistItems":
                payload = #"{"items":[{"contentDetails":{"videoId":"video-1"}}]}"#
            case "/youtube/v3/videos":
                payload = #"{"items":[{"id":"video-1","snippet":{"title":"Video","channelTitle":"Channel","publishedAt":"2026-08-15T00:00:00Z","thumbnails":{}},"statistics":{"viewCount":"1"},"contentDetails":{"duration":"PT1M"}}]}"#
            default:
                throw URLError(.unsupportedURL)
            }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        let page = try await client.subscriptionUploadsPage(pageToken: nil)

        XCTAssertEqual(page.videos.map(\.id), ["video-1"])
        XCTAssertEqual(page.nextPageToken, "page-2")
        XCTAssertEqual(subscriptionRequests.value, 1)
    }

    func testConcurrentSubscriptionPageRequestsUseOneBoundedSingleFlight() async throws {
        let subscriptionsRequests = LockedCounter()
        let channelsRequests = LockedCounter()
        let playlistRequests = LockedCounter()
        let videosRequests = LockedCounter()
        URLProtocolStub.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let payload: String
            switch request.url?.path {
            case "/youtube/v3/subscriptions":
                subscriptionsRequests.increment()
                Thread.sleep(forTimeInterval: 0.05)
                let items = (1...20).map {
                    #"{"snippet":{"resourceId":{"channelId":"channel-\#($0)"}}}"#
                }.joined(separator: ",")
                payload = "{\"items\":[\(items)]}"
            case "/youtube/v3/channels":
                channelsRequests.increment()
                let ids = (query?.first { $0.name == "id" }?.value ?? "").split(separator: ",")
                let items = ids.map { channelID in
                    let suffix = channelID.split(separator: "-").last ?? "0"
                    return #"{"contentDetails":{"relatedPlaylists":{"uploads":"uploads-\#(suffix)"}}}"#
                }.joined(separator: ",")
                payload = "{\"items\":[\(items)]}"
            case "/youtube/v3/playlistItems":
                playlistRequests.increment()
                let playlistID = query?.first { $0.name == "playlistId" }?.value ?? ""
                let suffix = playlistID.split(separator: "-").last ?? "0"
                payload = #"{"items":[{"contentDetails":{"videoId":"video-\#(suffix)"}}]}"#
            case "/youtube/v3/videos":
                videosRequests.increment()
                let ids = (query?.first { $0.name == "id" }?.value ?? "").split(separator: ",")
                let items = ids.map {
                    #"{"id":"\#($0)","snippet":{"title":"Video","channelTitle":"Channel","publishedAt":"2026-08-15T00:00:00Z","thumbnails":{}},"statistics":{"viewCount":"1"},"contentDetails":{"duration":"PT1M"}}"#
                }.joined(separator: ",")
                payload = "{\"items\":[\(items)]}"
            default:
                throw URLError(.unsupportedURL)
            }
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

        async let first = client.subscriptionUploadsPage(pageToken: nil)
        async let second = client.subscriptionUploadsPage(pageToken: nil)
        let pages = try await [first, second]

        XCTAssertEqual(pages[0].videos.count, 20)
        XCTAssertEqual(pages[1].videos.count, 20)
        XCTAssertEqual(subscriptionsRequests.value, 1)
        XCTAssertEqual(channelsRequests.value, 1)
        XCTAssertEqual(playlistRequests.value, 20)
        XCTAssertEqual(videosRequests.value, 1)
    }

    func testCancellingOneSingleFlightWaiterKeepsRequestForRemainingWaiter() async throws {
        let requestCount = LockedCounter()
        URLProtocolStub.handler = { request in
            requestCount.increment()
            Thread.sleep(forTimeInterval: 0.1)
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

        let cancelledWaiter = Task { try await client.popularVideos(regionCode: "JP") }
        try await Task.sleep(for: .milliseconds(10))
        let remainingWaiter = Task { try await client.popularVideos(regionCode: "JP") }
        try await Task.sleep(for: .milliseconds(10))
        cancelledWaiter.cancel()

        do {
            _ = try await cancelledWaiter.value
            XCTFail("The cancelled waiter must finish as cancelled")
        } catch is CancellationError {
            // Expected. The shared request remains alive for the other waiter.
        }
        let videos = try await remainingWaiter.value

        XCTAssertTrue(videos.isEmpty)
        XCTAssertEqual(requestCount.value, 1)
    }

    func testSharedRequestCancellationFailureCanBeRetried() async throws {
        let requestCount = LockedCounter()
        URLProtocolStub.handler = { request in
            requestCount.increment()
            if requestCount.value == 1 { throw URLError(.cancelled) }
            let payload = #"{"items":[]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        do {
            _ = try await client.popularVideos(regionCode: "JP")
            XCTFail("Expected the first shared request to be cancelled")
        } catch is CancellationError {
            // Expected. This cancellation originates in the shared request, not the caller.
        }

        let videos = try await client.popularVideos(regionCode: "JP")
        XCTAssertTrue(videos.isEmpty)
        XCTAssertEqual(requestCount.value, 2)
    }

    func testPlaylistRequestsAcrossDifferentPagesNeverExceedFourConcurrentCalls() async throws {
        let playlistRequests = LockedCounter()
        let concurrency = LockedConcurrencyTracker()
        URLProtocolStub.handler = { request in
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            let payload: String
            switch request.url?.path {
            case "/youtube/v3/subscriptions":
                let page = query?.first { $0.name == "pageToken" }?.value ?? "first"
                let items = (1...4).map {
                    #"{"snippet":{"resourceId":{"channelId":"channel-\#(page)-\#($0)"}}}"#
                }.joined(separator: ",")
                payload = "{\"items\":[\(items)]}"
            case "/youtube/v3/channels":
                let ids = (query?.first { $0.name == "id" }?.value ?? "").split(separator: ",")
                let items = ids.map {
                    #"{"contentDetails":{"relatedPlaylists":{"uploads":"uploads-\#($0)"}}}"#
                }.joined(separator: ",")
                payload = "{\"items\":[\(items)]}"
            case "/youtube/v3/playlistItems":
                playlistRequests.increment()
                concurrency.begin()
                defer { concurrency.end() }
                Thread.sleep(forTimeInterval: 0.05)
                payload = #"{"items":[]}"#
            default:
                throw URLError(.unsupportedURL)
            }
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

        async let first = client.subscriptionUploadsPage(pageToken: "page-a")
        async let second = client.subscriptionUploadsPage(pageToken: "page-b")
        _ = try await [first, second]

        XCTAssertEqual(playlistRequests.value, 8)
        XCTAssertLessThanOrEqual(concurrency.peak, 4)
    }

    func testTargetedSubscriptionRefreshDoesNotEvictPopularCache() async throws {
        let popularRequests = LockedCounter()
        let subscriptionRequests = LockedCounter()
        URLProtocolStub.handler = { request in
            switch request.url?.path {
            case "/youtube/v3/videos": popularRequests.increment()
            case "/youtube/v3/subscriptions": subscriptionRequests.increment()
            default: throw URLError(.unsupportedURL)
            }
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
            session: URLSession(configuration: configuration),
            manualRefreshCooldown: 0
        )

        _ = try await client.popularVideos(regionCode: "JP")
        _ = try await client.subscriptionUploadsPage(pageToken: nil)
        _ = try await client.subscriptionUploadsPage(pageToken: nil, forceRefresh: true)
        _ = try await client.popularVideos(regionCode: "JP")

        XCTAssertEqual(popularRequests.value, 1)
        XCTAssertEqual(subscriptionRequests.value, 2)
    }

    func testRepeatedManualRefreshWithinCooldownUsesCachedPage() async throws {
        let requestCount = LockedCounter()
        URLProtocolStub.handler = { request in
            requestCount.increment()
            let payload = #"{"items":[]}"#
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()

        _ = try await client.subscriptionUploadsPage(pageToken: nil)
        _ = try await client.subscriptionUploadsPage(pageToken: nil, forceRefresh: true)
        _ = try await client.subscriptionUploadsPage(pageToken: nil, forceRefresh: true)

        XCTAssertEqual(requestCount.value, 1)
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

    func testRefreshStatisticsBatchesFiftyOneIDsIntoFiftyAndOne() async throws {
        let batches = LockedStringArrays()
        URLProtocolStub.handler = { request in
            XCTAssertEqual(request.url?.path, "/youtube/v3/videos")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(query?.first { $0.name == "maxResults" }?.value, "50")
            let ids = (query?.first { $0.name == "id" }?.value ?? "")
                .split(separator: ",")
                .map(String.init)
            batches.append(ids)
            let items = ids.map {
                #"{"id":"\#($0)","snippet":{"title":"Video","channelTitle":"Channel","publishedAt":"2026-08-15T00:00:00Z","thumbnails":{}},"statistics":{"viewCount":"7"},"contentDetails":{"duration":"PT1M"}}"#
            }.joined(separator: ",")
            let payload = "{\"items\":[\(items)]}"
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data(payload.utf8))
        }
        let client = makeClient()
        let ids = (0..<51).map { String(format: "video%06d", $0) }

        let statistics = try await client.refreshStatistics(videoIDs: ids)

        XCTAssertEqual(batches.value.map(\.count), [50, 1])
        XCTAssertEqual(batches.value.flatMap { $0 }, ids)
        XCTAssertEqual(statistics.count, 51)
        XCTAssertTrue(statistics.values.allSatisfy { $0 == 7 })
    }

    private func makeClient(token: String? = "test-token") -> YouTubeDataClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [URLProtocolStub.self]
        let sessionID = UUID()
        return YouTubeDataClient(
            credentialProvider: {
                token.map {
                    YouTubeCredential(accessToken: $0, accountID: "test-account", sessionID: sessionID)
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

private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Date

    init(_ value: Date) { storage = value }
    var value: Date { lock.withLock { storage } }
    func advance(by interval: TimeInterval) {
        lock.withLock { storage = storage.addingTimeInterval(interval) }
    }
}

private final class LockedStringArrays: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String]] = []

    var value: [[String]] { lock.withLock { storage } }
    func append(_ value: [String]) { lock.withLock { storage.append(value) } }
}

private final class LockedConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var activeStorage = 0
    private var peakStorage = 0

    var peak: Int { lock.withLock { peakStorage } }

    func begin() {
        lock.withLock {
            activeStorage += 1
            peakStorage = max(peakStorage, activeStorage)
        }
    }

    func end() {
        lock.withLock { activeStorage -= 1 }
    }
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
