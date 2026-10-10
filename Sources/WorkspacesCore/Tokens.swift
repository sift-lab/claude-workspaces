import Foundation

// MARK: Price

/// What a call costs, in input tokens of Opus. Only the proportions matter: they turn tokens of
/// different kinds into one number that moves the way the account's limit moves.
public enum TokenPrice {
    public static let output = 5.0
    public static let cacheWrite = 1.25
    public static let cacheRead = 0.1

    /// Fable counts about four times as much against the limit (measured on the weekly meter).
    public static func modelFactor(_ model: String) -> Double {
        let name = model.lowercased()
        if name.contains("fable") { return 4 }
        if name.contains("haiku") { return 0.2 }
        if name.contains("sonnet") { return 0.6 }
        return 1
    }

    /// "Opus 5.5" from "claude-opus-5-5".
    public static func family(_ model: String) -> String {
        let name = model.lowercased()
        for family in ["fable", "opus", "sonnet", "haiku"] where name.contains(family) {
            let rest: String = name.components(separatedBy: family).last ?? ""
            var digits: [String] = []
            for part in rest.components(separatedBy: "-") where !part.isEmpty && part.count <= 2 && part.allSatisfy(\.isNumber) {
                digits.append(part)
            }
            let version = digits.prefix(2).joined(separator: ".")
            return family.prefix(1).uppercased() + family.dropFirst() + (version.isEmpty ? "" : " " + version)
        }
        return model
    }
}

// MARK: Transcript lines

/// The usage of one API call, read from a line of a Claude Code transcript.
public struct TokenCall: Equatable, Sendable {
    /// Message id and request id: Claude Code writes a message once per content block.
    public var key: String
    public var time: Date
    /// Claude's session id. Agents carry the id of the session that started them.
    public var session: String
    public var input: Int
    public var output: Int
    public var cacheRead: Int
    public var cacheWrite: Int
    public var model: String
    public var cwd: String?
    public var branch: String?

    public init(key: String, time: Date, session: String, input: Int = 0, output: Int = 0, cacheRead: Int = 0,
                cacheWrite: Int = 0, model: String = "claude-opus-5-5", cwd: String? = nil, branch: String? = nil) {
        self.key = key
        self.time = time
        self.session = session
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
        self.model = model
        self.cwd = cwd
        self.branch = branch
    }

    /// Everything the model read for this answer: the context at that moment.
    public var context: Int { input + cacheRead + cacheWrite }
}

public enum Transcript {
    static let usageMarker = Array("\"usage\"".utf8)
    static let assistantMarker = Array("\"assistant\"".utf8)

    /// The usage of an assistant line, nil for every other line. Lines without usage cost a byte search.
    public static func call(fromLine line: Data) -> TokenCall? {
        guard contains(line, usageMarker), contains(line, assistantMarker) else { return nil }
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let session = object["sessionId"] as? String,
              let stamp = object["timestamp"] as? String, let time = parseTime(stamp) else { return nil }
        let model = message["model"] as? String ?? ""
        // Local messages (errors, interruptions) carry zero usage under this model name.
        guard model != "<synthetic>" else { return nil }
        func count(_ key: String) -> Int { (usage[key] as? NSNumber)?.intValue ?? 0 }
        return TokenCall(key: (message["id"] as? String ?? stamp) + "|" + (object["requestId"] as? String ?? ""),
                         time: time, session: session,
                         input: count("input_tokens"), output: count("output_tokens"),
                         cacheRead: count("cache_read_input_tokens"), cacheWrite: count("cache_creation_input_tokens"),
                         model: model, cwd: object["cwd"] as? String, branch: object["gitBranch"] as? String)
    }

    static func contains(_ data: Data, _ needle: [UInt8]) -> Bool {
        data.withUnsafeBytes { raw in
            needle.withUnsafeBytes { n in
                guard let base = raw.baseAddress, let nb = n.baseAddress else { return false }
                return memmem(base, raw.count, nb, n.count) != nil
            }
        }
    }

