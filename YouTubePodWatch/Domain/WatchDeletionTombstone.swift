import Foundation
import SwiftData

enum WatchDeletionTombstoneState: String, Codable, Sendable {
    case valid
    case invalidIdentity
    case invalidRevision
}

enum WatchDeletionDecision: String, Codable, Sendable {
    case rejectDeletedOrStale
    case acceptNewerRevision
}

@Model
final class WatchDeletionTombstone {
    @Attribute(.unique) var youtubeID: String
    var transferID: UUID
    var revision: Int64
    var deletedAt: Date

    init(
        youtubeID: String,
        transferID: UUID,
        revision: Int64,
        deletedAt: Date = .now
    ) {
        self.youtubeID = youtubeID
        self.transferID = transferID
        self.revision = revision
        self.deletedAt = deletedAt
    }

    var state: WatchDeletionTombstoneState {
        guard Self.isValidYouTubeID(youtubeID), transferID != Self.nilUUID else {
            return .invalidIdentity
        }
        guard revision >= 0 else { return .invalidRevision }
        return .valid
    }

    func decision(forIncomingRevision incomingRevision: Int64) -> WatchDeletionDecision {
        guard state == .valid, incomingRevision > revision else {
            return .rejectDeletedOrStale
        }
        return .acceptNewerRevision
    }

    func rejects(incomingRevision: Int64) -> Bool {
        decision(forIncomingRevision: incomingRevision) == .rejectDeletedOrStale
    }

    private static func isValidYouTubeID(_ value: String) -> Bool {
        let allowed = CharacterSet(
            charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-"
        )
        return value.unicodeScalars.count == 11
            && value.unicodeScalars.allSatisfy(allowed.contains)
    }

    private static let nilUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
