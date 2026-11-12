import SwiftUI
import LedgerCore

enum Fmt {
    static let time: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .medium; return f }()
    /// Width of the time column in event rows, wide enough for "12:59:59 PM".
    static let clockWidth: CGFloat = 84
    static let detailIndent: CGFloat = 92
    static let dayTime: DateFormatter = { let f = DateFormatter(); f.dateStyle = .medium; f.timeStyle = .short; return f }()

    static let shortTime: DateFormatter = { let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f }()
    static func shortClock(_ ms: Double) -> String { shortTime.string(from: Date(timeIntervalSince1970: ms / 1000)) }
    static func clock(_ ms: Double) -> String { time.string(from: Date(timeIntervalSince1970: ms / 1000)) }
    static func day(_ ms: Double) -> String { dayTime.string(from: Date(timeIntervalSince1970: ms / 1000)) }

    /// A prompt or title on one line: runs of spaces and line breaks become single spaces.
    static func oneLine(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Sites worth showing: real hosts, without Chrome's own pages.
    static func sites(_ hosts: [String]) -> [String] {
        hosts.filter { ($0.contains(".") || $0 == "localhost") && $0 != "ogs.google.com" && !$0.hasSuffix(".google.com/_/chrome") }
    }

    static func duration(_ ms: Double) -> String {
        let s = Int(max(0, ms) / 1000)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \((s % 3600) / 60)m"
    }
}

struct Chip: View {
    let text: String
    var color: Color = .secondary
    var help: String = ""
    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
            .lineLimit(1)
            .help(help)
    }
}

/// Status that doesn't rely on colour alone.
struct StatusMark: View {
    enum Level { case ok, warn, off }
    let level: Level
    var body: some View {
        switch level {
        case .ok: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("OK")
        case .warn: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Needs attention")
        case .off: Image(systemName: "minus.circle").foregroundStyle(.secondary).accessibilityLabel("Not active")
        }
    }
}

enum Palette {
    static func agent(_ agent: String) -> Color {
        switch agent {
        case "claude-code": return .orange
        case "codex": return .teal
        default: return .gray
        }
    }

    static func actor(_ actor: String?) -> Color {
        switch actor {
        case "agent:claude-code": return .orange
        case "agent:codex": return .teal
        case "human": return .blue
        case "mixed": return .purple
        case "page": return .brown
        default: return .gray
        }
    }

    static func attribution(_ label: String) -> Color {
        switch label {
        case "identified": return .green
        case "likely": return .yellow
        case "mixed": return .purple
        default: return .gray
        }
    }
}

struct AgentBadge: View {
    let agent: String
    var body: some View {
        Image(systemName: agent == "codex" ? "chevron.left.forwardslash.chevron.right" : (agent == "claude-code" ? "sparkle" : "questionmark.circle"))
            .foregroundStyle(Palette.agent(agent))
            .frame(width: 18)
    }
}

extension AppModel.SessionDetail {
    /// The user's correction for an event, if one applies.
    func correction(for e: StoredEvent) -> Correction? {
        corrections.last { c in
            if let id = c.eventId { return id == e.id }
            if c.action == "this-was-me", let from = c.fromT, let to = c.toT { return e.event.t >= from && e.event.t <= to }
            return false
        }
    }
}

func correctedLabel(_ c: Correction?) -> String? {
    guard let c else { return nil }
    switch c.action {
    case "this-was-me": return "You (corrected)"
    case "wrong-agent": return "Not this agent"
    case "agent-confirmed": return "Agent (confirmed)"
    default: return nil
    }
}
