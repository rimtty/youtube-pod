import Foundation
import Testing
@testable import YouTubePodWatch

struct WatchPeerSyncServiceTests {
    @Test func audioStagingFailureProducesRetryableAcknowledgement() throws {
        let envelope = makeEnvelope(kind: .audio)
        let metadata = try envelope.metadata()

        let userInfo = WatchWCSessionPeerSyncService.stagingFailureUserInfo(
            metadata: metadata,
            message: "staging failed"
        )
        let acknowledgement = try WatchTransferAcknowledgement.decode(
            userInfo: #require(userInfo)
        )

        #expect(acknowledgement.transferID == envelope.transferID)
        #expect(acknowledgement.youtubeID == envelope.youtubeID)
        #expect(acknowledgement.outcome == .failed)
        #expect(acknowledgement.errorCode == .stagingFailure)
    }

    @Test func artworkStagingFailureIsNonTerminal() throws {
        let envelope = makeEnvelope(kind: .artwork)
        let metadata = try envelope.metadata()

        #expect(WatchWCSessionPeerSyncService.stagingFailureUserInfo(
            metadata: metadata,
            message: "optional artwork failed"
        ) == nil)
    }

    @Test func malformedStagingMetadataCannotBeAcknowledged() {
        #expect(WatchWCSessionPeerSyncService.stagingFailureUserInfo(
            metadata: [:],
            message: "missing identity"
        ) == nil)
    }

    private func makeEnvelope(kind: WatchTransferFileKind) -> WatchTransferEnvelope {
        WatchTransferEnvelope(
            transferID: UUID(),
            revision: 1,
            fileKind: kind,
            youtubeID: "dQw4w9WgXcQ",
            title: "Title",
            channel: "Channel",
            publishedAt: nil,
            viewCount: 1,
            duration: 60,
            fileSize: 64,
            playbackPosition: 0
        )
    }
}
