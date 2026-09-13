import CryptoKit
import Foundation

enum WatchFileDigest {
    private static let chunkSize = 256 * 1_024

    static func sha256(at url: URL) throws -> String {
        try sha256(at: url, progress: { _ in })
    }

    /// `progress` receives the fraction of bytes hashed so far (0...1) and is
    /// called at most once per chunk.
    static func sha256(at url: URL, progress: (Double) -> Void) throws -> String {
        let totalBytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Double.init) ?? 0
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var hashedBytes = 0.0
        while let data = try handle.read(upToCount: chunkSize), !data.isEmpty {
            hasher.update(data: data)
            hashedBytes += Double(data.count)
            if totalBytes > 0 {
                progress(min(hashedBytes / totalBytes, 1))
            }
        }
        progress(1)
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func isValidSHA256(_ value: String) -> Bool {
        value.unicodeScalars.count == 64
            && value.unicodeScalars.allSatisfy {
                CharacterSet(charactersIn: "0123456789abcdef").contains($0)
            }
    }
}

