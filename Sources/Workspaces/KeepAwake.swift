import Foundation

/// One power assertion held while any session works, so the Mac does not idle-sleep under it.
/// The kernel drops it when the app exits, so it never outlives the app.
@MainActor
final class KeepAwake {
    private var activity: NSObjectProtocol?

    func hold(_ wanted: Bool) {
        if wanted, activity == nil {
            // userInitiated includes idleSystemSleepDisabled and keeps App Nap off the hooks and timers.
            // The display may still turn off; lid-close sleep is not affected. The reason shows in
            // `pmset -g assertions`, which garbles accents, so it stays ASCII.
            activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Workspaces: Claude trabalhando")
        } else if !wanted, let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
    }
}
