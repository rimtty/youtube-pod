import Foundation
import Testing
@testable import YouTubePodWatch

struct WatchTransferEnvelopeTests {
    @Test func metadataRoundTripPreservesAllFields() throws {
        let envelope = fixture()

        let decoded = try WatchTransferEnvelope.decode(metadata: envelope.metadata())

        #expect(decoded == envelope)
        #expect(decoded.normalizedPlaybackPosition == 92)
    }

    @Test func playbackPositionIsClampedForImport() {
        let envelope = fixture(playbackPosition: 900)

        #expect(envelope.normalizedPlaybackPosition == envelope.duration)
    }

    @Test func missingEnvelopeIsRejected() {
        #expect(throws: WatchTransferProtocolError.missingEnvelope) {
            try WatchTransferEnvelope.decode(metadata: [:])
        }
    }

    @Test func malformedEnvelopeIsRejected() {
        #expect(throws: WatchTransferProtocolError.malformedPayload) {
            try WatchTransferEnvelope.decode(
                metadata: [WatchTransferEnvelope.metadataKey: Data("not-json".utf8)]
            )
        }
    }

    @Test func unsupportedSchemaIsRejected() {
        let envelope = fixture(schemaVersion: 2)

        #expect(throws: WatchTransferProtocolError.unsupportedSchema(2)) {
            try envelope.metadata()
        }
    }

    @Test func invalidValuesAreRejectedBeforeTransfer() {
        #expect(throws: WatchTransferProtocolError.invalidRevision) {
            try fixture(revision: -1).metadata()
        }
        #expect(throws: WatchTransferProtocolError.invalidYouTubeID) {
            try fixture(youtubeID: "  ").metadata()
        }
        #expect(throws: WatchTransferProtocolError.invalidYouTubeID) {
            try fixture(youtubeID: "abcdefghij/").metadata()
        }
        #expect(throws: WatchTransferProtocolError.invalidYouTubeID) {
            try fixture(youtubeID: "あいうえおかきくけこさ").metadata()
        }
        #expect(throws: WatchTransferProtocolError.invalidDuration) {
            try fixture(duration: 0).metadata()
        }
        #expect(throws: WatchTransferProtocolError.invalidFileSize) {
            try fixture(fileSize: -1).metadata()
        }
        #expect(throws: WatchTransferProtocolError.invalidPlaybackPosition) {
            try fixture(playbackPosition: -.infinity).metadata()
        }
    }

    @Test func acknowledgementRoundTripPreservesIdentityAndOutcome() throws {
        let acknowledgement = WatchTransferAcknowledgement(
            transferID: UUID(uuidString: "D725B720-D653-4B75-9D9E-772352ABF5C8")!,
            revision: 3,
            youtubeID: "dQw4w9WgXcQ",
            outcome: .imported,
            message: nil
        )

        let decoded = try WatchTransferAcknowledgement.decode(
            userInfo: acknowledgement.userInfo()
        )

        #expect(decoded == acknowledgement)
    }

    @Test func malformedAcknowledgementIsRejected() {
        #expect(throws: WatchTransferProtocolError.malformedPayload) {
            try WatchTransferAcknowledgement.decode(
                userInfo: [WatchTransferAcknowledgement.userInfoKey: Data("not-json".utf8)]
            )
        }
    }

    @Test func invalidAcknowledgementIdentityIsRejected() {
        let acknowledgement = WatchTransferAcknowledgement(
            transferID: UUID(uuidString: "D725B720-D653-4B75-9D9E-772352ABF5C8")!,
            revision: -1,
            youtubeID: "not-valid",
            outcome: .failed
        )

        #expect(throws: WatchTransferProtocolError.invalidRevision) {
            try acknowledgement.userInfo()
        }
    }

    @Test func inventoryApplicationContextRoundTripPreservesIdentityAndGeneration() throws {
        let snapshot = WatchInventorySnapshot(
            libraryInstanceID: UUID(uuidString: "E6722C37-252A-4EBE-8722-18FCE42E9708")!,
            generation: 7,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            availableCapacity: 1_000_000,
            entries: [WatchInventoryEntry(
                youtubeID: "dQw4w9WgXcQ",
                transferID: UUID(uuidString: "D725B720-D653-4B75-9D9E-772352ABF5C8")!,
                revision: 3,
                fileSize: 8_192
            )]
        )

        let decoded = try WatchInventorySnapshot.decode(
            applicationContext: snapshot.applicationContext()
        )

        #expect(decoded == snapshot)
    }

    @Test func deletionCommandRoundTripPreservesRevision() throws {
        let command = WatchLibraryCommand(
            commandID: UUID(uuidString: "49F1BC3D-660B-4AC8-93F3-013454593FE3")!,
            kind: .delete,
            youtubeID: "dQw4w9WgXcQ",
            revision: 4
        )

        let decoded = try WatchLibraryCommand.decode(userInfo: command.userInfo())

        #expect(decoded == command)
    }

    @Test func invalidInventoryAndDeletionCommandFailClosed() {
        let snapshot = WatchInventorySnapshot(
            libraryInstanceID: UUID(),
            generation: -1,
            generatedAt: .now,
            availableCapacity: nil,
            entries: []
        )
        #expect(throws: WatchTransferProtocolError.malformedPayload) {
            try snapshot.applicationContext()
        }

        let command = WatchLibraryCommand(
            commandID: UUID(),
            kind: .delete,
            youtubeID: "invalid",
            revision: 1
        )
        #expect(throws: WatchTransferProtocolError.invalidYouTubeID) {
            try command.userInfo()
        }
    }

    private func fixture(
        schemaVersion: Int = WatchTransferEnvelope.currentSchemaVersion,
        revision: Int64 = 3,
        youtubeID: String = "dQw4w9WgXcQ",
        duration: TimeInterval = 245,
        fileSize: Int64 = 8_192,
        playbackPosition: TimeInterval = 92
    ) -> WatchTransferEnvelope {
        WatchTransferEnvelope(
            schemaVersion: schemaVersion,
            transferID: UUID(uuidString: "D725B720-D653-4B75-9D9E-772352ABF5C8")!,
            revision: revision,
            fileKind: .audio,
            youtubeID: youtubeID,
            title: "Watch transfer test",
            channel: "YouTube Pod",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000),
            viewCount: 1_234,
            duration: duration,
            fileSize: fileSize,
            playbackPosition: playbackPosition
        )
    }
}
