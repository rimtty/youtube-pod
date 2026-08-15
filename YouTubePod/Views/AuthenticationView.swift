import SwiftUI

struct AuthenticationRestoringView: View {
    var body: some View {
        ZStack {
            PodScreenBackground()
            VStack(spacing: 22) {
                PodBrandMark(size: 92)
                ProgressView()
                    .controlSize(.large)
                    .tint(PodPalette.violet)
                Text("Googleアカウントを確認しています")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            .padding(36)
        }
        .accessibilityElement(children: .combine)
    }
}

struct AuthenticationView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @State private var isAnimatingWaveform = false

    let savedAudioCount: Int
    let openOfflineLibrary: () -> Void

    var body: some View {
        ZStack {
            PodScreenBackground()
            decorativeBackground

            ScrollView {
                VStack(spacing: 28) {
                    brandHeader
                    hero
                    benefits
                    if let message = environment.auth.failureMessage {
                        failureCard(message)
                    }
                    if !environment.auth.isConfigured {
                        configurationCard
                    }
                    privacyNote
                }
                .frame(maxWidth: 680)
                .padding(.horizontal, 22)
                .padding(.top, 24)
                .padding(.bottom, 176)
                .frame(maxWidth: .infinity)
            }
        }
        .safeAreaInset(edge: .bottom) {
            signInPanel
        }
        .onAppear { isAnimatingWaveform = !reduceMotion }
    }

    private var decorativeBackground: some View {
        GeometryReader { proxy in
            Circle()
                .fill(PodPalette.raspberry.opacity(0.12))
                .frame(width: min(proxy.size.width * 0.72, 420))
                .blur(radius: 8)
                .offset(x: proxy.size.width * 0.55, y: -90)

            Circle()
                .fill(PodPalette.sky.opacity(0.16))
                .frame(width: min(proxy.size.width * 0.65, 360))
                .blur(radius: 12)
                .offset(x: -proxy.size.width * 0.24, y: proxy.size.height * 0.55)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private var brandHeader: some View {
        HStack(spacing: 12) {
            PodBrandMark(size: 46)
            VStack(alignment: .leading, spacing: 1) {
                Text("YouTube Pod")
                    .font(.headline.bold())
                Text("動画を、聴く時間に。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("PoC")
                .font(.caption2.bold())
                .foregroundStyle(PodPalette.violet)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(PodPalette.violet.opacity(0.10), in: Capsule())
        }
    }

    private var hero: some View {
        VStack(spacing: 20) {
            ZStack {
                RoundedRectangle(cornerRadius: 42, style: .continuous)
                    .fill(
                        reduceTransparency || colorScheme == .dark
                            ? Color(.secondarySystemBackground)
                            : .white.opacity(0.76)
                    )
                    .strokeBorder(.white.opacity(0.84))
                    .shadow(color: PodPalette.sky.opacity(0.18), radius: 28, y: 15)

                VStack(spacing: 17) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 58, weight: .black))
                        .foregroundStyle(PodPalette.brandGradient)
                    ListeningWaveform(isAnimating: isAnimatingWaveform)
                }
            }
            .frame(height: dynamicTypeSize.isAccessibilitySize ? 230 : 205)

            VStack(spacing: 10) {
                Text("聴きたい動画を、\nあとでゆっくり音声で。")
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.primary)

                Text("Googleにログインすると、登録チャンネルの新着・人気動画・検索をひとつにまとめられます。")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var benefits: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))

        return layout {
            BenefitCard(icon: "sparkles.tv", title: "見つける", detail: "新着・人気・検索")
            BenefitCard(icon: "arrow.down.circle.fill", title: "保存する", detail: "音声だけを端末へ")
            BenefitCard(icon: "headphones", title: "いつでも聴く", detail: "オフライン再生")
        }
    }

    private var privacyNote: some View {
        Label {
            Text("YouTube情報は読み取り専用です。Googleの認証情報を音声取得処理へ渡すことはありません。")
        } icon: {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(PodPalette.violet)
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 8)
    }

    private var configurationCard: some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("Google Client IDが必要です")
                    .font(.subheadline.bold())
                Text("Config/Secrets.xcconfig にiOS OAuth Client IDとURL Schemeを設定してください。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: "wrench.and.screwdriver.fill")
                .foregroundStyle(.orange)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func failureCard(_ message: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 4) {
                Text("ログインを完了できませんでした")
                    .font(.subheadline.bold())
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)
            }
        } icon: {
            Image(systemName: "exclamationmark.bubble.fill")
                .foregroundStyle(PodPalette.raspberry)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PodPalette.raspberry.opacity(0.09), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var signInPanel: some View {
        VStack(spacing: 9) {
            Button {
                Task { try? await environment.auth.signIn() }
            } label: {
                HStack(spacing: 10) {
                    if environment.auth.isWorking {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                    }
                    Text(environment.auth.isWorking ? "Googleに接続中…" : "Googleアカウントで続ける")
                        .fontWeight(.bold)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(PodPalette.violet)
            .disabled(environment.auth.isWorking || !environment.auth.isConfigured)

            if savedAudioCount > 0 {
                Button(action: openOfflineLibrary) {
                    Label(
                        "保存済みの音声を開く（\(savedAudioCount)件）",
                        systemImage: "headphones"
                    )
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 46)
                }
                .buttonStyle(.bordered)
                .buttonBorderShape(.capsule)
                .tint(PodPalette.violet)
                .accessibilityHint("Googleログインなしで端末内の音声を再生します")
            }

            Text("youtube.readonly 権限のみを使用します")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(
            reduceTransparency
                ? AnyShapeStyle(Color(.systemBackground))
                : AnyShapeStyle(.ultraThinMaterial)
        )
    }
}

private struct ListeningWaveform: View {
    let isAnimating: Bool
    private let heights: [CGFloat] = [18, 34, 54, 34, 18]

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(Array(heights.enumerated()), id: \.offset) { index, height in
                Capsule()
                    .fill(PodPalette.brandGradient)
                    .frame(width: 10, height: height)
                    .scaleEffect(y: isAnimating ? (index.isMultiple(of: 2) ? 1.08 : 0.86) : 1)
            }
        }
        .animation(
            isAnimating
                ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                : nil,
            value: isAnimating
        )
        .accessibilityHidden(true)
    }
}

private struct BenefitCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.title2.bold())
                .foregroundStyle(PodPalette.brandGradient)
            Text(title)
                .font(.subheadline.bold())
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, minHeight: 104)
        .padding(12)
        .podCard()
        .accessibilityElement(children: .combine)
    }
}
