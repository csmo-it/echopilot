import SwiftUI

enum EchoPilotTheme {
    static let background = Color(hex: 0x111418)
    static let card = Color(hex: 0x1A1F26)
    static let elevated = Color(hex: 0x222832)
    static let primary = Color(hex: 0x4F7CFF)
    static let recording = Color(hex: 0xFF4D4D)
    static let success = Color(hex: 0x3FD17F)
    static let warning = Color(hex: 0xF5B84B)
    static let text = Color.white.opacity(0.94)
    static let secondaryText = Color.white.opacity(0.62)
    static let mutedText = Color.white.opacity(0.42)
    static let stroke = Color.white.opacity(0.10)
}

extension Color {
    init(hex: UInt, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xff) / 255.0,
            green: Double((hex >> 8) & 0xff) / 255.0,
            blue: Double(hex & 0xff) / 255.0,
            opacity: alpha
        )
    }
}

struct EchoCard<Content: View>: View {
    let title: String?
    let subtitle: String?
    let systemImage: String?
    @ViewBuilder var content: Content

    init(
        _ title: String? = nil,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if title != nil || subtitle != nil {
                HStack(alignment: .top, spacing: 10) {
                    if let systemImage {
                        Image(systemName: systemImage)
                            .foregroundStyle(EchoPilotTheme.primary)
                            .font(.title3.weight(.semibold))
                            .frame(width: 24)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        if let title {
                            Text(title)
                                .font(.headline)
                                .foregroundStyle(EchoPilotTheme.text)
                        }
                        if let subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(EchoPilotTheme.secondaryText)
                        }
                    }
                    Spacer()
                }
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(EchoPilotTheme.card, in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(EchoPilotTheme.stroke, lineWidth: 1)
        )
    }
}

struct StatusChip: View {
    enum Tone {
        case neutral
        case primary
        case success
        case warning
        case danger

        var color: Color {
            switch self {
            case .neutral: return EchoPilotTheme.secondaryText
            case .primary: return EchoPilotTheme.primary
            case .success: return EchoPilotTheme.success
            case .warning: return EchoPilotTheme.warning
            case .danger: return EchoPilotTheme.recording
            }
        }
    }

    let title: String
    let tone: Tone
    let systemImage: String?

    init(_ title: String, tone: Tone = .neutral, systemImage: String? = nil) {
        self.title = title
        self.tone = tone
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 5) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
                .lineLimit(1)
        }
        .font(.caption2.weight(.semibold))
        .foregroundStyle(tone.color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(tone.color.opacity(0.14), in: Capsule())
        .overlay(Capsule().stroke(tone.color.opacity(0.18), lineWidth: 1))
    }
}

struct PrimaryButton: View {
    let title: String
    let systemImage: String
    let tone: StatusChip.Tone
    let disabledReason: String?
    let action: () -> Void

    init(
        _ title: String,
        systemImage: String,
        tone: StatusChip.Tone = .primary,
        disabledReason: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.systemImage = systemImage
        self.tone = tone
        self.disabledReason = disabledReason
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.white)
        .background(disabledReason == nil ? tone.color : EchoPilotTheme.elevated, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(disabledReason == nil ? tone.color.opacity(0.4) : EchoPilotTheme.stroke, lineWidth: 1)
        )
        .disabled(disabledReason != nil)
        .help(disabledReason ?? title)
    }
}

struct SecondaryCommandButton: View {
    let title: String
    let systemImage: String
    let disabledReason: String?
    let action: () -> Void

    init(_ title: String, systemImage: String, disabledReason: String? = nil, action: @escaping () -> Void) {
        self.title = title
        self.systemImage = systemImage
        self.disabledReason = disabledReason
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(disabledReason == nil ? EchoPilotTheme.text : EchoPilotTheme.mutedText)
        .disabled(disabledReason != nil)
        .help(disabledReason ?? title)
    }
}

struct CommandCenterSectionHeader: View {
    let step: String
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(step.uppercased())
                .font(.caption2.weight(.bold))
                .foregroundStyle(EchoPilotTheme.primary)
            Text(title)
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(EchoPilotTheme.text)
            Text(subtitle)
                .font(.callout)
                .foregroundStyle(EchoPilotTheme.secondaryText)
        }
    }
}

func echoPilotFormatDuration(_ seconds: TimeInterval) -> String {
    let total = max(0, Int(seconds))
    return String(format: "%02d:%02d", total / 60, total % 60)
}
