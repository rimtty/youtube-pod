import Foundation

enum WatchTransferFileKind: String, Codable, CaseIterable, Sendable {
    case audio
    case artwork
}

enum WatchTransferAcknowledgementOutcome: String, Codable, Sendable {
    case imported
    case failed
    case deleted
}

enum WatchTransferProtocolError: Error, Equatable, LocalizedError, Sendable {
    case missingEnvelope
    case unsupportedSchema(Int)
    case invalidTransferID
    case invalidRevision
    case invalidYouTubeID
    case invalidTitle
    case invalidDuration
    case invalidFileSize
    case invalidPlaybackPosition
    case malformedPayload

    var errorDescription: String? {
        switch self {
        case .missingEnvelope:
            "転送メタデータがありません。"
        case let .unsupportedSchema(version):
            "未対応の転送形式です（version: \(version)）。"
        case .invalidTransferID:
            "転送IDが正しくありません。"
        case .invalidRevision:
            "転送revisionが正しくありません。"
        case .invalidYouTubeID:
            "YouTube IDが正しくありません。"
        case .invalidTitle:
            "タイトルがありません。"
        case .invalidDuration:
            "再生時間が正しくありません。"
        case .invalidFileSize:
            "ファイルサイズが正しくありません。"
        case .invalidPlaybackPosition:
            "再生位置が正しくありません。"
        case .malformedPayload:
            "転送メタデータを読み取れません。"
        }
    }
}

struct WatchTransferEnvelope: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1
    static let metadataKey = "com.rimtty.YouTubePod.watchTransferEnvelope"

    let schemaVersion: Int
    let transferID: UUID
    let revision: Int64
    let fileKind: WatchTransferFileKind
    let youtubeID: String
    let title: String
    let channel: String
    let publishedAt: Date?
    let viewCount: Int64
    let duration: TimeInterval
    let fileSize: Int64
    let playbackPosition: TimeInterval

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        transferID: UUID,
        revision: Int64,
        fileKind: WatchTransferFileKind,
        youtubeID: String,
        title: String,
        channel: String,
        publishedAt: Date?,
        viewCount: Int64,
        duration: TimeInterval,
        fileSize: Int64,
        playbackPosition: TimeInterval
    ) {
        self.schemaVersion = schemaVersion
        self.transferID = transferID
        self.revision = revision
        self.fileKind = fileKind
        self.youtubeID = youtubeID
        self.title = title
        self.channel = channel
        self.publishedAt = publishedAt
        self.viewCount = viewCount
        self.duration = duration
        self.fileSize = fileSize
        self.playbackPosition = playbackPosition
    }

    var normalizedPlaybackPosition: TimeInterval {
        min(max(playbackPosition, 0), duration)
    }

    func validated() throws -> Self {
        guard schemaVersion == Self.currentSchemaVersion else {
            throw WatchTransferProtocolError.unsupportedSchema(schemaVersion)
        }
        guard transferID != UUID.nil else {
            throw WatchTransferProtocolError.invalidTransferID
        }
        guard revision >= 0 else {
            throw WatchTransferProtocolError.invalidRevision
        }
        let youtubeIDScalars = youtubeID.unicodeScalars
        let allowedYouTubeIDScalars = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        )
        guard youtubeIDScalars.count == 11,
              youtubeIDScalars.allSatisfy(allowedYouTubeIDScalars.contains)
        else {
            throw WatchTransferProtocolError.invalidYouTubeID
        }
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw WatchTransferProtocolError.invalidTitle
        }
        guard duration.isFinite, duration > 0 else {
            throw WatchTransferProtocolError.invalidDuration
        }
        guard fileSize >= 0 else {
            throw WatchTransferProtocolError.invalidFileSize
        }
        guard playbackPosition.isFinite, playbackPosition >= 0 else {
            throw WatchTransferProtocolError.invalidPlaybackPosition
        }
        return self
    }

    func metadata() throws -> [String: Any] {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return [Self.metadataKey: try encoder.encode(self)]
    }

    static func decode(metadata: [String: Any]) throws -> Self {
        guard let payload = metadata[metadataKey] as? Data else {
            throw WatchTransferProtocolError.missingEnvelope
        }

        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(Self.self, from: payload).validated()
        } catch let error as WatchTransferProtocolError {
            throw error
        } catch {
            throw WatchTransferProtocolError.malformedPayload
        }
    }
}

struct WatchTransferAcknowledgement: Codable, Equatable, Sendable {
    static let userInfoKey = "com.rimtty.YouTubePod.watchTransferAcknowledgement"

    let schemaVersion: Int
    let transferID: UUID
    let revision: Int64
    let youtubeID: String
    let outcome: WatchTransferAcknowledgementOutcome
    let message: String?

    init(
        schemaVersion: Int = WatchTransferEnvelope.currentSchemaVersion,
        transferID: UUID,
        revision: Int64,
        youtubeID: String,
        outcome: WatchTransferAcknowledgementOutcome,
        message: String? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.transferID = transferID
        self.revision = revision
        self.youtubeID = youtubeID
        self.outcome = outcome
        self.message = message
    }

    func validated() throws -> Self {
        guard schemaVersion == WatchTransferEnvelope.currentSchemaVersion else {
            throw WatchTransferProtocolError.unsupportedSchema(schemaVersion)
        }
        guard transferID != UUID.nil else {
            throw WatchTransferProtocolError.invalidTransferID
        }
        guard revision >= 0 else {
            throw WatchTransferProtocolError.invalidRevision
        }
        try validateYouTubeID(youtubeID)
        return self
    }

    func userInfo() throws -> [String: Any] {
        _ = try validated()
        return [Self.userInfoKey: try JSONEncoder().encode(self)]
    }

    static func decode(userInfo: [String: Any]) throws -> Self {
        guard let payload = userInfo[userInfoKey] as? Data else {
            throw WatchTransferProtocolError.missingEnvelope
        }
        do {
            return try JSONDecoder().decode(Self.self, from: payload).validated()
        } catch let error as WatchTransferProtocolError {
            throw error
        } catch {
            throw WatchTransferProtocolError.malformedPayload
        }
    }
}

struct WatchInventoryEntry: Codable, Equatable, Sendable {
    let youtubeID: String
    let revision: Int64
    let fileSize: Int64
}

struct WatchInventorySnapshot: Codable, Equatable, Sendable {
    let schemaVersion: Int
    let generatedAt: Date
    let availableCapacity: Int64?
    let entries: [WatchInventoryEntry]

    init(
        schemaVersion: Int = WatchTransferEnvelope.currentSchemaVersion,
        generatedAt: Date,
        availableCapacity: Int64?,
        entries: [WatchInventoryEntry]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.availableCapacity = availableCapacity
        self.entries = entries
    }
}

private extension UUID {
    static let `nil` = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
}

private func validateYouTubeID(_ youtubeID: String) throws {
    let scalars = youtubeID.unicodeScalars
    let allowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
    )
    guard scalars.count == 11, scalars.allSatisfy(allowed.contains) else {
        throw WatchTransferProtocolError.invalidYouTubeID
    }
}
