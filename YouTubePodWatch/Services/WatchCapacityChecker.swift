import Foundation

protocol WatchCapacityChecking: Sendable {
    func ensureImportCapacity(
        at libraryURL: URL,
        stagedFileSize: Int64,
        minimumReserve: Int64
    ) async throws
}

struct FileSystemWatchCapacityChecker: WatchCapacityChecking {
    func ensureImportCapacity(
        at libraryURL: URL,
        stagedFileSize: Int64,
        minimumReserve: Int64
    ) async throws {
        guard stagedFileSize >= 0, minimumReserve >= 0 else {
            throw WatchCapacityError.invalidRequirement
        }
        let attributes = try FileManager.default.attributesOfFileSystem(
            forPath: libraryURL.path
        )
        guard let freeSize = attributes[.systemFreeSize] as? NSNumber else {
            throw WatchCapacityError.capacityUnavailable
        }
        let available = freeSize.int64Value
        // Keep the durable inbox receipt until SwiftData commits. The short
        // overlap with the immutable library copy closes the process-death
        // window between filesystem installation and database persistence.
        let (required, overflow) = stagedFileSize.addingReportingOverflow(minimumReserve)
        guard !overflow, available > required else {
            throw WatchCapacityError.insufficientStorage(
                requiredReserve: overflow ? Int64.max : required,
                available: available
            )
        }
    }
}

enum WatchCapacityError: LocalizedError, Equatable, Sendable {
    case invalidRequirement
    case capacityUnavailable
    case insufficientStorage(requiredReserve: Int64, available: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidRequirement:
            "必要な空き容量を計算できませんでした。"
        case .capacityUnavailable:
            "Apple Watchの空き容量を取得できませんでした。"
        case .insufficientStorage:
            "Apple Watchの空き容量が不足しています。"
        }
    }
}