    private static let fallbackFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// "2026-10-02T18:31:05.123Z", the shape Claude Code writes, parsed by hand: a formatter per line
    /// is most of the cost of reading a week of transcripts.
    public static func parseTime(_ text: String) -> Date? {
        let b = Array(text.utf8)
        func digits(_ from: Int, _ count: Int) -> Int? {
            guard from + count <= b.count else { return nil }
            var value = 0
            for i in from..<(from + count) {
                let c = b[i]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            return value
        }
        guard b.count >= 20, b.last == UInt8(ascii: "Z"), b[4] == UInt8(ascii: "-"), b[10] == UInt8(ascii: "T"),
              let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
              let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2) else {
            return fallbackFormatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
        }
        var fraction = 0.0
        if b.count > 21, b[19] == UInt8(ascii: ".") {
            var scale = 0.1
            for i in 20..<(b.count - 1) {
                let c = b[i]
                guard c >= 48, c <= 57 else { break }
                fraction += Double(c - 48) * scale
                scale /= 10
            }
        }
        let days = daysFromCivil(year, month, day)
        let seconds = Double(days * 86_400 + hour * 3600 + minute * 60 + second) + fraction
        return Date(timeIntervalSince1970: seconds)
    }

    /// Days since 1970-01-01 (Howard Hinnant's algorithm).
    static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yoe = y - era * 400
        let mp = (month + 9) % 12
        let doy = (153 * mp + 2) / 5 + day - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }
}

// MARK: Ledger

/// Every call read so far, deduplicated, kept compact so two weeks fit in a few megabytes.
/// Not thread safe: one queue owns it.
public final class TokenLedger: @unchecked Sendable {
    public struct Entry: Sendable {
        public var time: Double
        public var session: Int32
        /// -1 for the conversation itself; otherwise which agent transcript it came from.
        public var agent: Int32
        public var model: Int32
        public var context: Int32
        /// Weights (see TokenPrice) by kind of token.
        public var input: Float
        public var output: Float
        public var cacheRead: Float
        public var cacheWrite: Float

        public var weight: Double { Double(input) + Double(output) + Double(cacheRead) + Double(cacheWrite) }
        public var isAgent: Bool { agent >= 0 }
    }

    public struct SessionMeta: Sendable, Equatable {
        public var id: String
        public var cwd: String?
        public var branch: String?
        public var model: String?
    }

    public private(set) var entries: [Entry] = []
    public private(set) var sessions: [SessionMeta] = []
    public private(set) var models: [String] = []
    private var sessionIndex: [String: Int32] = [:]
    private var agentIndex: [String: Int32] = [:]
    private var modelIndex: [String: Int32] = [:]
    private var seen: Set<String> = []

    public init() {}

    /// False when the call was already counted.
    @discardableResult
    public func add(_ call: TokenCall, agent: String? = nil) -> Bool {
        guard seen.insert(call.key).inserted else { return false }
        let s = index(of: call.session)
        if agent == nil || sessions[Int(s)].cwd == nil {
            if let cwd = call.cwd { sessions[Int(s)].cwd = cwd }
            if let branch = call.branch, !branch.isEmpty { sessions[Int(s)].branch = branch }
        }
        if agent == nil { sessions[Int(s)].model = call.model }
        let a: Int32 = agent.map { key in
            if let i = agentIndex[key] { return i }
            let i = Int32(agentIndex.count)
            agentIndex[key] = i
            return i
        } ?? -1
        let m: Int32 = {
            if let i = modelIndex[call.model] { return i }
            let i = Int32(models.count)
            models.append(call.model)
            modelIndex[call.model] = i
            return i
        }()
        let f = TokenPrice.modelFactor(call.model)
        entries.append(Entry(time: call.time.timeIntervalSince1970, session: s, agent: a, model: m,
                             context: Int32(clamping: call.context),
                             input: Float(Double(call.input) * f),
                             output: Float(Double(call.output) * TokenPrice.output * f),
                             cacheRead: Float(Double(call.cacheRead) * TokenPrice.cacheRead * f),
                             cacheWrite: Float(Double(call.cacheWrite) * TokenPrice.cacheWrite * f)))
        return true
    }

    private func index(of session: String) -> Int32 {
        if let i = sessionIndex[session] { return i }
        let i = Int32(sessions.count)
        sessions.append(SessionMeta(id: session))
        sessionIndex[session] = i
        return i
    }

    public func index(ofSession id: String) -> Int32? { sessionIndex[id] }

    /// Drops calls older than `date`. Their keys stay, so a line read again is never counted twice.
    public func prune(before date: Date) {
        let t = date.timeIntervalSince1970
        entries.removeAll { $0.time < t }
    }

