import SwiftUI

struct AccountSettingsView: View {
    let displayName: String?
    let email: String?
    let profileImageURL: URL?
    let librarySize: String
    let signOut: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var confirmsSignOut = false

    var body: some View {
        NavigationStack {
            List {
                accountSection
                storageSection
                noticeSection
                aboutSection
            }
            .navigationTitle("アカウントと設定")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .confirmationDialog("Googleアカウントからログアウトしますか？", isPresented: $confirmsSignOut) {
                Button("ログアウト", role: .destructive) {
                    dismiss()
                    signOut()
                }
                Button("キャンセル", role: .cancel) {}
            } message: {
                Text("保存済みの音声は削除されません。")
            }
        }
    }

    private var accountSection: some View {
        Section("YouTubeアカウント") {
            HStack(spacing: 14) {
                PodAccountAvatar(
                    imageURL: profileImageURL,
                    displayName: displayName ?? "Googleユーザー",
                    size: 48
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 3) {
                    Text(displayName ?? "Googleユーザー")
                        .font(.headline)
                    if let email {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .accessibilityElement(children: .combine)

            Label("YouTube情報は読み取り専用です", systemImage: "checkmark.shield.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Button("ログアウト", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                confirmsSignOut = true
            }
        }
    }

    private var storageSection: some View {
        Section("端末内のデータ") {
            LabeledContent("保存した音声", value: librarySize)
            Label("ログアウトしても音声とサムネイルは残ります", systemImage: "iphone.gen3")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var noticeSection: some View {
        Section("技術検証について") {
            Label {
                Text("このアプリは開発署名による技術検証専用です。App Store配布を目的としていません。")
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            Label("公開済み・M4A音声を提供する動画だけに対応します", systemImage: "checkmark.shield")
            Label("取得処理はフォアグラウンド中だけ動作します", systemImage: "sun.max")
        }
        .font(.subheadline)
    }

    private var aboutSection: some View {
        Section("このアプリについて") {
            HStack(spacing: 14) {
                PodBrandMark(size: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text("YouTube Pod")
                        .font(.headline)
                    Text("バージョン 0.1.0 · PoC")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}
