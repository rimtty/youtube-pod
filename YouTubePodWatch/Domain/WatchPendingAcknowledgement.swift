import Foundation
import SwiftData

enum WatchPendingAcknowledgementError: Error, Equatable, LocalizedError, Sendable {
    case invalidAcknowledgementID
    case invalidOutcome(String)

    var errorDescription: String? {
        switch self {
        case .invalidAcknowledgementID:
            "ACK outbox IDが正しくありません。"
        case .invalidOutcome:
            "ACKの結果が正しくありません。"
        }
    }
}

@Model
final class WatchPendingAcknowledgement {
    @Attribute(.unique) var acknowledgementID: UUID
    var transferID: UUID
    var revision: Int64
    var youtubeID: String
    var outcomeRawValue: String
    var errorCodeRawValue: String?
    var message: String?
    var createdAt: Date
    var attemptCount: Int

    init(
        acknowledgementID: UUID = UUID(),
        transferID: UUID,
        revision: Int64,
        youtubeID: String,
        outcome: WatchTransferAcknowledgementOutcome,
        errorCode: WatchTransferAcknowledgementErrorCode? = nil,
        message: String? = nil,
        createdAt: Date = .now,
        attemptCount: Int = 0
    ) {
        self.acknowledgementID = acknowledgementID
        self.transferID = transferID
        self.revision = revision
        self.youtubeID = youtubeID
        self.outcomeRawValue = outcome.rawValue
        self.errorCodeRawValue = errorCode?.rawValue
        self.message = message
        self.createdAt = createdAt
        self.attemptCount = attemptCount
    }

    var outcome: WatchTransferAcknowledgementOutcome? {
        get { WatchTransferAcknowledgementOutcome(rawValue: outcomeRawValue) }
        set {
            guard let newValue else { return }
            outcomeRawValue = newValue.rawValue
        }
    }

    var normalizedAttemptCount: Int {
        max(attemptCount, 0)
    }

    var errorCode: WatchTransferAcknowledgementErrorCode? {
        get { errorCodeRawValue.flatMap(WatchTransferAcknowledgementErrorCode.init(rawValue:)) }
        set { errorCodeRawValue = newValue?.rawValue }
    }

    func validatedAcknowledgement() throws -> WatchTransferAcknowledgement {
        guard acknowledgementID != Self.nilUUID else {
            throw WatchPendingAcknowledgementError.invalidAcknowledgementID
        }
        guard let outcome else {
            throw WatchPendingAcknowledgementError.invalidOutcome(outcomeRawValue)
        }
        return try WatchTransferAcknowledgement(
            transferID: transferID,
            revision: revision,
            youtubeID: youtubeID,
            outcome: outcome,
            errorCode: errorCode,
            message: message
        ).validated()
    }

    private static let nilUUID = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}