    /// The most ever spent in any stretch of `span` seconds between two moments. The account's
    /// window holds at least that much, since local use never goes past the limit.
    public func heaviest(span: TimeInterval, from: Date, to: Date, only filter: LedgerFilter? = nil) -> Double {
        let a = from.timeIntervalSince1970, b = to.timeIntervalSince1970
        let points = entries.filter { $0.time >= a && $0.time < b && Self.counts($0, filter) }.map { ($0.time, $0.weight) }.sorted { $0.0 < $1.0 }
        var best = 0.0, sum = 0.0, j = 0
        for i in points.indices {
            sum += points[i].1
            while points[i].0 - points[j].0 > span {
                sum -= points[j].1
                j += 1
            }
            best = max(best, sum)
        }
        return best
    }

    /// Weight spent between two moments, by everyone or by one session (agents included).
    public func weight(from: Date, to: Date = .distantFuture, session: String? = nil, only filter: LedgerFilter? = nil) -> Double {
        let a = from.timeIntervalSince1970, b = to.timeIntervalSince1970
        let s = session.flatMap { sessionIndex[$0] }
        if session != nil, s == nil { return 0 }
        var total = 0.0
        for e in entries where e.time >= a && e.time < b && (s == nil || e.session == s) && Self.counts(e, filter) { total += e.weight }
        return total
    }

    /// What counts in the `only` of the sums: the spend of one account, per session and moment.
    /// A session the ledger learns after the filter was made does not count.
    public func filter(_ changes: (String) -> [LedgerFilter.Change]) -> LedgerFilter {
        LedgerFilter(changes: sessions.map { changes($0.id).sorted { $0.from < $1.from } })
    }

    static func counts(_ e: Entry, _ filter: LedgerFilter?) -> Bool {
        filter?.counts(e) ?? true
    }
}

/// Which calls count in a sum. Per session, the moments from which it counts or stops counting;
/// before the first one, the first one holds. A session with none never counts.
public struct LedgerFilter: Sendable {
    public struct Change: Equatable, Sendable {
        public var from: Double
        public var counts: Bool

        public init(from: Double, counts: Bool) {
            self.from = from
            self.counts = counts
        }
    }

    let changes: [[Change]]

    func counts(_ e: TokenLedger.Entry) -> Bool {
        let i = Int(e.session)
        guard i < changes.count, let first = changes[i].first else { return false }
        var result = first.counts
        for change in changes[i] {
            guard change.from <= e.time else { break }
            result = change.counts
        }
        return result
    }
}

// MARK: Scanner

/// Reads what each transcript gained since the last scan, from the byte where it stopped.
public final class TranscriptScanner: @unchecked Sendable {
    public let root: URL
    private var offsets: [String: UInt64] = [:]

    public init(root: URL) {
        self.root = root
    }

    /// Files not touched since `since` are skipped. Returns how many new calls were added.
    /// Files are parsed on a few threads; the ledger is only touched here, in order.
    @discardableResult
    public func scan(into ledger: TokenLedger, since: Date, parallelism: Int = 4) -> Int {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return 0 }
        struct Job { var url: URL; var path: String; var offset: UInt64; var agent: String? }
        var jobs: [Job] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                  let modified = values.contentModificationDate, modified >= since,
                  let size = values.fileSize.map(UInt64.init) else { continue }
            let path = url.path
            var offset = offsets[path] ?? 0
            if size < offset { offset = 0 }
            guard size > offset else { continue }
            let agent = path.contains("/subagents/") ? url.deletingPathExtension().lastPathComponent : nil
            jobs.append(Job(url: url, path: path, offset: offset, agent: agent))
        }
        guard !jobs.isEmpty else { return 0 }

        let lanes = max(1, min(parallelism, jobs.count))
        var results = Array(repeating: [(job: Int, offset: UInt64, calls: [TokenCall])](), count: lanes)
        results.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                var mine: [(job: Int, offset: UInt64, calls: [TokenCall])] = []
                var i = lane
                while i < jobs.count {
                    let read = Self.read(jobs[i].url, from: jobs[i].offset)
                    mine.append((i, read.offset, read.calls))
                    i += lanes
                }
                buffer[lane] = mine
            }
        }
        var added = 0
        for result in results.joined().sorted(by: { $0.job < $1.job }) {
            let job = jobs[result.job]
            offsets[job.path] = result.offset
            for call in result.calls where ledger.add(call, agent: job.agent) { added += 1 }
        }
        return added
    }

    /// Only complete lines are read; a line still being written is picked up next time.
    private static func read(_ url: URL, from offset: UInt64) -> (offset: UInt64, calls: [TokenCall]) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return (offset, []) }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil else { return (offset, []) }
        var consumed = offset
        var calls: [TokenCall] = []
        var pending = Data()
        while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            pending.append(chunk)
            var candidates: [Range<Int>] = []
            var end = 0
            pending.withUnsafeBytes { raw in
                guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return }
                var start = 0
                while start < raw.count, let hit = memchr(base + start, 0x0A, raw.count - start) {
                    let newline = base.distance(to: hit.assumingMemoryBound(to: UInt8.self))
                    let length = newline - start
                    let line = UnsafeRawPointer(base + start)
                    if length > 0, Transcript.usageMarker.withUnsafeBytes({ memmem(line, length, $0.baseAddress!, $0.count) }) != nil {
                        candidates.append(start..<newline)
                    }
                    start = newline + 1
                }
                end = start
            }
            for range in candidates {
                if let call = Transcript.call(fromLine: pending.subdata(in: range)) { calls.append(call) }
            }
            if end > 0 {
                consumed += UInt64(end)
                pending = end < pending.count ? pending.subdata(in: end..<pending.count) : Data()
            }
        }
        return (consumed, calls)
    }
}

