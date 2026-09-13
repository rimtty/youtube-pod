import Foundation

/// What iPhone still has to deliver to Apple Watch, published through the
/// WCSession application context so the Watch can tell the user to keep the
/// app open (watchOS throttles file transfers while the app is not frontmost).
///
/// The summary changes only on transfer state transitions, never on progress
/// callbacks; every change republishes the whole application context.
struct WatchPendingTransfersSummary: Codable, Equatable, Sendable {
    static let applicationContextKey = "com.rimtty.YouTubePod.watchPendingTransfers"

    let schemaVersion: Int
    let queuedCount: Int
    let transferringCount: Int
    /// Bytes of audio not yet delivered (queued plus transferring).
    let totalBytes: Int64
    let activeYouTubeID: String?
    let activeTitle: String?
    let publishedAt: Date

    init(
        schemaVersion: Int = WatchTransferEnvelope.currentSchemaVersion,
        queuedCount: Int,
        transferringCount: Int,
        totalBytes: Int64,
        activeYouTubeID: String? = nil,
        activeTitle: String? = nil,
        publishedAt: Date
    ) {
        self.schemaVersion = schemaVersion
        self.queuedCount = queuedCount
        self.transferringCount = transferringCount
        self.totalBytes = totalBytes
        self.activeYouTubeID = activeYouTubeID
        self.activeTitle = activeTitle
        self.publishedAt = publishedAt
    }

    static func none(at date: Date) -> Self {
        WatchPendingTransfersSummary(queuedCount: 0, transferringCount: 0, totalBytes: 0, publishedAt: date)
    }

    var pendingCount: Int { queuedCount + transferringCount }

    /// Equality that ignores `publishedAt`, used to skip redundant publishes.
    func hasSameContent(as other: Self) -> Bool {
        schemaVersion == other.schemaVersion
            && queuedCount == other.queuedCount
            && transferringCount == other.transferringCount
            && totalBytes == other.totalBytes
            && activeYouTubeID == other.activeYouTubeID
            && activeTitle == other.activeTitle
    }

    func validated() throws -> Self {
        guard schemaVersion == WatchTransferEnvelope.currentSchemaVersion else {
            throw WatchTransferProtocolError.unsupportedSchema(schemaVersion)
        }
        guard queuedCount >= 0, transferringCount >= 0 else {
            throw WatchTransferProtocolError.malformedPayload
        }
        guard totalBytes >= 0 else {
            throw WatchTransferProtocolError.invalidFileSize
        }
        if let activeYouTubeID {
            try validateYouTubeID(activeYouTubeID)
        }
        if let activeTitle,
           activeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw WatchTransferProtocolError.invalidTitle
        }
        if pendingCount == 0, activeYouTubeID != nil || activeTitle != nil {
            throw WatchTransferProtocolError.malformedPayload
        }
        return self
    }

    func applicationContext() throws -> [String: Any] {
        _ = try validated()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return [Self.applicationContextKey: try encoder.encode(self)]
    }

    static func decode(applicationContext: [String: Any]) throws -> Self {
        guard let payload = applicationContext[applicationContextKey] as? Data else {
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

/// Everything iPhone publishes with `WCSession.updateApplicationContext`.
///
/// `updateApplicationContext` replaces the counterpart's whole dictionary, so
/// the inventory request and the pending-transfers summary must always be
/// sent together; publishing one alone would erase the other.
struct WatchPhoneApplicationContext: Equatable, Sendable {
    var inventoryRequest: WatchInventoryRequest?
    var pendingTransfers: WatchPendingTransfersSummary

    func applicationContext() throws -> [String: Any] {
        var context = try pendingTransfers.applicationContext()
        if let inventoryRequest {
            context.merge(try inventoryRequest.applicationContext()) { current, _ in current }
        }
        return context
    }

    func hasSameContent(as other: Self) -> Bool {
        inventoryRequest == other.inventoryRequest
            && pendingTransfers.hasSameContent(as: other.pendingTransfers)
    }
}
