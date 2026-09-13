import Foundation

struct WatchISOBaseMediaContainerSummary: Equatable, Sendable {
    private let boxCounts: [String: Int]

    init(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        guard let fileSize = values.fileSize, fileSize >= 8 else {
            throw WatchISOBaseMediaContainerError.invalidContainer
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var offset: UInt64 = 0
        var counts: [String: Int] = [:]
        let totalSize = UInt64(fileSize)
        while offset < totalSize {
            try handle.seek(toOffset: offset)
            guard let header = try handle.read(upToCount: 8), header.count == 8,
                  let type = String(data: header[4..<8], encoding: .ascii) else {
                throw WatchISOBaseMediaContainerError.invalidContainer
            }
            let compactSize = Self.uint32(header[0..<4])
            let headerSize: UInt64
            let boxSize: UInt64
            switch compactSize {
            case 0:
                headerSize = 8
                boxSize = totalSize - offset
            case 1:
                guard let extended = try handle.read(upToCount: 8), extended.count == 8 else {
                    throw WatchISOBaseMediaContainerError.invalidContainer
                }
                headerSize = 16
                boxSize = Self.uint64(extended[0..<8])
            default:
                headerSize = 8
                boxSize = UInt64(compactSize)
            }
            guard boxSize >= headerSize,
                  boxSize <= totalSize - offset else {
                throw WatchISOBaseMediaContainerError.invalidContainer
            }
            counts[type, default: 0] += 1
            offset += boxSize
        }
        guard offset == totalSize else {
            throw WatchISOBaseMediaContainerError.invalidContainer
        }
        boxCounts = counts
    }

    func count(of type: String) -> Int {
        boxCounts[type, default: 0]
    }

    private static func uint32(_ bytes: Data.SubSequence) -> UInt32 {
        bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func uint64(_ bytes: Data.SubSequence) -> UInt64 {
        bytes.reduce(0) { ($0 << 8) | UInt64($1) }
    }
}

enum WatchISOBaseMediaContainerError: Error {
    case invalidContainer
}

