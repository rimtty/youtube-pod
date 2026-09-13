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
        #expect(throws: WatchTransferProtocolError.invalidContentDigest) {
            try fixture(contentSHA256: "not-a-digest").metadata()
        }
        #expect(throws: WatchTransferProtocolError.invalidValidationProfile) {
            try fixture(audioValidationProfile: .normalizedFlatM4A).metadata()
        }
    }

    @Test func normalizedAudioValidationMetadataRoundTrips() throws {
        let digest = String(repeating: "ab", count: 32)
        let envelope = fixture(
            contentSHA256: digest,
            audioValidationProfile: .normalizedFlatM4A
        )

        let decoded = try WatchTransferEnvelope.decode(metadata: envelope.metadata())

        #expect(decoded.contentSHA256 == digest)
        #expect(decoded.audioValidationProfile == .normalizedFlatM4A)
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
        let requestID = UUID(uuidString: "2E81163C-7343-43C3-A86F-B3100246CD30")!
        let snapshot = WatchInventorySnapshot(
            libraryInstanceID: UUID(uuidString: "E6722C37-252A-4EBE-8722-18FCE42E9708")!,
            generation: 7,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_100),
            availableCapacity: 1_000_000,
            respondingToRequestID: requestID,
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

    @Test func inventoryRequestApplicationContextRoundTripPreservesIdentity() throws {
        let request = WatchInventoryRequest(
            requestID: UUID(uuidString: "2E81163C-7343-43C3-A86F-B3100246CD30")!,
            requestedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )

        let decoded = try WatchInventoryRequest.decode(
            applicationContext: request.applicationContext()
        )

        #expect(decoded == request)
        #expect(throws: WatchTransferProtocolError.missingEnvelope) {
            try WatchInventoryRequest.decode(applicationContext: [:])
        }
    }

    @Test func pendingTransfersSummaryRoundTripsAndFailsClosed() throws {
        let summary = WatchPendingTransfersSummary(
            queuedCount: 1,
            transferringCount: 2,
            totalBytes: 98_765,
            activeYouTubeID: "dQw4w9WgXcQ",
            activeTitle: "Now sending",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_300)
        )

        let decoded = try WatchPendingTransfersSummary.decode(
            applicationContext: summary.applicationContext()
        )
        #expect(decoded == summary)
        #expect(throws: WatchTransferProtocolError.missingEnvelope) {
            try WatchPendingTransfersSummary.decode(applicationContext: [:])
        }
        #expect(throws: WatchTransferProtocolError.malformedPayload) {
            try WatchPendingTransfersSummary.decode(
                applicationContext: [WatchPendingTransfersSummary.applicationContextKey: Data("x".utf8)]
            )
        }
        #expect(throws: WatchTransferProtocolError.malformedPayload) {
            try WatchPendingTransfersSummary(queuedCount: -1, transferringCount: 0, totalBytes: 0, publishedAt: .now)
                .validated()
        }
        #expect(throws: WatchTransferProtocolError.invalidFileSize) {
            try WatchPendingTransfersSummary(queuedCount: 0, transferringCount: 0, totalBytes: -1, publishedAt: .now)
                .validated()
        }
        #expect(throws: WatchTransferProtocolError.invalidYouTubeID) {
            try WatchPendingTransfersSummary(
                queuedCount: 1, transferringCount: 0, totalBytes: 1, activeYouTubeID: "bad", publishedAt: .now
            ).validated()
        }
        #expect(throws: WatchTransferProtocolError.malformedPayload) {
            try WatchPendingTransfersSummary(
                queuedCount: 0, transferringCount: 0, totalBytes: 0, activeTitle: "Stale", publishedAt: .now
            ).validated()
        }
    }

    @Test func phoneApplicationContextCarriesBothPayloadsInOneDictionary() throws {
        let request = WatchInventoryRequest(
            requestID: UUID(),
            requestedAt: Date(timeIntervalSince1970: 1_700_000_200)
        )
        let summary = WatchPendingTransfersSummary.none(at: Date(timeIntervalSince1970: 1_700_000_201))

        let merged = try WatchPhoneApplicationContext(
            inventoryRequest: request,
            pendingTransfers: summary
        ).applicationContext()
        #expect(try WatchInventoryRequest.decode(applicationContext: merged) == request)
        #expect(try WatchPendingTransfersSummary.decode(applicationContext: merged) == summary)

        let summaryOnly = try WatchPhoneApplicationContext(
            inventoryRequest: nil,
            pendingTransfers: summary
        ).applicationContext()
        #expect(summaryOnly[WatchInventoryRequest.applicationContextKey] == nil)
        #expect(try WatchPendingTransfersSummary.decode(applicationContext: summaryOnly) == summary)
    }

    @Test func inventoryWithoutResponseCorrelationRemainsDecodable() throws {
        let legacyPayload = """
        {
          "schemaVersion": 1,
          "libraryInstanceID": "E6722C37-252A-4EBE-8722-18FCE42E9708",
          "generation": 7,
          "generatedAt": 1700000100000,
          "availableCapacity": 1000000,
          "entries": []
        }
        """.data(using: .utf8)!

        let decoded = try WatchInventorySnapshot.decode(applicationContext: [
            WatchInventorySnapshot.applicationContextKey: legacyPayload
        ])

        #expect(decoded.respondingToRequestID == nil)
        #expect(decoded.generation == 7)
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
        playbackPosition: TimeInterval = 92,
        contentSHA256: String? = nil,
        audioValidationProfile: WatchAudioValidationProfile? = nil
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
            playbackPosition: playbackPosition,
            contentSHA256: contentSHA256,
            audioValidationProfile: audioValidationProfile
        )
    }
}
