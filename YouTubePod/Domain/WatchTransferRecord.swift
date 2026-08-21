import Foundation
import SwiftData

enum WatchTransferState: String, Codable, CaseIterable, Sendable {
    case preparing
    case queued
    case transferring
    case awaitingWatchConfirmation
    case availableOnWatch
    case cancelling
    case deletionPending
    case failed
    case reconciliationRequired
    case removedFromWatch

    var isPendingTransfer: Bool {
        switch self {
        case .preparing, .queued, .transferring, .awaitingWatchConfirmation:
            true
        case .availableOnWatch, .cancelling, .deletionPending, .failed,
             .reconciliationRequired, .removedFromWatch:
            false
        }
    }
}

@Model
final class WatchTransferRecord {
    @Attribute(.unique) var youtubeID: String
    var title: String
    var channelTitle: String
    var publishedAt: Date
    var duration: TimeInterval
    var savedViewCount: Int64
    var sourceFileSize: Int64
    var playbackPosition: TimeInterval
    @Attribute(.unique) var transferID: UUID
    var revision: Int64
    var stateRawValue: String
    var lastKnownProgress: Double
    var artworkExpected: Bool
    var audioDeliveryFinished: Bool
    var artworkDeliveryFinished: Bool
    var senderFailed: Bool
    var watchImportConfirmed: Bool
    var watchImportFailed: Bool
    var queuedAt: Date
    var updatedAt: Date
    var confirmedAt: Date?
    var retryCount: Int
    var lastErrorCode: String?
    var lastErrorMessage: String?

    init(
        youtubeID: String,
        title: String,
        channelTitle: String,
        publishedAt: Date,
        duration: TimeInterval,
        savedViewCount: Int64,
        sourceFileSize: Int64,
        playbackPosition: TimeInterval = 0,
        transferID: UUID = UUID(),
        revision: Int64 = 0,
        state: WatchTransferState = .preparing,
        lastKnownProgress: Double = 0,
        artworkExpected: Bool = false,
        audioDeliveryFinished: Bool = false,
        artworkDeliveryFinished: Bool = false,
        senderFailed: Bool = false,
        watchImportConfirmed: Bool = false,
        watchImportFailed: Bool = false,
        queuedAt: Date = .now,
        updatedAt: Date = .now,
        confirmedAt: Date? = nil,
        retryCount: Int = 0,
        lastErrorCode: String? = nil,
        lastErrorMessage: String? = nil
    ) {
        self.youtubeID = youtubeID
        self.title = title
        self.channelTitle = channelTitle
        self.publishedAt = publishedAt
        self.duration = duration
        self.savedViewCount = savedViewCount
        self.sourceFileSize = sourceFileSize
        self.playbackPosition = playbackPosition
        self.transferID = transferID
        self.revision = revision
        self.stateRawValue = state.rawValue
        self.lastKnownProgress = lastKnownProgress
        self.artworkExpected = artworkExpected
        self.audioDeliveryFinished = audioDeliveryFinished
        self.artworkDeliveryFinished = artworkDeliveryFinished
        self.senderFailed = senderFailed
        self.watchImportConfirmed = watchImportConfirmed
        self.watchImportFailed = watchImportFailed
        self.queuedAt = queuedAt
        self.updatedAt = updatedAt
        self.confirmedAt = confirmedAt
        self.retryCount = retryCount
        self.lastErrorCode = lastErrorCode
        self.lastErrorMessage = lastErrorMessage
    }

    var state: WatchTransferState {
        get { WatchTransferState(rawValue: stateRawValue) ?? .reconciliationRequired }
        set { stateRawValue = newValue.rawValue }
    }
}
