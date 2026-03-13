import SwiftUI

enum SidekickTheme {
    static let accent = Color(red: 0.294, green: 0.620, blue: 0.827)
    static let accentSecondary = Color(red: 0.949, green: 0.756, blue: 0.510)
    static let fog = Color.white.opacity(0.64)
    static let edge = Color.white.opacity(0.24)
    static let shadow = Color.black.opacity(0.12)
    static let canvasTop = Color(red: 0.972, green: 0.985, blue: 0.997)
    static let canvasBottom = Color(red: 0.920, green: 0.953, blue: 0.978)
    static let blush = Color(red: 0.992, green: 0.908, blue: 0.850)
}

struct SidekickBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [SidekickTheme.canvasTop, SidekickTheme.canvasBottom],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(
                    RadialGradient(
                        colors: [SidekickTheme.blush.opacity(0.55), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 220
                    )
                )
                .frame(width: 320, height: 320)
                .offset(x: -120, y: -300)

            Circle()
                .fill(
                    RadialGradient(
                        colors: [SidekickTheme.accent.opacity(0.26), .clear],
                        center: .center,
                        startRadius: 10,
                        endRadius: 260
                    )
                )
                .frame(width: 360, height: 360)
                .offset(x: 140, y: 240)
        }
        .ignoresSafeArea()
    }
}

struct GlassCardModifier: ViewModifier {
    var padding: CGFloat = 18

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(SidekickTheme.edge, lineWidth: 1)
            )
            .shadow(color: SidekickTheme.shadow, radius: 20, x: 0, y: 12)
    }
}

extension View {
    func glassCard(padding: CGFloat = 18) -> some View {
        modifier(GlassCardModifier(padding: padding))
    }
}

struct SectionHeader: View {
    let eyebrow: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(eyebrow.uppercased())
                .font(.caption.weight(.semibold))
                .foregroundStyle(SidekickTheme.accent)
                .tracking(1.6)

            Text(title)
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
                .foregroundStyle(.primary)

            Text(subtitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }
}

struct StatusPill: View {
    let title: String
    let tint: Color

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.16), in: Capsule())
            .foregroundStyle(tint)
    }
}