// MARK: One session

public struct ContextPoint: Equatable, Sendable, Identifiable {
    public var time: Date
    public var tokens: Int
    public var id: Date { time }

    public init(time: Date, tokens: Int) {
        self.time = time
        self.tokens = tokens
    }
}

/// The context fell to less than half: Claude Code compacted (or the conversation was cleared).
public struct Compaction: Equatable, Sendable, Identifiable {
    public var time: Date
    public var before: Int
    public var after: Int
    public var id: Date { time }
}

public struct CostBin: Equatable, Sendable, Identifiable {
    public var start: Date
    public var weight: Double
    /// Part of `weight` spent by agents.
    public var agents: Double
    public var id: Date { start }
}

public struct SessionTokens: Equatable, Sendable {
    public var id: String
    public var cwd: String?
    public var branch: String?
    public var model: String?
    /// Context of the last answer in the conversation.
    public var context: Int
    public var lastCall: Date?
    /// The conversation's context at each answer since `from`.
    public var points: [ContextPoint]
    public var compactions: [Compaction]
    /// Five-minute bins since `from`.
    public var bins: [CostBin]
    public var weightSinceFrom: Double
    public var agentWeightSinceFrom: Double
    public var weightInWindow: Double
    public var weightLastHour: Double
    public var weightLast10: Double
    /// Agents that answered in the last two minutes.
    public var activeAgents: Int
    /// Tokens per hour the context grew over the last hour (since the last compaction, if later).
    public var growthPerHour: Double
    /// Context gained in the last ten minutes.
    public var growthLast10: Int
}

