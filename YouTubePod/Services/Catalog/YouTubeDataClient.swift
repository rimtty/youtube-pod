import Foundation
import OSLog

actor YouTubeDataClient: YouTubeCatalogServing {
    typealias CredentialProvider = @Sendable () async -> YouTubeCredential?
    typealias AuthenticationFailureHandler = @Sendable () async -> Void

    private let credentialProvider: CredentialProvider
    private let authenticationFailureHandler: AuthenticationFailureHandler
    private let session: URLSession
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: InFlightRequest] = [:]
    private let playlistRequestLimiter = AsyncRequestLimiter(limit: 4)
    private let cacheLifetime: TimeInterval = 15 * 60
    private let manualRefreshCooldown: TimeInterval
    private let logger = Logger(subsystem: "com.rimtty.YouTubePod", category: "YouTubeData")

    init(
        credentialProvider: @escaping CredentialProvider,
        authenticationFailureHandler: @escaping AuthenticationFailureHandler = {},
        session: URLSession = .shared,
        manualRefreshCooldown: TimeInterval = 60
    ) {
        self.credentialProvider = credentialProvider
        self.authenticationFailureHandler = authenticationFailureHandler
        self.session = session
        self.manualRefreshCooldown = manualRefreshCooldown
    }

    func popularVideos(regionCode: String = "JP", forceRefresh: Bool = false) async throws -> [VideoSummary] {
        let credential = try await requireCredential()
        return try await cached(
            "\(credential.accountID):\(credential.sessionID):popular:\(regionCode)",
            forceRefresh: forceRefresh
        ) {
            let response: VideoListResponse = try await self.request(
                "videos",
                query: [
                    "part": "snippet,statistics,contentDetails",
                    "chart": "mostPopular",
                    "regionCode": regionCode,
                    "maxResults": "20",
                ],
                credential: credential
            )
            return response.items.compactMap(\.summary)
        }
    }

    func searchVideos(query: String) async throws -> [VideoSummary] {
        let credential = try await requireCredential()
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return [] }
        let result: SearchListResponse = try await request(
            "search",
            query: [
                "part": "snippet",
                "q": cleaned,
                "type": "video",
                "maxResults": "25",
                "safeSearch": "moderate",
            ],
            credential: credential
        )
        return try await videoDetails(ids: result.items.map(\.id.videoID), credential: credential)
    }

    func subscriptionUploadsPage(
        pageToken: String?,
        forceRefresh: Bool = false
    ) async throws -> SubscriptionFeedPage {
        let credential = try await requireCredential()
        let pageKey = pageToken ?? "first"
        return try await cached(
            "\(credential.accountID):\(credential.sessionID):subscriptions:activity20:\(pageKey)",
            forceRefresh: forceRefresh
        ) {
            // Each subscribed channel requires its own uploads-playlist request.
            // Keep a page deliberately small and let the user request later pages.
            var query = [
                "part": "snippet",
                "mine": "true",
                "maxResults": "20",
                "order": "unread",
            ]
            if let pageToken { query["pageToken"] = pageToken }
            let subscriptions: SubscriptionListResponse = try await self.request(
                "subscriptions",
                query: query,
                credential: credential
            )
            let channelIDs = Array(Set(subscriptions.items.compactMap { $0.snippet?.resourceID?.channelID }))
            let uploads = try await self.uploadPlaylistIDs(channelIDs: channelIDs, credential: credential)
            var videoIDs: [String] = []
            for group in uploads.chunks(ofCount: 4) {
                let values = try await withThrowingTaskGroup(of: [String].self) { taskGroup in
                    for playlistID in group {
                        taskGroup.addTask {
                            try await self.uploadVideoIDs(playlistID: playlistID, credential: credential)
                        }
                    }
                    var result: [String] = []
                    for try await ids in taskGroup { result.append(contentsOf: ids) }
                    return result
                }
                videoIDs.append(contentsOf: values)
            }
            let details = try await self.videoDetails(ids: Array(Set(videoIDs)), credential: credential)
            return SubscriptionFeedPage(
                videos: details.sorted { $0.publishedAt > $1.publishedAt },
                nextPageToken: subscriptions.nextPageToken
            )
        }
    }

    func channelVideosPage(
        channelID: String,
        pageToken: String?,
        forceRefresh: Bool = false
    ) async throws -> ChannelVideoPage {
        let credential = try await requireCredential()
        let cleanedChannelID = channelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedChannelID.isEmpty else { throw CatalogError.invalidRequest }
        let pageKey = pageToken ?? "first"
        return try await cached(
            "\(credential.accountID):\(credential.sessionID):channel:\(cleanedChannelID):\(pageKey)",
            forceRefresh: forceRefresh
        ) {
            let channels: ChannelListResponse = try await self.request(
                "channels",
                query: [
                    "part": "contentDetails",
                    "id": cleanedChannelID,
                    "maxResults": "1",
                ],
                credential: credential
            )
            guard let uploadsPlaylistID = channels.items.first?.contentDetails?.relatedPlaylists?.uploads else {
                return ChannelVideoPage(videos: [], nextPageToken: nil)
            }
            var query = [
                "part": "contentDetails",
                "playlistId": uploadsPlaylistID,
                "maxResults": "25",
            ]
            if let pageToken { query["pageToken"] = pageToken }
            let playlistQuery = query
            let playlist: PlaylistItemListResponse = try await self.playlistRequestLimiter.withPermit {
                try await self.request(
                    "playlistItems",
                    query: playlistQuery,
                    credential: credential
                )
            }
            let videoIDs = playlist.items.compactMap { $0.contentDetails?.videoID }
            let videos = try await self.videoDetails(ids: videoIDs, credential: credential)
            return ChannelVideoPage(
                videos: videos.sorted { $0.publishedAt > $1.publishedAt },
                nextPageToken: playlist.nextPageToken
            )
        }
    }

    func refreshStatistics(videoIDs: [String]) async throws -> [String: Int64] {
        let credential = try await requireCredential()
        let videos = try await videoDetails(ids: videoIDs, credential: credential)
        return Dictionary(uniqueKeysWithValues: videos.map { ($0.id, $0.viewCount) })
    }

    func clearCache() {
        for request in inFlight.values { request.task.cancel() }
        inFlight.removeAll()
        cache.removeAll()
    }

    static func mergeUnique(_ groups: [[VideoSummary]]) -> [VideoSummary] {
        var seen = Set<String>()
        return groups.flatMap { $0 }
            .sorted { $0.publishedAt > $1.publishedAt }
            .filter { seen.insert($0.id).inserted }
    }

    private func uploadPlaylistIDs(
        channelIDs: [String],
        credential: YouTubeCredential
    ) async throws -> [String] {
        var result: [String] = []
        for batch in channelIDs.chunks(ofCount: 50) {
            let response: ChannelListResponse = try await request(
                "channels",
                query: ["part": "contentDetails", "id": batch.joined(separator: ","), "maxResults": "50"],
                credential: credential
            )
            result.append(contentsOf: response.items.compactMap { $0.contentDetails?.relatedPlaylists?.uploads })
        }
        return result
    }

    private func uploadVideoIDs(playlistID: String, credential: YouTubeCredential) async throws -> [String] {
        let response: PlaylistItemListResponse = try await playlistRequestLimiter.withPermit {
            try await self.request(
                "playlistItems",
                query: ["part": "contentDetails", "playlistId": playlistID, "maxResults": "3"],
                credential: credential
            )
        }
        return response.items.compactMap { $0.contentDetails?.videoID }
    }

    private func videoDetails(ids: [String], credential: YouTubeCredential) async throws -> [VideoSummary] {
        var result: [VideoSummary] = []
        for batch in ids.chunks(ofCount: 50) where !batch.isEmpty {
            let response: VideoListResponse = try await request(
                "videos",
                query: [
                    "part": "snippet,statistics,contentDetails",
                    "id": batch.joined(separator: ","),
                    "maxResults": "50",
                ],
                credential: credential
            )
            result.append(contentsOf: response.items.compactMap(\.summary))
        }
        return result
    }

    private func cached<T: Codable & Sendable>(
        _ key: String,
        forceRefresh: Bool,
        loader: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let now = Date()
        if forceRefresh, let entry = cache[key],
           now.timeIntervalSince(entry.date) < manualRefreshCooldown,
           let value = try? JSONDecoder.youtube.decode(T.self, from: entry.data) {
            return value
        }
        if forceRefresh { cache[key] = nil }
        if let entry = cache[key], now.timeIntervalSince(entry.date) < cacheLifetime,
           let value = try? JSONDecoder.youtube.decode(T.self, from: entry.data) {
            return value
        }
        if let request = inFlight[key] {
            return try await waitForSharedRequest(request, key: key, as: T.self)
        }

        let requestID = UUID()
        let task = Task<Data, Error> {
            let value = try await loader()
            return try JSONEncoder.youtube.encode(value)
        }
        let request = InFlightRequest(id: requestID, task: task, waiters: [])
        inFlight[key] = request
        return try await waitForSharedRequest(request, key: key, as: T.self)
    }

    private func waitForSharedRequest<T: Codable & Sendable>(
        _ request: InFlightRequest,
        key: String,
        as type: T.Type
    ) async throws -> T {
        let waiterID = UUID()
        if var current = inFlight[key], current.id == request.id {
            current.waiters.insert(waiterID)
            inFlight[key] = current
        }

        do {
            let data = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let data = try await request.task.value
                try Task.checkCancellation()
                return data
            } onCancel: {
                Task {
                    await self.cancelWaiter(
                        waiterID,
                        forKey: key,
                        requestID: request.id
                    )
                }
            }
            if inFlight[key]?.id == request.id {
                inFlight[key] = nil
                cache[key] = CacheEntry(date: .now, data: data)
            }
            return try JSONDecoder.youtube.decode(T.self, from: data)
        } catch {
            if var current = inFlight[key], current.id == request.id {
                current.waiters.remove(waiterID)
                if Task.isCancelled, !current.waiters.isEmpty {
                    inFlight[key] = current
                } else {
                    if Task.isCancelled { current.task.cancel() }
                    inFlight[key] = nil
                }
            }
            throw error
        }
    }

    private func cancelWaiter(_ waiterID: UUID, forKey key: String, requestID: UUID) {
        guard var request = inFlight[key], request.id == requestID else { return }
        request.waiters.remove(waiterID)
        if request.waiters.isEmpty {
            request.task.cancel()
            inFlight[key] = nil
        } else {
            inFlight[key] = request
        }
    }

    private func request<T: Decodable>(
        _ path: String,
        query: [String: String],
        credential: YouTubeCredential
    ) async throws -> T {
        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/\(path)")!
        components.queryItems = query.sorted { $0.key < $1.key }.map(URLQueryItem.init)
        guard let url = components.url else { throw CatalogError.invalidRequest }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue("Bearer \(credential.accessToken)", forHTTPHeaderField: "Authorization")
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw CatalogError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw CatalogError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = (try? JSONDecoder().decode(APIErrorEnvelope.self, from: data).error.message) ?? "HTTP \(http.statusCode)"
            if http.statusCode == 401 {
                await authenticationFailureHandler()
                throw CatalogError.authenticationRequired
            }
            if http.statusCode == 403 { throw CatalogError.quotaOrPermission(detail) }
            throw CatalogError.server(detail)
        }
        do {
            return try JSONDecoder.youtube.decode(T.self, from: data)
        } catch {
            let detail = Self.decodingDetail(error)
            logger.error("Decode failed for /\(path, privacy: .public): \(detail, privacy: .public)")
            throw CatalogError.decoding("\(path): \(detail)")
        }
    }

    private func requireCredential() async throws -> YouTubeCredential {
        guard let credential = await credentialProvider() else {
            throw CatalogError.authenticationRequired
        }
        return credential
    }

    private static func decodingDetail(_ error: Error) -> String {
        guard let decodingError = error as? DecodingError else { return error.localizedDescription }
        switch decodingError {
        case .keyNotFound(let key, let context):
            return "missing \(codingPath(context))\(key.stringValue)"
        case .valueNotFound(_, let context):
            return "null at \(codingPath(context))"
        case .typeMismatch(_, let context):
            return "type mismatch at \(codingPath(context))"
        case .dataCorrupted(let context):
            return "invalid data at \(codingPath(context))"
        @unknown default:
            return error.localizedDescription
        }
    }

    private static func codingPath(_ context: DecodingError.Context) -> String {
        let path = context.codingPath.map(\.stringValue).joined(separator: ".")
        return path.isEmpty ? "response." : "\(path)."
    }
}

