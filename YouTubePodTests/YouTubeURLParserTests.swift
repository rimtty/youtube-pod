import XCTest
@testable import YouTubePod

final class YouTubeURLParserTests: XCTestCase {
    private let videoID = "dQw4w9WgXcQ"

    func testParsesBareVideoIDAndTrimsWhitespace() {
        XCTAssertEqual(YouTubeURLParser.videoID(from: "  \(videoID)\n"), videoID)
    }

    func testParsesCanonicalWatchURL() {
        XCTAssertEqual(
            YouTubeURLParser.videoID(
                from: "https://www.youtube.com/watch?v=\(videoID)&feature=share"
            ),
            videoID
        )
    }

    func testParsesShortShareURL() {
        XCTAssertEqual(
            YouTubeURLParser.videoID(from: "https://youtu.be/\(videoID)?si=example"),
            videoID
        )
    }

    func testParsesShortsAndEmbedURLs() {
        XCTAssertEqual(
            YouTubeURLParser.videoID(from: "https://youtube.com/shorts/\(videoID)"),
            videoID
        )
        XCTAssertEqual(
            YouTubeURLParser.videoID(from: "https://www.youtube.com/embed/\(videoID)"),
            videoID
        )
    }

    func testRejectsUnsupportedInput() {
        XCTAssertNil(YouTubeURLParser.videoID(from: "not a video"))
        XCTAssertNil(YouTubeURLParser.videoID(from: "https://example.com/watch?v=\(videoID)"))
        XCTAssertNil(YouTubeURLParser.videoID(from: "https://youtube.com/channel/example"))
    }
}