public extension TokenLedger {
    func session(_ id: String, from: Date, windowStart: Date, now: Date, maxPoints: Int = 900) -> SessionTokens? {
        guard let s = sessionIndex[id] else { return nil }
        let meta = sessions[Int(s)]
        var mine = entries.filter { $0.session == s }
        guard !mine.isEmpty else { return nil }
        mine.sort { $0.time < $1.time }
        let t0 = from.timeIntervalSince1970, tw = windowStart.timeIntervalSince1970, tn = now.timeIntervalSince1970
        let main = mine.filter { !$0.isAgent }

        var points: [ContextPoint] = []
        var compactions: [Compaction] = []
        var previous: Entry?
        for e in main {
            if let p = previous, p.context >= 60_000, e.context * 2 < p.context, e.time >= t0 {
                compactions.append(Compaction(time: Date(timeIntervalSince1970: e.time), before: Int(p.context), after: Int(e.context)))
            }
            if e.time >= t0 { points.append(ContextPoint(time: Date(timeIntervalSince1970: e.time), tokens: Int(e.context))) }
            previous = e
        }
        points = thin(points, compactions: compactions, limit: maxPoints)

        var bins: [CostBin] = []
        let binSize = 300.0
        if tn > t0 {
            let first = (t0 / binSize).rounded(.down) * binSize
            let count = Int(((tn - first) / binSize).rounded(.up))
            bins = (0..<max(count, 0)).map { CostBin(start: Date(timeIntervalSince1970: first + Double($0) * binSize), weight: 0, agents: 0) }
            for e in mine where e.time >= first {
                let i = Int((e.time - first) / binSize)
                guard i >= 0, i < bins.count else { continue }
                bins[i].weight += e.weight
                if e.isAgent { bins[i].agents += e.weight }
            }
        }

        var since = 0.0, agentSince = 0.0, window = 0.0, hour = 0.0, ten = 0.0
        var agents: Set<Int32> = []
        for e in mine {
            let w = e.weight
            if e.time >= t0 { since += w; if e.isAgent { agentSince += w } }
            if e.time >= tw { window += w }
            if e.time >= tn - 3600 { hour += w }
            if e.time >= tn - 600 { ten += w }
            if e.isAgent, e.time >= tn - 120 { agents.insert(e.agent) }
        }

        let last = main.last
        let context = Int(last?.context ?? 0)
        func contextAt(_ t: Double) -> Int? { main.last { $0.time <= t }.map { Int($0.context) } }
        var growth = 0.0
        if let last, last.time >= tn - 3600 {
            let lastCut = compactions.last.map { $0.time.timeIntervalSince1970 } ?? 0
            if lastCut > tn - 3600 {
                if let cut = compactions.last { growth = Double(context - cut.after) / max((tn - lastCut) / 3600, 0.25) }
            } else if let before = contextAt(tn - 3600) {
                growth = Double(context - before)
            }
        }
        var growth10 = 0
        if let last, last.time >= tn - 600, let before = contextAt(tn - 600),
           !compactions.contains(where: { $0.time.timeIntervalSince1970 > tn - 600 }) {
            growth10 = context - before
        }

        return SessionTokens(id: id, cwd: meta.cwd, branch: meta.branch, model: meta.model, context: context,
                             lastCall: last.map { Date(timeIntervalSince1970: $0.time) },
                             points: points, compactions: compactions, bins: bins,
                             weightSinceFrom: since, agentWeightSinceFrom: agentSince, weightInWindow: window,
                             weightLastHour: hour, weightLast10: ten, activeAgents: agents.count,
                             growthPerHour: max(growth, 0), growthLast10: max(growth10, 0))
    }

    /// Keeps the shape (every compaction's edges) with at most about `limit` points.
    private func thin(_ points: [ContextPoint], compactions: [Compaction], limit: Int) -> [ContextPoint] {
        guard points.count > limit else { return points }
        let step = Int((Double(points.count) / Double(limit)).rounded(.up))
        let cuts = Set(compactions.map(\.time))
        var kept: [ContextPoint] = []
        for (i, p) in points.enumerated() {
            let edge = cuts.contains(p.time) || (i + 1 < points.count && cuts.contains(points[i + 1].time))
            if i % step == 0 || edge || i == points.count - 1 { kept.append(p) }
        }
        return kept
    }
}

// MARK: Everyone

public struct SessionSummary: Equatable, Sendable, Identifiable {
    public var id: String
    public var cwd: String?
    public var branch: String?
    public var weight: Double
    public var agentWeight: Double
    public var peak: Int
    public var context: Int
    public var compactions: Int
    public var first: Date
    public var last: Date
}

public struct DayUsage: Equatable, Sendable, Identifiable {
    public var day: Date
    /// Weight per group (a workspace, or "Outros").
    public var groups: [String: Double]
    public var id: Date { day }
    public var total: Double { groups.values.reduce(0, +) }
}

public struct CurvePoint: Equatable, Sendable, Identifiable {
    /// Seconds since the start of the window.
    public var offset: TimeInterval
    /// Weight spent from the start of the window to here.
    public var weight: Double
    public var id: TimeInterval { offset }
}