enum CatalogError: LocalizedError {
    case authenticationRequired, invalidRequest, invalidResponse
    case quotaOrPermission(String), server(String), decoding(String), network(String)
    var errorDescription: String? {
        switch self {
        case .authenticationRequired: "Googleの認証が必要です。もう一度ログインしてください。"
        case .invalidRequest: "APIリクエストを作成できませんでした。"
        case .invalidResponse: "YouTubeから不正な応答を受信しました。"
        case .quotaOrPermission(let value): "APIの権限または利用上限を確認してください。\n\(value)"
        case .server(let value): value
        case .decoding(let value): "YouTubeデータを読み取れませんでした。\n\(value)"
        case .network(let value): "ネットワークに接続できませんでした。\n\(value)"
        }
    }
}

private struct CacheEntry { let date: Date; let data: Data }
private struct InFlightRequest {
    let id: UUID
    let task: Task<Data, Error>
    var waiters: Set<UUID>
}

private actor AsyncRequestLimiter {
    private let limit: Int
    private var availablePermits: Int
    private var waitingOrder: [UUID] = []
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]

    init(limit: Int) {
        precondition(limit > 0)
        self.limit = limit
        availablePermits = limit
    }

    func withPermit<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await acquire()
        defer { release() }
        try Task.checkCancellation()
        return try await operation()
    }

    private func acquire() async throws {
        try Task.checkCancellation()
        if availablePermits > 0 {
            availablePermits -= 1
            return
        }

        let waiterID = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[waiterID] = continuation
                waitingOrder.append(waiterID)
            }
            try Task.checkCancellation()
        } onCancel: {
            Task { await self.cancel(waiterID) }
        }
    }

    private func cancel(_ waiterID: UUID) {
        guard let continuation = waiters.removeValue(forKey: waiterID) else { return }
        waitingOrder.removeAll { $0 == waiterID }
        continuation.resume(throwing: CancellationError())
    }

    private func release() {
        while let waiterID = waitingOrder.first {
            waitingOrder.removeFirst()
            if let continuation = waiters.removeValue(forKey: waiterID) {
                continuation.resume()
                return
            }
        }
        availablePermits = min(limit, availablePermits + 1)
    }
}

