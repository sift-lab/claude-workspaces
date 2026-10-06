import Foundation
import Testing
@testable import WorkspacesCore

@Suite struct ContextLimitsTests {
    let limits = ContextLimits()

    @Test func defaultsAndLevels() {
        #expect(limits.handoff == 300_000 && limits.alarm == 500_000 && limits.step == 50_000)
        #expect(limits.level(nil) == .normal)
        #expect(limits.level(300_000) == .normal)
        #expect(limits.level(300_001) == .needsHandoff)
        #expect(limits.level(500_000) == .needsHandoff)
        #expect(limits.level(500_001) == .alarm)
        #expect(ContextLimits(handoff: 600_000).alarm == 600_000)
        #expect(AppConfig(handoffContextTokens: 200_000).contextLimits.level(250_000) == .needsHandoff)
    }

    @Test func remindsOnCrossingThenEveryFiftyThousand() {
        var last: Int?
        #expect(limits.reminder(tokens: 290_000, lastWarned: &last) == nil)
        #expect(limits.reminder(tokens: 310_000, lastWarned: &last) == ContextLimits.reminder(tokens: 310_000, limit: 300_000))
        #expect(last == 310_000)
        #expect(limits.reminder(tokens: 340_000, lastWarned: &last) == nil)
        #expect(limits.reminder(tokens: 359_999, lastWarned: &last) == nil)
        #expect(limits.reminder(tokens: 360_000, lastWarned: &last) != nil)
        #expect(limits.reminder(tokens: 380_000, lastWarned: &last) == nil)
        #expect(limits.reminder(tokens: nil, lastWarned: &last) == nil)
        #expect(last == 360_000)
    }

    @Test func aCompactionStartsTheCountOver() {
        var last: Int? = 600_000
        // Dropped a whole step but still above the limit: remind right away.
        #expect(limits.reminder(tokens: 400_000, lastWarned: &last) != nil)
        #expect(last == 400_000)
        // Back under the limit: the next crossing reminds again.
        #expect(limits.reminder(tokens: 80_000, lastWarned: &last) == nil)
        #expect(last == nil)
        #expect(limits.reminder(tokens: 301_000, lastWarned: &last) != nil)
    }

    @Test func reminderText() {
        #expect(ContextLimits.reminder(tokens: 412_345, limit: 300_000)
                == "Contexto em 412k, acima do limite de 300k: no próximo ponto seguro, escreva a Passagem no FRENTE.md e chame recycle_self.")
    }

    @Test func shortForm() {
        #expect(ContextLimits.short(963_412) == "963k")
        #expect(ContextLimits.short(300_000) == "300k")
    }

    @Test func configDefaultsToThreeHundredThousand() throws {
        let config = try JSONDecoder().decode(AppConfig.self, from: Data("{}".utf8))
        #expect(config.handoffContextTokens == 300_000)
        var custom = AppConfig()
        custom.handoffContextTokens = 250_000
        let back = try JSONDecoder().decode(AppConfig.self, from: JSONEncoder().encode(custom))
        #expect(back.handoffContextTokens == 250_000)
    }
}