public struct TokenOverview: Equatable, Sendable {
    public var now: Date
    public var windowStart: Date
    public var weekStart: Date
    /// Cumulative weight in the 5 h window, every ten minutes.
    public var windowCurve: [CurvePoint]
    public var weightInWindow: Double
    public var weightLastHour: Double
    public var weightLast10: Double
    /// Cumulative weight this week and the week before, every two hours.
    public var weekCurve: [CurvePoint]
    public var lastWeekCurve: [CurvePoint]
    public var weightInWeek: Double
    public var days: [DayUsage]
    /// The last seven days.
    public var cacheRead: Double
    public var cacheWrite: Double
    public var output: Double
    public var input: Double
    public var agentWeight: Double
    public var modelWeights: [String: Double]
    public var topSessions: [SessionSummary]
    /// Everyone who spent in the 5 h window, most first.
    public var windowSessions: [SessionSummary]

    public var total: Double { cacheRead + cacheWrite + output + input }
}

public extension TokenLedger {
    /// `group` names the group of a working folder (a workspace); `days` counts back from today;
    /// `only` keeps the sessions of one account.
    func overview(now: Date, windowStart: Date, weekStart: Date, days dayCount: Int = 14,
                  calendar: Calendar = .current, only filter: LedgerFilter? = nil, group: (String?) -> String) -> TokenOverview {
        let tn = now.timeIntervalSince1970, tw = windowStart.timeIntervalSince1970, tk = weekStart.timeIntervalSince1970
        let tPrev = tk - 7 * 86_400
        let t7 = tn - 7 * 86_400
        let today = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -(dayCount - 1), to: today) ?? today
        let tDays = firstDay.timeIntervalSince1970

        var dayStarts: [Double] = []
        for i in 0...dayCount {
            dayStarts.append((calendar.date(byAdding: .day, value: i, to: firstDay) ?? firstDay).timeIntervalSince1970)
        }
        var dayGroups = Array(repeating: [String: Double](), count: dayCount)
        var groupCache: [Int32: String] = [:]

        let windowSteps = Int(((tn - tw) / 600).rounded(.up)) + 1
        var windowBins = Array(repeating: 0.0, count: max(windowSteps, 1))
        let weekSteps = Int((7 * 86_400.0) / 7200)
        var weekBins = Array(repeating: 0.0, count: weekSteps + 1)
        var lastWeekBins = Array(repeating: 0.0, count: weekSteps + 1)

        var inWindow = 0.0, hour = 0.0, ten = 0.0, inWeek = 0.0
        var read = 0.0, write = 0.0, out = 0.0, inp = 0.0, agent = 0.0
        var modelWeights: [String: Double] = [:]
        struct Acc { var weight = 0.0, agent = 0.0, peak: Int32 = 0, first = Double.infinity, last = 0.0, lastContext: Int32 = 0, lastMainTime = 0.0 }
        var week: [Int32: Acc] = [:]
        var window: [Int32: Acc] = [:]

        for e in entries where Self.counts(e, filter) {
            let t = e.time, w = e.weight
            if t >= tw, t <= tn {
                inWindow += w
                windowBins[min(Int((t - tw) / 600), windowBins.count - 1)] += w
                var a = window[e.session] ?? Acc()
                a.weight += w
                if !e.isAgent, t >= a.lastMainTime { a.lastMainTime = t; a.lastContext = e.context }
                a.first = min(a.first, t); a.last = max(a.last, t)
                window[e.session] = a
            }
            if t >= tn - 3600 { hour += w }
            if t >= tn - 600 { ten += w }
            if t >= tk, t <= tn {
                inWeek += w
                weekBins[min(Int((t - tk) / 7200), weekSteps)] += w
            } else if t >= tPrev, t < tk {
                lastWeekBins[min(Int((t - tPrev) / 7200), weekSteps)] += w
            }
            if t >= tDays, t < dayStarts[dayCount] {
                var d = 0
                while d + 1 < dayStarts.count, t >= dayStarts[d + 1] { d += 1 }
                if d < dayCount {
                    let name: String
                    if let cached = groupCache[e.session] { name = cached } else {
                        name = group(sessions[Int(e.session)].cwd)
                        groupCache[e.session] = name
                    }
                    dayGroups[d][name, default: 0] += w
                }
            }
            if t >= t7 {
                read += Double(e.cacheRead); write += Double(e.cacheWrite); out += Double(e.output); inp += Double(e.input)
                if e.isAgent { agent += w }
                modelWeights[TokenPrice.family(models[Int(e.model)]), default: 0] += w
                var a = week[e.session] ?? Acc()
                a.weight += w
                if e.isAgent { a.agent += w } else {
                    a.peak = max(a.peak, e.context)
                    if t >= a.lastMainTime { a.lastMainTime = t; a.lastContext = e.context }
                }
                a.first = min(a.first, t); a.last = max(a.last, t)
                week[e.session] = a
            }
        }

