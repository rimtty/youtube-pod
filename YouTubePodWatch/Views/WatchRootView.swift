import SwiftUI

struct WatchRootView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    Image(systemName: "waveform")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.purple, .pink],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .accessibilityHidden(true)

                    Text("Watchライブラリ")
                        .font(.headline)

                    Text("iPhoneから転送された音声がここに表示されます。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.top, 16)
            }
            .containerBackground(
                LinearGradient(
                    colors: [
                        Color(red: 0.03, green: 0.48, blue: 0.43),
                        Color(red: 0.08, green: 0.23, blue: 0.30)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                for: .navigation
            )
            .navigationTitle("YouTube Pod")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}
