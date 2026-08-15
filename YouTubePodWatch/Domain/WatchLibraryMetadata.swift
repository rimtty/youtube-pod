import Foundation
import SwiftData

@Model
final class WatchLibraryMetadata {
    @Attribute(.unique) var key: String
    var libraryInstanceID: UUID
    var generation: Int64
    var updatedAt: Date

    init(
        key: String = "primary",
        libraryInstanceID: UUID = UUID(),
        generation: Int64 = 0,
        updatedAt: Date = .now
    ) {
        self.key = key
        self.libraryInstanceID = libraryInstanceID
        self.generation = generation
        self.updatedAt = updatedAt
    }

    func advanceGeneration(at date: Date = .now) {
        generation = max(0, generation) + 1
        updatedAt = date
    }
}
