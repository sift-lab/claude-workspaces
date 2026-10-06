import Foundation

/// Decides when the Mac must not idle-sleep: while a Claude session works. Pure, so it can be tested.
///
/// Claude Code keeps its own `caffeinate -i -t 300` relay, but it kills each one before starting the
/// next, holds only while its turn runs, and dies with the session. The app outlives all of that.
public struct KeepAwakePolicy: Sendable {
    /// A session still marked working with no hook for this long is presumed stuck (an interrupt
    /// may skip Stop), unless a command still runs under it.
    public var staleAfter: TimeInterval

    public init(staleAfter: TimeInterval = 30 * 60) {
        self.staleAfter = staleAfter
    }

    public struct Session: Sendable {
        public var status: SessionStatus
        public var quietFor: TimeInterval
        /// A shell under Claude: a Bash call or background task that sends no hook until it ends.
        public var runningCommand: Bool

        public init(status: SessionStatus, quietFor: TimeInterval, runningCommand: Bool) {
            self.status = status
            self.quietFor = quietFor
            self.runningCommand = runningCommand
        }
    }

    public func holds(_ sessions: [Session]) -> Bool {
        sessions.contains { $0.status == .working && ($0.quietFor < staleAfter || $0.runningCommand) }
    }
}
