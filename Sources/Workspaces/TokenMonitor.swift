import AppKit
import Observation
import WorkspacesCore

/// Tokens the sessions spend and the account's limit. The transcripts are read in the background,
/// from where each one stopped; the meter comes from the status line Claude Code refreshes.
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

    private(set) var overview: TokenOverview?
    /// By Claude's session id; only the sessions open in the app.
    private(set) var sessions: [String: SessionTokens] = [:]
    private(set) var fiveHour: MeterReading?
    private(set) var sevenDay: MeterReading?
    private(set) var exact: [String: ExactContext] = [:]
    /// Weight that fills each window, calibrated from the meter's readings.
    private(set) var windowFull = LimitMath.defaultWindowWeight
    private(set) var weekFull = LimitMath.defaultWeekWeight
    /// The Consumo window shows this session in full.
    var focused: UUID?

    @ObservationIgnored weak var model: AppModel?
    @ObservationIgnored private let queue = DispatchQueue(label: "workspaces.tokens", qos: .utility)
    @ObservationIgnored private let ledger = TokenLedger()
    @ObservationIgnored private let scanner: TranscriptScanner
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var again = false
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var soon: DispatchWorkItem?
    @ObservationIgnored private var readings5: [MeterReading] = []
    @ObservationIgnored private var readings7: [MeterReading] = []
    @ObservationIgnored private var alertedWindow: Date?
    /// The heaviest 5 h and 7 days seen locally; sorting every call is too much for every tick.
    @ObservationIgnored private var floors: (at: Date, window: Double, week: Double)?
    @ObservationIgnored private var pendingSave: DispatchWorkItem?

    static let contextDefault = 1_000_000
    private nonisolated static let horizon: TimeInterval = 15 * 86_400

    init() {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        scanner = TranscriptScanner(root: home.appendingPathComponent(".claude/projects", isDirectory: true))
        loadReadings()
        fiveHour = readings5.last
        sevenDay = readings7.last
    }

    func start(model: AppModel) {
        self.model = model
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        timer?.tolerance = 3
    }

    // MARK: Status line

    func receive(_ reading: StatusLineReading, from runtime: SessionRuntime) {
        let now = Date()
        if let id = reading.sessionId ?? runtime.claudeSessionId, let tokens = reading.contextTokens, tokens > 0 {
            exact[id] = ExactContext(tokens: tokens, size: reading.contextSize, at: now)
        }
        var changed = false
        if let r = reading.fiveHour {
            var list = readings5
            if record(r, in: &list) { fiveHour = r }
            changed = changed || list.count != readings5.count || list.last?.percent != readings5.last?.percent
            readings5 = list
        }
        if let r = reading.sevenDay {
            var list = readings7
            if record(r, in: &list) { sevenDay = r }
            changed = changed || list.count != readings7.count || list.last?.percent != readings7.last?.percent
            readings7 = list
        }
        // Only a new value is written; the same value seen again just moves its time in memory.
        if changed { saveReadings() }
        // A new answer just landed somewhere: read it soon, not at the next tick.
        soon?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        soon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }

    /// Keeps only readings that changed something; returns true when the reading is the newest.
    private func record(_ reading: MeterReading, in list: inout [MeterReading]) -> Bool {
        if let last = list.last {
            guard reading.time >= last.time else { return false }
            if last.percent == reading.percent, abs(last.resetsAt.timeIntervalSince(reading.resetsAt)) < 60 {
                list[list.count - 1].time = reading.time
                return true
            }
        }
        list.append(reading)
        let cutoff = Date().addingTimeInterval(-Self.horizon)
        list.removeAll { $0.time < cutoff }
        if list.count > 3000 { list.removeFirst(list.count - 3000) }
        return true
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
        let windowStart = self.windowStart(now), weekStart = self.weekStart(now)
        let ids = Set(model.sessions.compactMap(\.claudeSessionId))
        let config = model.config
        let home = NSHomeDirectory()
        let today = Calendar.current.startOfDay(for: now)
        let from = min(today, now.addingTimeInterval(-6 * 3600))
        let r5 = readings5, r7 = readings7
        let known = floors.flatMap { now.timeIntervalSince($0.at) < 600 ? $0 : nil }
        let ledger = self.ledger, scanner = self.scanner
        queue.async { [weak self] in
            scanner.scan(into: ledger, since: now.addingTimeInterval(-Self.horizon))
            ledger.prune(before: now.addingTimeInterval(-Self.horizon - 86_400))
            let overview = ledger.overview(now: now, windowStart: windowStart, weekStart: weekStart) { cwd in
                cwd.flatMap { config.project(containing: $0, home: home)?.workspace.name } ?? "Outros"
            }
            var sessions: [String: SessionTokens] = [:]
            for id in ids {
                if let s = ledger.session(id, from: from, windowStart: windowStart, now: now) { sessions[id] = s }
            }
            // Before the meter calibrates, a window holds at least the heaviest stretch seen locally.
            let seen = now.addingTimeInterval(-Self.horizon)
            let floors = known ?? (at: now,
                                   window: max(LimitMath.defaultWindowWeight, ledger.heaviest(span: 5 * 3600, from: seen, to: now)),
                                   week: max(LimitMath.defaultWeekWeight, ledger.heaviest(span: 7 * 86_400, from: seen, to: now)))
            let floor5 = floors.window, floor7 = floors.week
            let full5 = LimitMath.fullWeight(readings: r5, spent: { ledger.weight(from: $0, to: $1) }, fallback: floor5)
            let full7 = LimitMath.fullWeight(readings: r7, minimumDelta: 3, spent: { ledger.weight(from: $0, to: $1) }, fallback: floor7)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.floors = floors
                    self.publish(overview: overview, sessions: sessions, full5: full5, full7: full7)
                }
            }
        }
    }

    private func publish(overview: TokenOverview, sessions: [String: SessionTokens], full5: Double, full7: Double) {
        if self.overview != overview { self.overview = overview }
        if self.sessions != sessions { self.sessions = sessions }
        if windowFull != full5 { windowFull = full5 }
        if weekFull != full7 { weekFull = full7 }
        busy = false
        checkAlert()
        if again {
            again = false
            refresh()
        }
    }

    // MARK: Windows

    func windowStart(_ now: Date) -> Date {
        if let r = fiveHour, r.resetsAt > now { return r.resetsAt.addingTimeInterval(-5 * 3600) }
        return now.addingTimeInterval(-5 * 3600)
    }

    func weekStart(_ now: Date) -> Date {
        if let r = sevenDay, r.resetsAt > now { return r.resetsAt.addingTimeInterval(-7 * 86_400) }
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

    var fiveHourLimit: Limit? {
        guard let o = overview else { return nil }
        let now = o.now
        let rate = o.weightLastHour / windowFull * 100
        if let r = fiveHour, r.resetsAt > now {
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

    var weekLimit: Limit? {
        guard let o = overview else { return nil }
        let now = o.now
        let used: Double
        let reset: Date
        let estimated: Bool
        if let r = sevenDay, r.resetsAt > now {
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

    /// The session spending the most right now, among the open ones.
    var hottest: (runtime: SessionRuntime, rate: Double)? {
        guard let model else { return nil }
        let ranked = model.sessions.compactMap { runtime -> (SessionRuntime, Double)? in
            guard let s = tokens(runtime), s.weightLastHour > 0 else { return nil }
            return (runtime, windowPercent(s.weightLastHour))
        }
        return ranked.max { $0.1 < $1.1 }.map { (runtime: $0.0, rate: $0.1) }
    }

    // MARK: Alert

    /// Once per window: the pace of the last ten minutes empties it before it resets.
    private func checkAlert() {
        guard let o = overview, let limit = fiveHourLimit, !limit.estimated, limit.used >= 10, limit.used < 100 else { return }
        let now = o.now
        let rate = windowPercent(o.weightLast10) * 6
        guard rate > 0 else { return }
        let runsOut = now.addingTimeInterval((100 - limit.used) / rate * 3600)
        guard runsOut < limit.resetsAt.addingTimeInterval(-10 * 60), runsOut.timeIntervalSince(now) < 90 * 60 else { return }
        guard alertedWindow.map({ abs($0.timeIntervalSince(limit.resetsAt)) > 120 }) ?? true else { return }
        alertedWindow = limit.resetsAt

        var body = "Só renova às \(TokenFormat.clock(limit.resetsAt))."
        var target = UUID()
        if let model, let top = model.sessions.compactMap({ r -> (SessionRuntime, SessionTokens)? in tokens(r).map { (r, $0) } })
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

    private struct Saved: Codable {
        var fiveHour: [MeterReading]
        var sevenDay: [MeterReading]
    }

    private var file: URL { AppPaths.supportDirectory.appendingPathComponent("limit-readings.json") }

    private func loadReadings() {
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        readings5 = saved.fiveHour
        readings7 = saved.sevenDay
    }

    private func saveReadings() {
        pendingSave?.cancel()
        let saved = Saved(fiveHour: readings5, sevenDay: readings7)
        let url = file
        let work = DispatchWorkItem {
            guard let data = try? JSONEncoder().encode(saved) else { return }
            try? data.write(to: url, options: .atomic)
        }
        pendingSave = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
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
