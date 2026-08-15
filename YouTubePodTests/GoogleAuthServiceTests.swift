import XCTest
@testable import YouTubePod

@MainActor
final class GoogleAuthServiceTests: XCTestCase {
    func testYouTubeReadOnlyScopeMustBeGrantedExactly() {
        let requiredScope = "https://www.googleapis.com/auth/youtube.readonly"

        XCTAssertFalse(GoogleAuthService.includesYouTubeReadOnlyScope(nil))
        XCTAssertFalse(GoogleAuthService.includesYouTubeReadOnlyScope([]))
        XCTAssertFalse(GoogleAuthService.includesYouTubeReadOnlyScope(["openid", "email"]))
        XCTAssertFalse(
            GoogleAuthService.includesYouTubeReadOnlyScope(
                ["https://www.googleapis.com/auth/youtube"]
            )
        )
        XCTAssertTrue(GoogleAuthService.includesYouTubeReadOnlyScope([requiredScope]))
        XCTAssertTrue(
            GoogleAuthService.includesYouTubeReadOnlyScope(
                ["openid", requiredScope, "email"]
            )
        )
    }
}
