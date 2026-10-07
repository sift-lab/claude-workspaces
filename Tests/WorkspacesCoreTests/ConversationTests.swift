import Foundation
import Testing
@testable import WorkspacesCore

private func hook(_ event: String, _ id: String, source: String? = nil, reason: String? = nil) -> HookUpdate {
    var payload: [String: JSONValue] = ["hook_event_name": .string(event), "session_id": .string(id)]
    if let source { payload["source"] = .string(source) }
    if let reason { payload["reason"] = .string(reason) }
    return HookEvent.update(from: .object(payload))!
}

@Suite struct ConversationTrackerTests {
    @Test func aClearKeepsTheNewConversationOnceItHasAMessage() {
        var tracker = ConversationTracker(saved: "old")
        tracker.apply(hook("SessionEnd", "old", reason: "clear"))
        let changed1 = tracker.apply(hook("SessionStart", "new", source: "clear"))
        #expect(changed1)
        // Empty right after the clear: --resume could not open it, so nothing is resumable yet.
        #expect(tracker.current == "new")
        #expect(tracker.resumable == nil)
        let changed2 = tracker.apply(hook("UserPromptSubmit", "new"))
        #expect(changed2)
        #expect(tracker.resumable == "new")
    }

    @Test func aPromptQueuedByAnotherSessionAlsoCounts() {
        // 06/10: the first message after the clear came from Claude Code's queue, and only
        // PostToolUse and Stop reported the new conversation.
        var tracker = ConversationTracker(saved: "c9656622")
        tracker.apply(hook("SessionStart", "1b86fcec", source: "clear"))
        tracker.apply(hook("PostToolUse", "1b86fcec"))
        #expect(tracker.resumable == "1b86fcec")
    }

    @Test func theOldSessionEndArrivingLateDoesNotBringTheOldConversationBack() {
        var tracker = ConversationTracker(saved: "old")
        tracker.apply(hook("SessionStart", "new", source: "clear"))
        tracker.apply(hook("UserPromptSubmit", "new"))
        // SessionEnd hooks of a /clear are cut at 1.5 s; a slow helper delivers this one after the start.
        let changed3 = tracker.apply(hook("SessionEnd", "old", reason: "clear"))
        #expect(!changed3)
        let changed4 = tracker.apply(hook("Stop", "old"))
        #expect(!changed4)
        let changed5 = tracker.apply(hook("PostToolUse", "old"))
        #expect(!changed5)
        #expect(tracker.current == "new")
        #expect(tracker.resumable == "new")
    }

    @Test func aMissedSessionStartIsCaughtByTheNextHook() {
        var tracker = ConversationTracker(saved: "old")
        let changed6 = tracker.apply(hook("UserPromptSubmit", "new"))
        #expect(changed6)
        #expect(tracker.current == "new")
        #expect(tracker.resumable == "new")
        // The replaced conversation is now finished: a late hook from it changes nothing.
        let changed7 = tracker.apply(hook("Stop", "old"))
        #expect(!changed7)
        #expect(tracker.resumable == "new")
    }

    @Test func severalClearsInARowEndOnTheLastOne() {
        var tracker = ConversationTracker(saved: "c9656622")
        for (previous, next) in [("c9656622", "a0798dfd"), ("a0798dfd", "181e5ac4"), ("181e5ac4", "7d51d6b4"), ("7d51d6b4", "1b86fcec")] {
            tracker.apply(hook("SessionStart", next, source: "clear"))
            tracker.apply(hook("SessionEnd", previous, reason: "clear"))
            if next != "a0798dfd" { tracker.apply(hook("Stop", next)) }
        }
        #expect(tracker.resumable == "1b86fcec")
    }

    @Test func aResumeReopensAConversationThatEndedBefore() {
        var tracker = ConversationTracker(saved: "c1")
        // Hibernating ends the process; waking resumes the same conversation.
        tracker.apply(hook("SessionEnd", "c1", reason: "other"))
        #expect(tracker.resumable == "c1")
        tracker.apply(hook("SessionStart", "c1", source: "resume"))
        tracker.apply(hook("Stop", "c1"))
        #expect(tracker.current == "c1")
        #expect(tracker.resumable == "c1")
    }

    @Test func aResumeThatForksFollowsTheNewId() {
        var tracker = ConversationTracker(saved: "c1")
        let changed8 = tracker.apply(hook("SessionStart", "c2", source: "resume"))
        #expect(changed8)
        #expect(tracker.resumable == "c2")
        let changed9 = tracker.apply(hook("Stop", "c1"))
        #expect(!changed9)
    }

    @Test func aFreshSessionIsResumableOnlyAfterItsFirstMessage() {
        var tracker = ConversationTracker(saved: nil)
        let changed10 = tracker.apply(hook("SessionStart", "c1", source: "startup"))
        #expect(!changed10)
        #expect(tracker.current == "c1")
        #expect(tracker.resumable == nil)
        let changed11 = tracker.apply(hook("UserPromptSubmit", "c1"))
        #expect(changed11)
        #expect(tracker.resumable == "c1")
    }

    @Test func anIdleReminderDoesNotMakeAnEmptyConversationResumable() {
        var tracker = ConversationTracker(saved: "old")
        tracker.apply(hook("SessionStart", "new", source: "clear"))
        var idle = hook("Notification", "new")
        idle.status = nil  // what HookEvent makes of notification_type "idle_prompt"
        tracker.apply(idle)
        #expect(tracker.resumable == nil)
        tracker.apply(HookEvent.update(from: .object(["hook_event_name": .string("Notification"), "session_id": .string("new"),
                                                      "message": .string("Claude needs your permission to use Bash")]))!)
        #expect(tracker.resumable == "new")
    }

    @Test func hooksWithoutAnIdChangeNothing() {
        var tracker = ConversationTracker(saved: "c1")
        let changed12 = tracker.apply(HookUpdate(event: "Stop", status: .done))
        #expect(!changed12)
        #expect(tracker.resumable == "c1")
    }

    @Test func theFinishedListStaysSmall() {
        var tracker = ConversationTracker(saved: "c0")
        for i in 1...100 { tracker.apply(hook("SessionStart", "c\(i)", source: "clear")) }
        #expect(tracker.finished.count == ConversationTracker.finishedLimit)
        #expect(tracker.finished.last == "c99")
    }
}
