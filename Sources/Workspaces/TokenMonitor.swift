import AppKit
import Observation
import WorkspacesCore

/// Tokens the sessions spend and each account's limit. The transcripts are read in the background,
/// from where each one stopped; the meter comes from the status line Claude Code refreshes.
/// The ring, the menu bar and Consumo show one account at a time, `meterAccount`.
@MainActor
@Observable
final class TokenMonitor {
    /// What the status line said about a session's context: exact, and fresher than the transcript.
    struct ExactContext: Equatable {
        var tokens: Int
        var size: Int?
        var at: Date
    }

    /// The account's 5 h window or week, now.
    struct Limit: Equatable {
        var used: Double
        var resetsAt: Date
        /// No reading from the meter yet: the number comes from the transcripts alone.
        var estimated: Bool
        var forecast: Forecast
    }

    /// One account's meter: the last readings and the spend of its sessions.
    struct Meter: Equatable {
        var overview: TokenOverview?
        var fiveHour: MeterReading?
        var sevenDay: MeterReading?
        /// Weight that fills each window, calibrated from the meter's readings.
        var windowFull = LimitMath.defaultWindowWeight
        var weekFull = LimitMath.defaultWeekWeight
    }

    private struct Floors {
        var at: Date
        var window: Double
        var week: Double
    }

    /// By account name.
    private(set) var meters: [String: Meter] = [:]
    /// The account the ring, the menu bar and Consumo show: the one of the session on screen.
    var meterAccount = LimitReadingStore.defaultAccount
    /// By Claude's session id; only the sessions open in the app.
    private(set) var sessions: [String: SessionTokens] = [:]
    private(set) var exact: [String: ExactContext] = [:]
    /// The Consumo window shows this session in full.
    var focused: UUID?

    private var meter: Meter { meters[meterAccount] ?? Meter() }
    var overview: TokenOverview? { meter.overview }
    var fiveHour: MeterReading? { meter.fiveHour }
    var sevenDay: MeterReading? { meter.sevenDay }
    var windowFull: Double { meter.windowFull }
    var weekFull: Double { meter.weekFull }

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let queue = DispatchQueue(label: "workspaces.tokens", qos: .utility)
    /// Writes go on their own queue: the first scan of two weeks of transcripts would hold them.
    @ObservationIgnored private let files = DispatchQueue(label: "workspaces.tokens.files", qos: .utility)
    @ObservationIgnored private let ledger = TokenLedger()
    /// One per projects folder the accounts read, symlinks resolved; Claude Code's own always.
    @ObservationIgnored private var scanners: [String: TranscriptScanner] = [:]
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var soon: DispatchWorkItem?
    /// Each account's readings, loaded on first use.
    @ObservationIgnored private var readings: [String: LimitReadings] = [:]
    @ObservationIgnored private var alertedWindow: [String: Date] = [:]
    /// The heaviest 5 h and 7 days seen locally; sorting every call is too much for every tick.
    @ObservationIgnored private var floors: [String: Floors] = [:]
    @ObservationIgnored private var pendingSave: [String: DispatchWorkItem] = [:]
    /// Which account each conversation ran in and since when, as the sessions reported it. Kept on
    /// disk, so the spend stays with its account after a /clear, a close or a restart; a
    /// conversation the app never ran is the default account's.
    @ObservationIgnored private var owners = ConversationAccounts()
    @ObservationIgnored private var pendingOwnersSave: DispatchWorkItem?

    static let contextDefault = 1_000_000
    private nonisolated static let horizon: TimeInterval = 15 * 86_400