        func curve(_ bins: [Double], step: Double, upTo: Double?) -> [CurvePoint] {
            var total = 0.0
            var points = [CurvePoint(offset: 0, weight: 0)]
            for (i, b) in bins.enumerated() {
                let end = Double(i + 1) * step
                total += b
                if let upTo, end >= upTo {
                    points.append(CurvePoint(offset: upTo, weight: total))
                    break
                }
                points.append(CurvePoint(offset: end, weight: total))
            }
            return points
        }

        func summaries(_ accs: [Int32: Acc], limit: Int) -> [SessionSummary] {
            accs.sorted { $0.value.weight > $1.value.weight }.prefix(limit).map { index, a in
                let meta = sessions[Int(index)]
                return SessionSummary(id: meta.id, cwd: meta.cwd, branch: meta.branch, weight: a.weight, agentWeight: a.agent,
                                      peak: Int(a.peak), context: Int(a.lastContext), compactions: compactionCount(index, from: t7),
                                      first: Date(timeIntervalSince1970: a.first), last: Date(timeIntervalSince1970: a.last))
            }
        }

        return TokenOverview(
            now: now, windowStart: windowStart, weekStart: weekStart,
            windowCurve: curve(windowBins, step: 600, upTo: tn - tw),
            weightInWindow: inWindow, weightLastHour: hour, weightLast10: ten,
            weekCurve: curve(weekBins, step: 7200, upTo: tn - tk),
            lastWeekCurve: curve(lastWeekBins, step: 7200, upTo: nil),
            weightInWeek: inWeek,
            days: (0..<dayCount).map { DayUsage(day: Date(timeIntervalSince1970: dayStarts[$0]), groups: dayGroups[$0]) },
            cacheRead: read, cacheWrite: write, output: out, input: inp, agentWeight: agent, modelWeights: modelWeights,
            topSessions: summaries(week, limit: 8), windowSessions: summaries(window, limit: 12))
    }

    private func compactionCount(_ session: Int32, from t: Double) -> Int {
        var count = 0
        var previous: Int32?
        for e in entries where e.session == session && !e.isAgent {
            if let p = previous, p >= 60_000, e.context * 2 < p, e.time >= t { count += 1 }
            previous = e.context
        }
        return count
    }
}

// MARK: The account's limit

/// One reading of the account's meter, from the status line.
public struct MeterReading: Codable, Equatable, Sendable {
    public var time: Date
    /// 0 to 100.
    public var percent: Double
    public var resetsAt: Date

    public init(time: Date, percent: Double, resetsAt: Date) {
        self.time = time
        self.percent = percent
        self.resetsAt = resetsAt
    }
}

public struct Forecast: Equatable, Sendable {
    public var used: Double
    public var resetsAt: Date
    /// Percent per hour.
    public var rate: Double
    /// Where the meter lands at the reset if the rate holds, uncapped.
    public var atReset: Double
    /// When it reaches 100% before the reset; nil when it does not.
    public var runsOutAt: Date?
}

public enum LimitMath {
    /// What 100% of each window holds in weight before the meter has said anything: rough figures
    /// from 01/10/2026, when one hour of agents took the 5 h window from 0 to 99%. The app raises
    /// them to the heaviest stretch it has seen, and replaces them once the meter calibrates.
    public static let defaultWindowWeight = 55_000_000.0
    public static let defaultWeekWeight = 1_700_000_000.0

    /// Weight that fills a window, from readings of the same window and what was spent between them.
    /// Rounded percents need a few points of distance to say anything.
    public static func fullWeight(readings: [MeterReading], minimumDelta: Double = 4,
                                  spent: (Date, Date) -> Double, fallback: Double) -> Double {
        var windows: [Int: [MeterReading]] = [:]
        for r in readings { windows[Int((r.resetsAt.timeIntervalSince1970 / 300).rounded()), default: []].append(r) }
        var estimates: [(Date, Double)] = []
        for group in windows.values {
            let sorted = group.sorted { $0.time < $1.time }
            guard let first = sorted.first, let last = sorted.last, last.percent - first.percent >= minimumDelta else { continue }
            let weight = spent(first.time, last.time)
            guard weight > 0 else { continue }
            estimates.append((last.time, weight / (last.percent - first.percent) * 100))
        }
        let recent = estimates.sorted { $0.0 > $1.0 }.prefix(7).map(\.1).sorted()
        guard !recent.isEmpty else { return fallback }
        return recent[recent.count / 2]
    }