private protocol PageResponse: Decodable {
    associatedtype Item: Decodable
    var items: [Item] { get }
    var nextPageToken: String? { get }
    init(items: [Item], nextPageToken: String?)
}

private struct SubscriptionListResponse: PageResponse {
    let items: [SubscriptionItem]
    let nextPageToken: String?
}
private struct SubscriptionItem: Decodable { let snippet: SubscriptionSnippet? }
private struct SubscriptionSnippet: Decodable {
    let resourceID: ResourceID?
    private enum CodingKeys: String, CodingKey { case resourceID = "resourceId" }
}
private struct ResourceID: Decodable {
    let channelID: String?
    private enum CodingKeys: String, CodingKey { case channelID = "channelId" }
}

private struct VideoListResponse: Decodable { let items: [VideoItem] }
private struct VideoItem: Decodable {
    let id: String
    let snippet: VideoSnippet?
    let statistics: VideoStatistics?
    let contentDetails: VideoContentDetails?
    var summary: VideoSummary? {
        guard let snippet,
              let title = snippet.title,
              let publishedAt = snippet.publishedAt else { return nil }
        return VideoSummary(
            id: id,
            title: title.decodingHTMLEntities,
            channelTitle: snippet.channelTitle ?? "不明なチャンネル",
            thumbnailURL: snippet.thumbnails?.best?.url,
            publishedAt: publishedAt,
            viewCount: Int64(statistics?.viewCount ?? "0") ?? 0,
            duration: contentDetails?.duration?.iso8601Duration ?? 0,
            channelID: snippet.channelID ?? "",
            broadcastStatus: YouTubeBroadcastStatus(rawValue: snippet.liveBroadcastContent ?? "none") ?? .none
        )
    }
}
private struct VideoSnippet: Decodable {
    let title: String?
    let channelTitle: String?
    let channelID: String?
    let publishedAt: Date?
    let thumbnails: Thumbnails?
    let liveBroadcastContent: String?