    func start(model: AppModel) {
        self.model = model
        meterAccount = model.config.mainAccount.name
        if let data = FileManager.default.contents(atPath: Self.ownersFile.path),
           let saved = try? JSONDecoder().decode(ConversationAccounts.self, from: data) {
            owners = saved
            owners.prune(before: Date().addingTimeInterval(-Self.horizon - 86_400))
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 3
    }

    // MARK: Status line

    func receive(_ reading: StatusLineReading, from runtime: SessionRuntime) {
        let now = Date()
        let account = self.account(of: runtime)
        if let id = reading.sessionId ?? runtime.claudeSessionId {
            record(id, account: account, at: now)
            if let tokens = reading.contextTokens, tokens > 0 {
                exact[id] = ExactContext(tokens: tokens, size: reading.contextSize, at: now)
                model?.checkContextAlarms()
            }
        }
        var saved = loadedReadings(account)
        var meter = meters[account] ?? Meter()
        var changed = false
        if let r = reading.fiveHour {
            var list = saved.fiveHour
            if record(r, in: &list) { meter.fiveHour = r }
            changed = changed || list.count != saved.fiveHour.count || list.last?.percent != saved.fiveHour.last?.percent
            saved.fiveHour = list
        }
        if let r = reading.sevenDay {
            var list = saved.sevenDay
            if record(r, in: &list) { meter.sevenDay = r }
            changed = changed || list.count != saved.sevenDay.count || list.last?.percent != saved.sevenDay.last?.percent
            saved.sevenDay = list
        }
        readings[account] = saved
        if meters[account] != meter { meters[account] = meter }
        // Only a new value is written; the same value seen again just moves its time in memory.
        if changed { saveReadings(account) }
        // A new answer just landed somewhere: read it soon, not at the next tick.
        soon?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        soon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Keeps only readings that changed something; returns true when the reading is the newest.
    private func record(_ reading: MeterReading, in list: inout [MeterReading]) -> Bool {
        LimitReadings.record(reading, in: &list)
    }

    /// Screenshot mode only: a meter reading equal to what the transcripts estimate.
    func previewMeter(from runtime: SessionRuntime) {
        guard let o = overview else { return }
        let now = o.now
        // The windows the readings announce start later than the rolling ones the overview used.
        let fiveReset = now.addingTimeInterval(116 * 60), weekReset = now.addingTimeInterval(3.6 * 86_400)
        let inFive = o.weightInWindow - weight(in: o.windowCurve, start: o.windowStart, at: fiveReset.addingTimeInterval(-5 * 3600))
        let inWeek = o.weightInWeek - weight(in: o.weekCurve, start: o.weekStart, at: weekReset.addingTimeInterval(-7 * 86_400))
        let five = MeterReading(time: now, percent: (inFive / windowFull * 100).rounded(), resetsAt: fiveReset)
        let week = MeterReading(time: now, percent: (inWeek / weekFull * 100).rounded(), resetsAt: weekReset)
        var reading = StatusLineReading()
        reading.fiveHour = five
        reading.sevenDay = week
        receive(reading, from: runtime)
    }

    // MARK: Reading the transcripts

    func refresh() {
        guard let model else { return }
        if busy { again = true; return }
        busy = true
        let now = Date()
        // Only a session that runs knows its account; one not started yet would claim the default's.
        for runtime in model.sessions {
            guard let account = runtime.account else { continue }
            for id in [runtime.conversation.current, runtime.conversation.resumable].compactMap({ $0 }) { record(id, account: account, at: now) }
        }
        var ids: [String: String] = [:]
        for runtime in model.sessions { if let id = runtime.claudeSessionId { ids[id] = account(of: runtime) } }
        let config = model.config
        let home = NSHomeDirectory()
        let today = Calendar.current.startOfDay(for: now)
        let from = min(today, now.addingTimeInterval(-6 * 3600))
        let main = config.mainAccount.name
        let split = config.accounts.count > 1
        let owners = self.owners
        struct Job { var account: String; var windowStart: Date; var weekStart: Date; var r5: [MeterReading]; var r7: [MeterReading]; var floors: Floors? }
        let jobs = config.accounts.map { account -> Job in
            let saved = loadedReadings(account.name)
            return Job(account: account.name, windowStart: windowStart(now, account: account.name), weekStart: weekStart(now, account: account.name),
                       r5: saved.fiveHour, r7: saved.sevenDay, floors: floors[account.name].flatMap { now.timeIntervalSince($0.at) < 600 ? $0 : nil })
        }
        let starts = Dictionary(jobs.map { ($0.account, $0.windowStart) }, uniquingKeysWith: { a, _ in a })
        let ledger = self.ledger, scanners = Array(updatedScanners(config).values)
        queue.async { [weak self] in
            for scanner in scanners { scanner.scan(into: ledger, since: now.addingTimeInterval(-Self.horizon)) }
            ledger.prune(before: now.addingTimeInterval(-Self.horizon - 86_400))
            var sessions: [String: SessionTokens] = [:]
            for (id, account) in ids {
                let windowStart = starts[account] ?? now.addingTimeInterval(-5 * 3600)
                if let s = ledger.session(id, from: from, windowStart: windowStart, now: now) { sessions[id] = s }
            }
            var results: [(account: String, overview: TokenOverview, full5: Double, full7: Double, floors: Floors)] = []
            for job in jobs {
                // With one account every conversation is its own, even one no session reported.
                let mask = split ? ledger.filter {
                    owners.changes($0, for: job.account) ?? [LedgerFilter.Change(from: -.infinity, counts: job.account == main)]
                } : nil
                let overview = ledger.overview(now: now, windowStart: job.windowStart, weekStart: job.weekStart, only: mask) { cwd in
                    cwd.flatMap { config.project(containing: $0, home: home)?.workspace.name } ?? "Outros"
                }
                // Before the meter calibrates, a window holds at least the heaviest stretch seen locally.
                let seen = now.addingTimeInterval(-Self.horizon)
                let floors = job.floors ?? Floors(
                    at: now,
                    window: max(LimitMath.defaultWindowWeight, ledger.heaviest(span: 5 * 3600, from: seen, to: now, only: mask)),
                    week: max(LimitMath.defaultWeekWeight, ledger.heaviest(span: 7 * 86_400, from: seen, to: now, only: mask)))
                let full5 = LimitMath.fullWeight(readings: job.r5, spent: { ledger.weight(from: $0, to: $1, only: mask) }, fallback: floors.window)
                let full7 = LimitMath.fullWeight(readings: job.r7, minimumDelta: 3, spent: { ledger.weight(from: $0, to: $1, only: mask) },
                                                 fallback: floors.week)
                results.append((job.account, overview, full5, full7, floors))
            }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    for r in results { self.floors[r.account] = r.floors }
                    self.publish(results.map { ($0.account, $0.overview, $0.full5, $0.full7) }, sessions: sessions)
                }
            }
        }
    }