    public static func forecast(used: Double, resetsAt: Date, rate: Double, now: Date) -> Forecast {
        let hours = max(resetsAt.timeIntervalSince(now) / 3600, 0)
        let atReset = used + rate * hours
        var runsOut: Date?
        if used >= 100 {
            runsOut = now
        } else if rate > 0 {
            let at = now.addingTimeInterval((100 - used) / rate * 3600)
            if at < resetsAt { runsOut = at }
        }
        return Forecast(used: used, resetsAt: resetsAt, rate: rate, atReset: atReset, runsOutAt: runsOut)
    }
}

// MARK: Status line

/// What Claude Code hands the status line command.
public struct StatusLineReading: Equatable, Sendable {
    public var sessionId: String?
    public var contextTokens: Int?
    public var contextSize: Int?
    public var model: String?
    public var projectDir: String?
    public var fiveHour: MeterReading?
    public var sevenDay: MeterReading?

    public init(sessionId: String? = nil, contextTokens: Int? = nil, contextSize: Int? = nil, model: String? = nil,
                projectDir: String? = nil, fiveHour: MeterReading? = nil, sevenDay: MeterReading? = nil) {
        self.sessionId = sessionId
        self.contextTokens = contextTokens
        self.contextSize = contextSize
        self.model = model
        self.projectDir = projectDir
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
    }

    public static func parse(_ payload: JSONValue, now: Date = Date()) -> StatusLineReading {
        func meter(_ key: String) -> MeterReading? {
            guard let o = payload["rate_limits"]?[key], let percent = o["used_percentage"]?.numberValue,
                  let resets = o["resets_at"]?.numberValue else { return nil }
            return MeterReading(time: now, percent: percent, resetsAt: Date(timeIntervalSince1970: resets))
        }
        let window = payload["context_window"]
        return StatusLineReading(
            sessionId: payload["session_id"]?.stringValue,
            contextTokens: window?["total_input_tokens"]?.numberValue.map { Int($0) },
            contextSize: window?["context_window_size"]?.numberValue.map { Int($0) },
            model: payload["model"]?["id"]?.stringValue,
            projectDir: payload["workspace"]?["project_dir"]?.stringValue ?? payload["cwd"]?.stringValue,
            fiveHour: meter("five_hour"),
            sevenDay: meter("seven_day"))
    }
}

/// `workspaces-hook statusline`: tells the app what Claude Code reported, then prints the person's own
/// status line, if they have one, since the app's `--settings` takes its place.
public enum StatusLineRelay {
    public static func run() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        let env = ProcessInfo.processInfo.environment
        let payload = JSONValue.parse(data) ?? .null
        if let session = env[ClaudeLaunch.sessionEnvKey] {
            _ = try? IPCClient.send(IPCRequest(kind: .statusLine, session: session, payload: payload,
                                              launch: env[ClaudeLaunch.launchEnvKey]), timeout: 1)
        }
        let projectDir = payload["workspace"]?["project_dir"]?.stringValue ?? payload["cwd"]?.stringValue
        guard let command = ownCommand(projectDir: projectDir, home: NSHomeDirectory()) else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        if let projectDir { process.currentDirectoryURL = URL(fileURLWithPath: projectDir) }
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        input.fileHandleForWriting.write(data)
        try? input.fileHandleForWriting.close()
        let text = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        FileHandle.standardOutput.write(text)
    }

    /// The person's status line command, in Claude Code's order: project local, project, user.
    public static func ownCommand(projectDir: String?, home: String) -> String? {
        var files: [String] = []
        if let projectDir {
            files += ["\(projectDir)/.claude/settings.local.json", "\(projectDir)/.claude/settings.json"]
        }
        files.append("\(home)/.claude/settings.json")
        for file in files {
            guard let data = FileManager.default.contents(atPath: file), let json = JSONValue.parse(data),
                  let line = json["statusLine"], let command = line["command"]?.stringValue,
                  !command.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let type = line["type"]?.stringValue, type != "command" { continue }
            return command
        }
        return nil
    }
}