    private enum CodingKeys: String, CodingKey {
        case title, channelTitle, publishedAt, thumbnails, liveBroadcastContent
        case channelID = "channelId"
    }
}
private struct VideoStatistics: Decodable { let viewCount: String? }
private struct VideoContentDetails: Decodable { let duration: String? }
private struct Thumbnails: Decodable {
    let maxres: Thumbnail?
    let standard: Thumbnail?
    let high: Thumbnail?
    let medium: Thumbnail?
    let `default`: Thumbnail?
    var best: Thumbnail? { maxres ?? standard ?? high ?? medium ?? `default` }
}
private struct Thumbnail: Decodable { let url: URL }

private struct SearchListResponse: Decodable { let items: [SearchItem] }
private struct SearchItem: Decodable { let id: SearchID }
private struct SearchID: Decodable {
    let videoID: String
    private enum CodingKeys: String, CodingKey { case videoID = "videoId" }
}

private struct ChannelListResponse: Decodable { let items: [ChannelItem] }
private struct ChannelItem: Decodable { let contentDetails: ChannelContentDetails? }
private struct ChannelContentDetails: Decodable { let relatedPlaylists: RelatedPlaylists? }
private struct RelatedPlaylists: Decodable { let uploads: String? }

private struct PlaylistItemListResponse: PageResponse {
    let items: [PlaylistItem]
    let nextPageToken: String?
}
private struct PlaylistItem: Decodable { let contentDetails: PlaylistContentDetails? }
private struct PlaylistContentDetails: Decodable {
    let videoID: String?
    private enum CodingKeys: String, CodingKey { case videoID = "videoId" }
}

private struct APIErrorEnvelope: Decodable { let error: APIErrorDetail }
private struct APIErrorDetail: Decodable { let message: String }

private extension JSONDecoder {
    static var youtube: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

private extension JSONEncoder {
    static var youtube: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension String {
    var iso8601Duration: TimeInterval {
        guard let expression = try? NSRegularExpression(pattern: #"P(?:([0-9]+)D)?T?(?:([0-9]+)H)?(?:([0-9]+)M)?(?:([0-9]+)S)?"#),
              let match = expression.firstMatch(in: self, range: NSRange(startIndex..., in: self)) else { return 0 }
        func number(_ index: Int) -> Double {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: self) else { return 0 }
            return Double(self[range]) ?? 0
        }
        return number(1) * 86400 + number(2) * 3600 + number(3) * 60 + number(4)
    }

    var decodingHTMLEntities: String {
        guard let data = data(using: .utf8),
              let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
                documentAttributes: nil
              ) else { return self }
        return attributed.string
    }
}