    private func publish(_ results: [(account: String, overview: TokenOverview, full5: Double, full7: Double)], sessions: [String: SessionTokens]) {
        for r in results {
            var meter = meters[r.account] ?? Meter()
            meter.overview = r.overview
            meter.windowFull = r.full5
            meter.weekFull = r.full7
            if meters[r.account] != meter { meters[r.account] = meter }
        }
        if self.sessions != sessions { self.sessions = sessions }
        busy = false
        for r in results { checkAlert(r.account) }
        model?.checkContextAlarms()
        if again {
            again = false
            refresh()
        }
    }

    /// Keeps which account the session's conversations run in from now on: called when it starts
    /// and when its conversation changes, so a switch counts from the moment it happened.
    func note(_ runtime: SessionRuntime) {
        guard let account = runtime.account else { return }
        let now = Date()
        for id in [runtime.conversation.current, runtime.conversation.resumable].compactMap({ $0 }) { record(id, account: account, at: now) }
    }

    private func record(_ conversation: String, account: String, at date: Date) {
        guard owners.record(conversation, account: account, at: date) else { return }
        pendingOwnersSave?.cancel()
        let saved = owners
        let work = DispatchWorkItem {
            try? FileManager.default.createDirectory(at: AppPaths.supportDirectory, withIntermediateDirectories: true)
            try? JSONEncoder().encode(saved).write(to: Self.ownersFile, options: .atomic)
        }
        pendingOwnersSave = work
        files.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Writes now what waits to be written, when the app quits.
    func flush() {
        for work in Array(pendingSave.values) + [pendingOwnersSave].compactMap({ $0 }) where !work.isCancelled {
            // A cancelled item no longer runs, so it is run first.
            files.sync { work.perform() }
            work.cancel()
        }
        pendingSave = [:]
        pendingOwnersSave = nil
    }

    private static var ownersFile: URL { AppPaths.supportDirectory.appendingPathComponent("conversation-accounts.json") }

    /// The account a session's spend and readings belong to: the one its process runs in.
    func account(of runtime: SessionRuntime) -> String {
        runtime.account ?? model?.config.mainAccount.name ?? LimitReadingStore.defaultAccount
    }

    /// Claude Code's own projects folder, plus the one of each account that keeps its own.
    private func updatedScanners(_ config: AppConfig) -> [String: TranscriptScanner] {
        let env = model?.toolEnvironment ?? ProcessInfo.processInfo.environment
        var roots = ["\(NSHomeDirectory())/.claude/projects"]
        roots += config.accounts.map { $0.projectsDirectory(environment: env) }
        for root in roots {
            let key = AccountFolder.resolved(root)
            if scanners[key] == nil, FileManager.default.fileExists(atPath: key) {
                scanners[key] = TranscriptScanner(root: URL(fileURLWithPath: key, isDirectory: true))
            }
        }
        return scanners
    }

    // MARK: Windows

    func windowStart(_ now: Date, account: String? = nil) -> Date {
        if let r = meters[account ?? meterAccount]?.fiveHour, r.resetsAt > now { return r.resetsAt.addingTimeInterval(-5 * 3600) }
        return now.addingTimeInterval(-5 * 3600)
    }

    func weekStart(_ now: Date, account: String? = nil) -> Date {
        if let r = meters[account ?? meterAccount]?.sevenDay, r.resetsAt > now { return r.resetsAt.addingTimeInterval(-7 * 86_400) }
        return now.addingTimeInterval(-7 * 86_400)
    }

    /// Weight spent in a window up to `date`, from the cumulative curve.
    private func weight(in curve: [CurvePoint], start: Date, at date: Date) -> Double {
        let offset = date.timeIntervalSince(start)
        guard let after = curve.firstIndex(where: { $0.offset >= offset }) else { return curve.last?.weight ?? 0 }
        guard after > 0 else { return 0 }
        let a = curve[after - 1], b = curve[after]
        let f = b.offset > a.offset ? (offset - a.offset) / (b.offset - a.offset) : 1
        return a.weight + (b.weight - a.weight) * f
    }

    var fiveHourLimit: Limit? { fiveHourLimit(meter) }
    var weekLimit: Limit? { weekLimit(meter) }

    private func fiveHourLimit(_ meter: Meter) -> Limit? {
        guard let o = meter.overview else { return nil }
        let now = o.now, windowFull = meter.windowFull
        let rate = o.weightLastHour / windowFull * 100
        if let r = meter.fiveHour, r.resetsAt > now {
            // The meter moves only when some session answers; the transcripts fill the gap since.
            let since = max(0, o.weightInWindow - weight(in: o.windowCurve, start: o.windowStart, at: r.time))
            let used = r.percent + since / windowFull * 100
            return Limit(used: used, resetsAt: r.resetsAt, estimated: false,
                         forecast: LimitMath.forecast(used: used, resetsAt: r.resetsAt, rate: rate, now: now))
        }
        let used = o.weightInWindow / windowFull * 100
        let reset = now.addingTimeInterval(5 * 3600)
        return Limit(used: used, resetsAt: reset, estimated: true,
                     forecast: LimitMath.forecast(used: used, resetsAt: reset, rate: rate, now: now))
    }

    private func weekLimit(_ meter: Meter) -> Limit? {
        guard let o = meter.overview else { return nil }
        let now = o.now, weekFull = meter.weekFull
        let used: Double
        let reset: Date
        let estimated: Bool
        if let r = meter.sevenDay, r.resetsAt > now {
            let since = max(0, o.weightInWeek - weight(in: o.weekCurve, start: o.weekStart, at: r.time))
            used = r.percent + since / weekFull * 100
            reset = r.resetsAt
            estimated = false
        } else {
            used = o.weightInWeek / weekFull * 100
            reset = now.addingTimeInterval(7 * 86_400)
            estimated = true
        }
        let hours = max(now.timeIntervalSince(o.weekStart) / 3600, 1)
        let rate = used / hours
        return Limit(used: used, resetsAt: reset, estimated: estimated,
                     forecast: LimitMath.forecast(used: used, resetsAt: reset, rate: rate, now: now))
    }

    /// Percent of the 5 h window for an amount of weight.
    func windowPercent(_ weight: Double) -> Double { weight / windowFull * 100 }
    func weekPercent(_ weight: Double) -> Double { weight / weekFull * 100 }

    /// The 5 h window runs out before it resets.
    var windowAtRisk: Bool {
        guard let limit = fiveHourLimit, !limit.estimated else { return false }
        return limit.forecast.runsOutAt != nil
    }

    /// The accounts in the app and the 5 h window of each, for the picker beside the meter.
    var accountLimits: [(account: String, limit: Limit?)] {
        (model?.config.accounts ?? []).map { ($0.name, fiveHourLimit(meters[$0.name] ?? Meter())) }
    }

    // MARK: One session

    func tokens(_ runtime: SessionRuntime) -> SessionTokens? {
        runtime.claudeSessionId.flatMap { sessions[$0] }
    }

    /// Exact from the status line when it is newer than the transcript.
    func context(_ runtime: SessionRuntime) -> Int? {
        let fromLedger = tokens(runtime)
        if let id = runtime.claudeSessionId, let e = exact[id], e.at >= (fromLedger?.lastCall ?? .distantPast) { return e.tokens }
        return fromLedger.map(\.context)
    }

    func contextLimit(_ runtime: SessionRuntime) -> Int {
        runtime.claudeSessionId.flatMap { exact[$0]?.size } ?? Self.contextDefault
    }

    /// Context grew more than 50 mil in the last ten minutes.
    func risingFast(_ runtime: SessionRuntime) -> Bool {
        (tokens(runtime)?.growthLast10 ?? 0) >= 50_000
    }

    func nearCeiling(_ runtime: SessionRuntime) -> Bool {
        guard let context = context(runtime) else { return false }
        return Double(context) >= Double(contextLimit(runtime)) * 0.9
    }

    /// When the context reaches the point where Claude Code compacts, at the last hour's pace.
    func nextCompaction(_ runtime: SessionRuntime, now: Date = Date()) -> Date? {
        guard let s = tokens(runtime), s.growthPerHour > 1000, let context = context(runtime) else { return nil }
        let room = Double(contextLimit(runtime)) * 0.95 - Double(context)
        guard room > 0 else { return now }
        return now.addingTimeInterval(room / s.growthPerHour * 3600)
    }

    /// The session spending the most right now, among the open ones of the account shown.
    var hottest: (runtime: SessionRuntime, rate: Double)? {
        guard let model else { return nil }
        let ranked = model.sessions.compactMap { runtime -> (SessionRuntime, Double)? in
            guard account(of: runtime) == meterAccount, let s = tokens(runtime), s.weightLastHour > 0 else { return nil }
            return (runtime, windowPercent(s.weightLastHour))
        }
        return ranked.max { $0.1 < $1.1 }.map { (runtime: $0.0, rate: $0.1) }
    }

    // MARK: Alert

    /// Once per window and account: the pace of the last ten minutes empties it before it resets.
    private func checkAlert(_ account: String) {
        let meter = meters[account] ?? Meter()
        guard let o = meter.overview, let limit = fiveHourLimit(meter), !limit.estimated, limit.used >= 10, limit.used < 100 else { return }
        let now = o.now
        let rate = o.weightLast10 / meter.windowFull * 100 * 6
        guard rate > 0 else { return }
        let runsOut = now.addingTimeInterval((100 - limit.used) / rate * 3600)
        guard runsOut < limit.resetsAt.addingTimeInterval(-10 * 60), runsOut.timeIntervalSince(now) < 90 * 60 else { return }
        guard alertedWindow[account].map({ abs($0.timeIntervalSince(limit.resetsAt)) > 120 }) ?? true else { return }
        alertedWindow[account] = limit.resetsAt

        var body = "Só renova às \(TokenFormat.clock(limit.resetsAt))."
        if let model, model.config.accounts.count > 1 { body = "Conta \(model.accountLabel(account)). " + body }
        var target = UUID()
        if let model, let top = model.sessions.filter({ self.account(of: $0) == account })
            .compactMap({ r -> (SessionRuntime, SessionTokens)? in tokens(r).map { (r, $0) } })
            .max(by: { $0.1.weightLast10 < $1.1.weightLast10 }), o.weightLast10 > 0 {
            let share = Int((top.1.weightLast10 / o.weightLast10 * 100).rounded())
            let project = model.project(top.0.projectId)?.project.name ?? ""
            var who = "\(model.displayLabel(top.0)), em \(project),"
            if top.1.activeAgents > 0 { who += " com \(top.1.activeAgents) \(top.1.activeAgents == 1 ? "agente" : "agentes")," }
            body += " \(who) fez \(share)% do gasto dos últimos 10 min."
            target = top.0.id
        }
        Notifier.shared.post(title: "A janela de 5 h acaba perto das \(TokenFormat.clock(runsOut))", body: body, sessionId: target)
    }

    // MARK: Files

    /// An account's readings, read from `limit-readings-<account>.json` the first time. Until the
    /// account of Claude Code's own folder has its file, the single file of earlier versions is read.
    private func loadedReadings(_ account: String) -> LimitReadings {
        if let saved = readings[account] { return saved }
        let own = model?.config.account(named: account).map { $0.configDirectory == nil } ?? false
        let saved = LimitReadingStore(account: account).load(legacy: own)
        readings[account] = saved
        var meter = meters[account] ?? Meter()
        meter.fiveHour = saved.fiveHour.last
        meter.sevenDay = saved.sevenDay.last
        if meters[account] != meter { meters[account] = meter }
        return saved
    }

    private func saveReadings(_ account: String) {
        pendingSave[account]?.cancel()
        let saved = readings[account] ?? LimitReadings()
        let store = LimitReadingStore(account: account)
        let work = DispatchWorkItem {
            try? store.save(saved)
        }
        pendingSave[account] = work
        files.asyncAfter(deadline: .now() + 2, execute: work)
    }
}

/// Numbers the way the app writes them: "549 mil", "1,2 mi", "41%", "0,6%", "20:40".
enum TokenFormat {
    static func tokens(_ value: Int) -> String {
        if value >= 1_000_000 {
            let m = Double(value) / 1_000_000
            return (m >= 10 || m.rounded() == m ? "\(Int(m.rounded()))" : decimal(m)) + " mi"
        }
        if value >= 1000 { return "\(Int((Double(value) / 1000).rounded())) mil" }
        return "\(value)"
    }

    static func percent(_ value: Double) -> String {
        if value > 0, value < 10, (value * 10).rounded() != (value.rounded() * 10) { return decimal(value) + "%" }
        return "\(Int(value.rounded()))%"
    }

    static func decimal(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".", with: ",")
    }

    static func clock(_ date: Date) -> String {
        date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits))
    }

    /// "20:40", "amanhã, 09:00" or "terça, 09:00".
    static func moment(_ date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return clock(date) }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(date, inSameDayAs: tomorrow) {
            return "amanhã, \(clock(date))"
        }
        let day = date.formatted(.dateTime.weekday(.wide).locale(Locale(identifier: "pt_BR")))
        return "\(day), \(clock(date))"
    }

    /// "qua", "sáb": short weekday without the period.
    static func weekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).locale(Locale(identifier: "pt_BR"))).replacingOccurrences(of: ".", with: "")
    }

    /// "1 h 56 min", "25 min".
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(Int((seconds / 60).rounded()), 0)
        if minutes < 60 { return "\(minutes) min" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
