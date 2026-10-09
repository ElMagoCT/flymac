import SwiftUI
import FlyCore

/// Restrained dark palette. Numbers are monospaced, text is scarce.
enum Theme {
    static let bg = Color(red: 0.055, green: 0.06, blue: 0.07)
    static let panel = Color(red: 0.09, green: 0.095, blue: 0.11)
    static let panelRaised = Color(red: 0.125, green: 0.13, blue: 0.15)
    static let line = Color.white.opacity(0.07)
    static let text = Color(white: 0.92)
    static let dim = Color(white: 0.55)
    static let accent = Color(red: 0.36, green: 0.78, blue: 0.86)   // cool cyan, one accent only
    static let ok = Color(red: 0.42, green: 0.80, blue: 0.52)
    static let warn = Color(red: 0.95, green: 0.72, blue: 0.30)
    static let bad = Color(red: 0.92, green: 0.40, blue: 0.40)
    static let radius: CGFloat = 10

    /// One colour per connected device (roster slot). Muted so four of them on
    /// screen still read as one system; slot 0 is the app accent.
    static let devicePalette: [Color] = [
        accent,
        Color(red: 0.95, green: 0.70, blue: 0.36),   // amber
        Color(red: 0.56, green: 0.84, blue: 0.52),   // green
        Color(red: 0.86, green: 0.55, blue: 0.80),   // orchid
        Color(red: 0.62, green: 0.66, blue: 0.98),   // periwinkle
        Color(red: 0.94, green: 0.52, blue: 0.48),   // coral
    ]
    static func deviceColor(_ slot: Int) -> Color { devicePalette[((slot % devicePalette.count) + devicePalette.count) % devicePalette.count] }

    static func color(for e: Evidence) -> Color {
        switch e { case .confirmed: return ok; case .likely: return accent; case .unverified: return dim; case .blocked: return bad }
    }
}

struct Panel<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title { Text(title.uppercased()).font(.caption2.weight(.semibold)).tracking(1.2).foregroundStyle(Theme.dim) }
            content
        }
        .padding(14)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line))
    }
}

struct Chip: View {
    var text: String
    var symbol: String? = nil
    var color: Color = Theme.dim
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: Capsule())
    }
}

/// A big number with a tiny label. The HUD is made of these.
struct Stat: View {
    var label: String
    var value: String
    var unit: String = ""
    var color: Color = Theme.text
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(Theme.dim)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 22, weight: .medium, design: .rounded)).monospacedDigit().foregroundStyle(color)
                    .contentTransition(.numericText())
                if !unit.isEmpty { Text(unit).font(.system(size: 11)).foregroundStyle(Theme.dim) }
            }
        }
        .frame(minWidth: 84, alignment: .leading)
    }
}

struct EmptyState: View {
    var symbol: String; var title: String; var detail: String = ""
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 34, weight: .light)).foregroundStyle(Theme.dim)
            Text(title).font(.title3.weight(.medium))
            if !detail.isEmpty { Text(detail).font(.callout).foregroundStyle(Theme.dim).multilineTextAlignment(.center).frame(maxWidth: 380) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension Int64 {
    var bytesString: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
extension Double {
    var bytesPerSecondString: String { ByteCountFormatter.string(fromByteCount: Int64(self), countStyle: .file) + "/s" }
}
extension TimeInterval {
    var clock: String { let s = Int(self); return String(format: "%d:%02d", s / 60, s % 60) }
}
