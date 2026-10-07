import Foundation

// Long-lived conversations reread their whole context on every call. Past a limit the session
// "precisa de passagem": it is told so by the hooks, marked in the app, and past the alarm the
// person is notified. Nothing here switches the model or compacts: compaction loses detail.

// MARK: Context thresholds

/// When a session's context asks for a handoff, and when it is an alarm.
public struct ContextLimits: Equatable, Sendable {
    public static let defaultHandoff = 300_000
    public static let defaultAlarm = 500_000
    public static let defaultStep = 50_000

    /// Above this the session "precisa de passagem". Set in Settings.
    public var handoff: Int
    /// Above this the person gets a notification and the mark turns red.
    public var alarm: Int
    /// Once above `handoff`, the session is reminded again each time its context grows this much.
    public var step: Int

    public init(handoff: Int = defaultHandoff, alarm: Int = defaultAlarm, step: Int = defaultStep) {
        self.handoff = handoff
        self.alarm = max(alarm, handoff)
        self.step = max(step, 1)
    }

    public enum Level: Int, Comparable, Sendable {
        case normal, needsHandoff, alarm
        public static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }
    }

    public func level(_ tokens: Int?) -> Level {
        guard let tokens else { return .normal }
        if tokens > alarm { return .alarm }
        if tokens > handoff { return .needsHandoff }
        return .normal
    }

    /// The reminder due now, if any. `lastWarned` is the context at the last reminder of this
    /// conversation and is updated here: one reminder on crossing the limit, then one per `step`
    /// of growth. A drop of a whole step (a compaction) starts the count over.
    public func reminder(tokens: Int?, lastWarned: inout Int?) -> String? {
        guard let tokens else { return nil }
        guard tokens > handoff else {
            lastWarned = nil
            return nil
        }
        if let last = lastWarned, tokens < last + step, tokens + step > last { return nil }
        lastWarned = tokens
        return Self.reminder(tokens: tokens, limit: handoff)
    }

    /// What the hooks add to the session's context while the context is above the limit.
    public static func reminder(tokens: Int, limit: Int) -> String {
        "Contexto em \(short(tokens)), acima do limite de \(short(limit)): no próximo ponto seguro, escreva a Passagem no FRENTE.md, com data e hora no título, e chame recycle_self."
    }

    /// "963k", the way list_sessions and the reminder write a context.
    public static func short(_ tokens: Int) -> String {
        "\(Int((Double(tokens) / 1000).rounded()))k"
    }
}
