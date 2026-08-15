import Foundation
@preconcurrency import GoogleSignIn
import Observation
import UIKit

enum AuthenticationPhase: Equatable {
    case restoring
    case signedOut
    case signingIn
    case signedIn
    case authorizationRequired
    case failed(String)
}

@MainActor
@Observable
final class GoogleAuthService: @unchecked Sendable {
    private(set) var phase: AuthenticationPhase = .restoring
    private(set) var displayName = "ゲスト"
    private(set) var email = ""
    private(set) var profileImageURL: URL?
    private(set) var sessionID = UUID()
    private var accountID = ""

    private let readOnlyScope = "https://www.googleapis.com/auth/youtube.readonly"

    var isSignedIn: Bool { phase == .signedIn }
    var isWorking: Bool { phase == .restoring || phase == .signingIn }
    var failureMessage: String? {
        switch phase {
        case .authorizationRequired:
            "登録チャンネルを読み取る権限が必要です。Googleでもう一度許可してください。"
        case .failed(let message):
            message
        default:
            nil
        }
    }
    var isConfigured: Bool {
        let clientID = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String ?? ""
        return !clientID.isEmpty && !clientID.contains("REPLACE_ME")
    }

    func restore() async {
        phase = .restoring
        guard isConfigured else {
            clearUser(phase: .signedOut)
            return
        }
        do {
            let user = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
            guard Self.includesYouTubeReadOnlyScope(user.grantedScopes) else {
                applyProfile(user)
                phase = .authorizationRequired
                return
            }
            applySignedInUser(user)
        } catch {
            clearUser(phase: .signedOut)
        }
    }

    func signIn() async throws {
        guard isConfigured else {
            throw AuthError.notConfigured
        }
        guard let presenter = Self.presentingViewController() else {
            throw AuthError.noPresenter
        }
        phase = .signingIn
        do {
            let user: GIDGoogleUser
            if let currentUser = GIDSignIn.sharedInstance.currentUser,
               !Self.includesYouTubeReadOnlyScope(currentUser.grantedScopes) {
                let result = try await currentUser.addScopes(
                    [readOnlyScope],
                    presenting: presenter
                )
                user = result.user
            } else {
                let result = try await GIDSignIn.sharedInstance.signIn(
                    withPresenting: presenter,
                    hint: nil,
                    additionalScopes: [readOnlyScope]
                )
                user = result.user
            }
            guard Self.includesYouTubeReadOnlyScope(user.grantedScopes) else {
                applyProfile(user)
                phase = .authorizationRequired
                throw AuthError.requiredScopeNotGranted
            }
            applySignedInUser(user)
        } catch {
            if case AuthError.requiredScopeNotGranted = error {
                phase = .authorizationRequired
                throw error
            }
            let nsError = error as NSError
            if nsError.domain == kGIDSignInErrorDomain && nsError.code == -5 {
                phase = .signedOut
            } else {
                phase = .failed(error.localizedDescription)
            }
            throw error
        }
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        clearUser(phase: .signedOut)
    }

    func validCredential() async -> YouTubeCredential? {
        guard isSignedIn,
              let user = GIDSignIn.sharedInstance.currentUser else { return nil }
        guard Self.includesYouTubeReadOnlyScope(user.grantedScopes) else {
            applyProfile(user)
            phase = .authorizationRequired
            return nil
        }
        do {
            let refreshed = try await user.refreshTokensIfNeeded()
            guard Self.includesYouTubeReadOnlyScope(refreshed.grantedScopes) else {
                applyProfile(refreshed)
                phase = .authorizationRequired
                return nil
            }
            return credential(for: refreshed)
        } catch {
            guard let expirationDate = user.accessToken.expirationDate,
                  expirationDate > Date().addingTimeInterval(30) else {
                invalidateSession()
                return nil
            }
            return credential(for: user)
        }
    }

    func invalidateSession() {
        GIDSignIn.sharedInstance.signOut()
        clearUser(phase: .failed("Googleの認証期限が切れました。もう一度ログインしてください。"))
    }

    static func includesYouTubeReadOnlyScope(_ scopes: [String]?) -> Bool {
        scopes?.contains("https://www.googleapis.com/auth/youtube.readonly") == true
    }

    private func applySignedInUser(_ user: GIDGoogleUser) {
        applyProfile(user)
        phase = .signedIn
    }

    private func applyProfile(_ user: GIDGoogleUser) {
        displayName = user.profile?.name ?? "YouTubeユーザー"
        email = user.profile?.email ?? ""
        profileImageURL = user.profile?.imageURL(withDimension: 160)
        accountID = user.userID ?? email
        sessionID = UUID()
    }

    private func clearUser(phase: AuthenticationPhase) {
        displayName = "ゲスト"
        email = ""
        profileImageURL = nil
        accountID = ""
        sessionID = UUID()
        self.phase = phase
    }

    private func credential(for user: GIDGoogleUser) -> YouTubeCredential {
        YouTubeCredential(
            accessToken: user.accessToken.tokenString,
            accountID: accountID,
            sessionID: sessionID
        )
    }

    private static func presentingViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let root = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        var presenter = root
        while let presented = presenter?.presentedViewController { presenter = presented }
        return presenter
    }
}

private enum AuthError: LocalizedError {
    case noUser, notConfigured, noPresenter, requiredScopeNotGranted
    var errorDescription: String? {
        switch self {
        case .noUser: "Googleアカウントを取得できませんでした。"
        case .notConfigured: "Config/Secrets.xcconfig にGoogle Client IDを設定してください。"
        case .noPresenter: "ログイン画面を表示できませんでした。"
        case .requiredScopeNotGranted: "YouTubeの読み取り権限が許可されませんでした。"
        }
    }
}
