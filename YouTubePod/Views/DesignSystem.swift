import SwiftUI
import UIKit

enum PodPalette {
    // Inspired by the supplied artwork: cool turquoise with violet/lilac accents.
    static let raspberry = Color(red: 0.72, green: 0.43, blue: 0.72)
    static let tangerine = Color(red: 0.38, green: 0.21, blue: 0.64)
    static let violet = Color(red: 0.56, green: 0.34, blue: 0.69)
    static let sky = Color(red: 0.04, green: 0.69, blue: 0.66)
    static let mint = Color(red: 0.44, green: 0.84, blue: 0.77)

    static let brandGradient = LinearGradient(
        colors: [tangerine, violet, raspberry],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let playerGradient = LinearGradient(
        colors: [sky, violet, raspberry],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct PodScreenBackground: View {
    var body: some View {
        ZStack {
            Color(.systemBackground)
            LinearGradient(
                colors: [PodPalette.sky.opacity(0.20), PodPalette.mint.opacity(0.10), .clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

struct PodCardModifier: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(reduceTransparency ? Color(.secondarySystemBackground) : Color(.secondarySystemBackground).opacity(0.74))
                    .strokeBorder(Color.primary.opacity(0.06))
            }
    }
}

extension View {
    func podCard() -> some View {
        modifier(PodCardModifier())
    }
}

struct PodBrandMark: View {
    var size: CGFloat = 44

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.31, style: .continuous)
                .fill(PodPalette.brandGradient)
            Image(systemName: "waveform")
                .font(.system(size: size * 0.43, weight: .black, design: .rounded))
                .foregroundStyle(.white)
                .symbolEffect(.variableColor.iterative, options: .nonRepeating)
        }
        .frame(width: size, height: size)
        .shadow(color: PodPalette.violet.opacity(0.22), radius: size * 0.2, y: size * 0.12)
        .accessibilityHidden(true)
    }
}

/// A circular toolbar treatment that fits iOS's glass navigation container.
/// The full app mark remains a squircle elsewhere in the app.
struct PodToolbarBrandMark: View {
    var size: CGFloat = 34

    var body: some View {
        Circle()
            .fill(PodPalette.brandGradient)
            .overlay {
                Image(systemName: "waveform")
                    .font(.system(size: size * 0.48, weight: .black, design: .rounded))
                    .foregroundStyle(.white)
            }
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

struct PodAccountAvatar: View {
    let imageURL: URL?
    let displayName: String
    var size: CGFloat = 36

    var body: some View {
        AsyncImage(url: imageURL) { phase in
            if case .success(let image) = phase {
                image
                    .resizable()
                    .scaledToFill()
            } else {
                ZStack {
                    Circle().fill(PodPalette.brandGradient)
                    Text(initials)
                        .font(.system(size: size * 0.34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(.white.opacity(0.72), lineWidth: 1.5)
        }
    }

    private var initials: String {
        let words = displayName.split(separator: " ")
        let value = words.prefix(2).compactMap(\.first).map(String.init).joined().uppercased()
        return value.isEmpty ? "G" : value
    }
}

struct PodArtworkImage: View {
    let url: URL?
    var symbol = "waveform"
    var contentMode: ContentMode = .fill

    var body: some View {
        Group {
            if let url, url.isFileURL, let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: contentMode)
                    default:
                        PodPalette.playerGradient
                            .overlay {
                                Image(systemName: symbol)
                                    .font(.title2.bold())
                                    .foregroundStyle(.white)
                            }
                    }
                }
            }
        }
    }
}

struct PodEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: icon)
                .symbolRenderingMode(.multicolor)
        } description: {
            Text(message)
                .lineLimit(5)
        } actions: {
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(PodPalette.raspberry)
            }
        }
    }
}

struct PodErrorState: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("読み込めませんでした", systemImage: "wifi.exclamationmark")
        } description: {
            Text(message)
                .lineLimit(5)
        } actions: {
            Button("もう一度試す", action: retry)
                .buttonStyle(.borderedProminent)
                .tint(PodPalette.raspberry)
        }
    }
}

struct SectionHeading: View {
    let title: String
    let subtitle: String?
    var systemImage: String?

    init(_ title: String, subtitle: String? = nil, systemImage: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let systemImage {
                Image(systemName: systemImage)
                    .foregroundStyle(PodPalette.brandGradient)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.title3.bold())
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
    }
}
