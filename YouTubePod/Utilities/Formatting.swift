import Foundation

enum DisplayFormatter {
    static func relativeDate(_ date: Date, relativeTo now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    static func views(_ count: Int64) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.numberStyle = .decimal
        return "\(formatter.string(from: NSNumber(value: count)) ?? String(count)) 回視聴"
    }

    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }
}

enum YouTubeURLParser {
    static func videoID(from input: String) -> String? {
        func valid(_ value: String?) -> String? {
            guard let value,
                  value.range(of: #"^[A-Za-z0-9_-]{11}$"#, options: .regularExpression) != nil else { return nil }
            return value
        }
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let value = valid(trimmed) { return value }
        guard let components = URLComponents(string: trimmed), let host = components.host?.lowercased() else {
            return nil
        }
        if host == "youtu.be" {
            return valid(components.path.split(separator: "/").first.map(String.init))
        }
        if host == "youtube.com" || host.hasSuffix(".youtube.com") {
            if let value = valid(components.queryItems?.first(where: { $0.name == "v" })?.value) { return value }
            let parts = components.path.split(separator: "/")
            if let marker = parts.firstIndex(where: { $0 == "shorts" || $0 == "embed" }), parts.indices.contains(marker + 1) {
                return valid(String(parts[marker + 1]))
            }
        }
        return nil
    }
}

extension Collection {
    func chunks(ofCount size: Int) -> [[Element]] {
        guard size > 0 else { return [] }
        var result: [[Element]] = []
        var index = startIndex
        while index != endIndex {
            let next = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            result.append(Array(self[index..<next]))
            index = next
        }
        return result
    }
}
