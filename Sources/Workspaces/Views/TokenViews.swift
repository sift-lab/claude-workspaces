import Charts
import SwiftUI
import WorkspacesCore

// Pieces of the token screens that show up in the session window, the sidebar and the menu bar.

extension Theme {
    /// The only color in the app: the 5 h window runs out before it resets.
    static let warning = Color(red: 0.91, green: 0.64, blue: 0.24)
    /// A session's context passed the alarm (500 mil): it needs its Passagem now.
    static let alarm = Color(red: 0.93, green: 0.34, blue: 0.3)
    /// Greys for groups in a stacked chart, light to dark, told apart by lightness.
    static let groupGreys: [Color] = [Color(white: 0.9), Color(white: 0.6), Color(white: 0.4), Color(white: 0.28)]
}

// MARK: Small marks

/// A short bar: how full the context is.
struct FillBar: View {
    let fraction: Double
    var width: CGFloat = 26
    var height: CGFloat = 4
    var fill: Color = Theme.primary

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Color.white.opacity(0.14))
            Capsule().fill(fill).frame(width: max(0, width * min(max(fraction, 0), 1)))
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

struct RisingArrow: View {
    var color: Color = Theme.support

    var body: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .accessibilityLabel("Subindo rápido")
    }
}

/// The 5 h window as a ring; amber only when it runs out before it resets.
struct LimitRing: View {
    let fraction: Double
    var alert = false
    var size: CGFloat = 16
    var line: CGFloat = 2

    var body: some View {
        ZStack {
            Circle().stroke(alert ? Theme.warning.opacity(0.25) : Color.white.opacity(0.14), lineWidth: line)
            Circle().trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(alert ? Theme.warning : Theme.primary, style: StrokeStyle(lineWidth: line, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// "3 agentes" with a small glyph.
struct AgentsLabel: View {
    let count: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "circle.grid.cross").font(.system(size: 9, weight: .medium))
            Text("\(count) \(count == 1 ? "agente" : "agentes")")
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
    }
}

/// Sidebar row: the context the session carries. Past the limit it reads "passagem", in red past the alarm.
struct TokenMark: View {
    let session: SessionRuntime
    @Environment(AppModel.self) private var model

    var body: some View {
        let tokens = model.tokens
        if !session.isTerminal, let context = tokens.context(session) {
            ContextTag(context: context, limits: model.contextLimits,
                       rising: session.sleep == .awake && tokens.risingFast(session))
        }
    }
}

/// "128k", or "412k passagem" past the limit.
struct ContextTag: View {
    let context: Int
    let limits: ContextLimits
    var rising = false

    var body: some View {
        let level = limits.level(context)
        HStack(spacing: 4) {
            if rising, level == .normal { RisingArrow() }
            // Not by color alone: the alarm also gets a glyph.
            if level == .alarm { Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)) }
            Text(ContextLimits.short(context))
                .font(.system(size: 11, weight: level == .normal ? .regular : .semibold).monospacedDigit())
            if level != .normal { Text("passagem").font(.system(size: 11)) }
        }
        .foregroundStyle(level == .alarm ? Theme.alarm : (level == .needsHandoff ? Theme.primary : Theme.tertiary))
        .help(ContextText.help(context, limits))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ContextText.help(context, limits))
    }
}

enum ContextText {
    static func help(_ context: Int, _ limits: ContextLimits) -> String {
        let base = "Contexto: \(TokenFormat.tokens(context))"
        switch limits.level(context) {
        case .normal:
            return base + ". Pede passagem acima de \(TokenFormat.tokens(limits.handoff))."
        case .needsHandoff:
            return base + ", acima do limite de \(TokenFormat.tokens(limits.handoff)). Precisa de passagem: escrever a Passagem no FRENTE.md e chamar recycle_self."
        case .alarm:
            return base + ", acima do alarme de \(TokenFormat.tokens(limits.alarm)). Precisa de passagem agora: escrever a Passagem no FRENTE.md e chamar recycle_self."
        }
    }
}

// MARK: Toolbar

/// Next to the session's state: how much context it carries. Opens the session's tokens.
struct ContextMeter: View {
    let session: SessionRuntime
    @Environment(AppModel.self) private var model
    @State private var open = false

    var body: some View {
        let tokens = model.tokens
        if !session.isTerminal, let context = tokens.context(session) {
            let limit = tokens.contextLimit(session)
            let near = tokens.nearCeiling(session)
            let level = model.contextLimits.level(context)
            let asleep = session.sleep != .awake
            let agents = tokens.tokens(session)?.activeAgents ?? 0
            Button { open.toggle() } label: {
                HStack(spacing: 7) {
                    FillBar(fraction: Double(context) / Double(limit),
                            fill: asleep ? Theme.faint : (level == .alarm ? Theme.alarm : Theme.primary))
                    Text(TokenFormat.tokens(context))
                        .font(.system(size: 12, weight: near || level != .normal ? .semibold : .regular).monospacedDigit())
                    if asleep {
                        Image(systemName: "moon").font(.system(size: 9, weight: .medium))
                    }
                    if level == .alarm {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                    }
                    if level != .normal {
                        Text("precisa de passagem").font(.system(size: 12))
                    } else if asleep {
                        EmptyView()
                    } else if near {
                        Text("compacta logo").font(.system(size: 12))
                    } else if tokens.risingFast(session) {
                        RisingArrow()
                    }
                    if agents > 0, !asleep { AgentsLabel(count: agents) }
                }
                .foregroundStyle(level == .alarm ? Theme.alarm : (asleep ? Theme.tertiary : Theme.primary))
                .padding(.leading, 8)
                .padding(.trailing, 9)
                .frame(height: 24)
                .background(Capsule().fill(open ? Theme.selected : (near ? Color(white: 0.16) : Theme.control)))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help("Contexto desta sessão: \(TokenFormat.tokens(context)) de \(TokenFormat.tokens(limit)). " + ContextText.help(context, model.contextLimits))
            .accessibilityLabel("Contexto da sessão: \(TokenFormat.tokens(context)) de \(TokenFormat.tokens(limit))")
            .popover(isPresented: $open, arrowEdge: .bottom) {
                SessionTokensPopover(session: session, close: { open = false })
                    .environment(model)
                    .preferredColorScheme(.dark)
            }
        }
    }
}

/// The toolbar's Consumo button: the 5 h window as a ring, with both windows on hover.
struct LimitButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let tokens = model.tokens
        Button {
            tokens.focused = nil
            openWindow(id: "usage")
        } label: {
            Group {
                if let limit = tokens.fiveHourLimit, !limit.estimated {
                    HStack(spacing: 6) {
                        LimitRing(fraction: limit.used / 100, alert: tokens.windowAtRisk)
                        Text(TokenFormat.percent(limit.used)).font(.system(size: 11).monospacedDigit())
                        if tokens.windowAtRisk {
                            Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(Theme.warning)
                        }
                    }
                    .padding(.horizontal, 6)
                } else {
                    Image(systemName: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 28)
                }
            }
            .foregroundStyle(Theme.support)
            .frame(height: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(LimitText.tooltip(tokens))
        .accessibilityLabel("Consumo. " + LimitText.tooltip(tokens))
    }
}

/// Sentences about the limit, shared by the tooltip, the menu bar and the Consumo window.
@MainActor
enum LimitText {
    static func fiveHour(_ limit: TokenMonitor.Limit) -> String {
        if limit.estimated { return "Estimado pelas últimas 5 h; a leitura da conta chega com a próxima resposta." }
        if let out = limit.forecast.runsOutAt {
            return "Acaba perto das \(TokenFormat.clock(out)) e só renova às \(TokenFormat.clock(limit.resetsAt))."
        }
        return "Renova às \(TokenFormat.clock(limit.resetsAt)). No ritmo da última hora, chega a \(TokenFormat.percent(min(limit.forecast.atReset, 100)))."
    }

    static func week(_ limit: TokenMonitor.Limit) -> String {
        if limit.estimated { return "Estimado pelos últimos 7 dias." }
        if let out = limit.forecast.runsOutAt {
            return "No ritmo da semana, acaba \(TokenFormat.moment(out)); renova \(TokenFormat.moment(limit.resetsAt))."
        }
        return "Renova \(TokenFormat.moment(limit.resetsAt)). No ritmo da semana, fecha perto de \(TokenFormat.percent(limit.forecast.atReset))."
    }

    static func tooltip(_ tokens: TokenMonitor) -> String {
        var parts: [String] = []
        if let f = tokens.fiveHourLimit { parts.append("Janela de 5 h: \(TokenFormat.percent(f.used)). " + fiveHour(f)) }
        if let w = tokens.weekLimit { parts.append("Semana: \(TokenFormat.percent(w.used)). " + week(w)) }
        return parts.isEmpty ? "Consumo das sessões" : parts.joined(separator: "\n")
    }
}

// MARK: Context chart

/// The conversation's context over time: compactions as rings, the pace ahead dashed, the ceiling on top.
struct ContextChart: View {
    /// Same width for the value labels of charts stacked over the same hours, so their plots line up.
    static let labelWidth: CGFloat = 46

    let points: [ContextPoint]
    let compactions: [Compaction]
    let limit: Int
    let domain: ClosedRange<Date>
    var projection: [ContextPoint] = []
    var selected: Date?
    var showsXAxis = true

    var body: some View {
        Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Hora", p.time), y: .value("Tokens", p.tokens))
                    .foregroundStyle(Color.white.opacity(0.07))
                LineMark(x: .value("Hora", p.time), y: .value("Tokens", p.tokens), series: .value("Linha", "contexto"))
                    .foregroundStyle(Theme.primary)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(projection) { p in
                LineMark(x: .value("Hora", p.time), y: .value("Tokens", p.tokens), series: .value("Linha", "ritmo"))
                    .foregroundStyle(Theme.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
            }
            RuleMark(y: .value("Teto", limit))
                .foregroundStyle(Color.white.opacity(0.22))
                .lineStyle(StrokeStyle(lineWidth: 1))
            ForEach(compactions) { c in
                PointMark(x: .value("Hora", c.time), y: .value("Tokens", c.before))
                    .symbol {
                        Circle().fill(Theme.control).overlay(Circle().stroke(Theme.primary, lineWidth: 1.5)).frame(width: 7, height: 7)
                    }
            }
            if let last = points.last {
                PointMark(x: .value("Hora", last.time), y: .value("Tokens", last.tokens))
                    .symbol { Circle().fill(Theme.primary).overlay(Circle().stroke(Color.black, lineWidth: 2)).frame(width: 9, height: 9) }
            }
            if let selected {
                RuleMark(x: .value("Hora", selected)).foregroundStyle(Color.white.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXScale(domain: domain)
        .chartYScale(domain: 0...limit)
        .chartYAxis {
            AxisMarks(position: .leading, values: [limit / 2, limit]) { value in
                AxisGridLine().foregroundStyle(Color.white.opacity(0.08))
                AxisValueLabel {
                    Text(TokenFormat.tokens(value.as(Int.self) ?? 0)).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        .frame(width: Self.labelWidth, alignment: .trailing)
                }
            }
        }
        .chartXAxis {
            if showsXAxis {
                AxisMarks(values: .automatic(desiredCount: 6)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(TokenFormat.clock(date)).font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                    }
                }
            } else {
                AxisMarks { _ in }
            }
        }
    }
}

/// Where the context goes at the last hour's pace, up to the point where Claude Code compacts.
@MainActor
func contextProjection(_ tokens: TokenMonitor, _ session: SessionRuntime, now: Date, horizon: TimeInterval) -> [ContextPoint] {
    guard let s = tokens.tokens(session), s.growthPerHour > 1000, let context = tokens.context(session),
          let at = tokens.nextCompaction(session, now: now), session.sleep == .awake else { return [] }
    let end = min(at, now.addingTimeInterval(horizon))
    let value = Double(context) + s.growthPerHour * end.timeIntervalSince(now) / 3600
    return [ContextPoint(time: now, tokens: context), ContextPoint(time: end, tokens: Int(value))]
}

// MARK: Session popover

/// What opens from the toolbar's meter: the context today, its pace, and this session's part of the window.
struct SessionTokensPopover: View {
    let session: SessionRuntime
    let close: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let tokens = model.tokens
        let s = tokens.tokens(session)
        let context = tokens.context(session) ?? 0
        let limit = tokens.contextLimit(session)
        let now = tokens.overview?.now ?? Date()
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Contexto")
                Spacer()
                if let name = s?.model { Text(TokenPrice.family(name)).font(.system(size: 11)).foregroundStyle(Theme.support) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(TokenFormat.tokens(context)).font(.system(size: 28, weight: .semibold))
                Text("de \(TokenFormat.tokens(limit))").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                Spacer()
                if let s, s.growthPerHour > 0 {
                    HStack(spacing: 4) {
                        RisingArrow()
                        Text("+\(TokenFormat.tokens(Int(s.growthPerHour))) na última hora")
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.support)
                }
            }
            .padding(.top, 4)
            FillBar(fraction: Double(context) / Double(limit), width: 352, height: 6).padding(.top, 8)

            if let s, s.points.count > 1 {
                let projection = contextProjection(tokens, session, now: now, horizon: 5 * 3600)
                let start = s.points.first?.time ?? now
                let end = max(projection.last?.time ?? now, now).addingTimeInterval(15 * 60)
                ContextChart(points: s.points, compactions: s.compactions, limit: limit, domain: start...end, projection: projection)
                    .frame(height: 124)
                    .padding(.top, 14)
                legend(projection: !projection.isEmpty)
                Text(caption(s, context: context))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.support)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }

            Rectangle().fill(Theme.divider).frame(height: 1).padding(.vertical, 14)
            spend(s)

            HStack(spacing: 8) {
                Button {
                    tokens.focused = session.id
                    openWindow(id: "usage")
                    close()
                } label: {
                    Text("Ver a sessão inteira").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                Button {
                    tokens.focused = nil
                    openWindow(id: "usage")
                    close()
                } label: {
                    Text("Consumo geral").frame(maxWidth: .infinity)
                }
                .controlSize(.large)
            }
            .padding(.top, 16)
        }
        .padding(16)
        .frame(width: 384)
        .background(Theme.surface)
    }

    private func legend(projection: Bool) -> some View {
        HStack(spacing: 14) {
            HStack(spacing: 5) {
                Circle().fill(Theme.control).overlay(Circle().stroke(Theme.primary, lineWidth: 1.5)).frame(width: 7, height: 7)
                Text("compactou")
            }
            if projection {
                HStack(spacing: 5) {
                    DashKey(color: Theme.secondary)
                    Text("no ritmo da última hora")
                }
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.secondary)
        .padding(.top, 8)
    }

    private func caption(_ s: SessionTokens, context: Int) -> String {
        var text = ""
        let n = s.compactions.count
        if n > 0 { text += "Compactou \(n == 1 ? "1 vez" : "\(n) vezes") desde \(TokenFormat.clock(s.points.first?.time ?? Date())). " }
        text += "Cada resposta relê os \(TokenFormat.tokens(context)) tokens"
        if let at = model.tokens.nextCompaction(session), session.sleep == .awake {
            text += "; no ritmo da última hora, compacta de novo perto das \(TokenFormat.clock(at))."
        } else {
            text += "."
        }
        return text
    }

    @ViewBuilder
    private func spend(_ s: SessionTokens?) -> some View {
        let tokens = model.tokens
        let limit = tokens.fiveHourLimit
        let mine = tokens.windowPercent(s?.weightInWindow ?? 0)
        let used = max(limit?.used ?? 0, mine)
        HStack {
            SectionLabel(text: "Gasto")
            Spacer()
            if let limit, !limit.estimated {
                Text("janela renova às \(TokenFormat.clock(limit.resetsAt))").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            }
        }
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(TokenFormat.percent(mine)).font(.system(size: 28, weight: .semibold))
            Text("da janela de 5 h foi desta sessão").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .padding(.top, 4)
        WindowShareBar(mine: mine, others: max(used - mine, 0)).padding(.top, 8)
        let rate = tokens.windowPercent(s?.weightLastHour ?? 0)
        let average = averageRate(s)
        row("Ritmo", "\(TokenFormat.percent(rate)) da janela por hora") {
            if average > 0 {
                HStack(spacing: 4) {
                    Image(systemName: rate >= average ? "arrow.up.right" : "arrow.down.right").font(.system(size: 9, weight: .semibold))
                    Text("\(TokenFormat.percent(average)) na média da janela")
                }
            }
        }
        let share = s.map { $0.weightSinceFrom > 0 ? $0.agentWeightSinceFrom / $0.weightSinceFrom * 100 : 0 } ?? 0
        let active = s?.activeAgents ?? 0
        row("Agentes", "\(TokenFormat.percent(share)) do gasto de hoje") {
            Text(active > 0 ? "\(active) rodando agora" : "nenhum rodando")
        }
    }

    /// Percent per hour across the part of the window this session was around.
    private func averageRate(_ s: SessionTokens?) -> Double {
        guard let s, s.weightInWindow > 0 else { return 0 }
        let start = model.tokens.windowStart(model.tokens.overview?.now ?? Date())
        let hours = max((model.tokens.overview?.now ?? Date()).timeIntervalSince(start) / 3600, 0.25)
        return model.tokens.windowPercent(s.weightInWindow) / hours
    }

    private func row<Trailing: View>(_ key: String, _ value: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(key).foregroundStyle(Theme.tertiary).frame(width: 64, alignment: .leading)
            Text(value).foregroundStyle(Theme.primary)
            Spacer()
            trailing().font(.system(size: 11)).foregroundStyle(Theme.secondary)
        }
        .font(.system(size: 12).monospacedDigit())
        .padding(.top, 9)
    }
}

struct DashKey: View {
    let color: Color

    var body: some View {
        Path { p in
            p.move(to: CGPoint(x: 1, y: 2))
            p.addLine(to: CGPoint(x: 15, y: 2))
        }
        .stroke(color, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
        .frame(width: 16, height: 4)
    }
}

/// The 5 h window split in three: this session, the others, what is left.
struct WindowShareBar: View {
    let mine: Double
    let others: Double

    var body: some View {
        let free = max(100 - mine - others, 0)
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                let w = geo.size.width - 4
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.primary).frame(width: max(w * mine / 100, mine > 0 ? 2 : 0))
                    RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.42)).frame(width: max(w * others / 100, 0))
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1))
                }
            }
            .frame(height: 6)
            HStack(spacing: 14) {
                key(Theme.primary, "esta sessão \(TokenFormat.percent(mine))")
                key(Color(white: 0.42), "outras \(TokenFormat.percent(others))")
                key(Color.white.opacity(0.18), "livre \(TokenFormat.percent(free))")
            }
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func key(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}

// MARK: Menu bar

/// Top of the menu bar window: both windows of the limit and who spends the most now.
struct MenuBarLimitSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tokens = model.tokens
        if let five = tokens.fiveHourLimit {
            VStack(alignment: .leading, spacing: 0) {
                SectionLabel(text: "Limite").padding(.bottom, 8)
                meter("Janela de 5 h", five, alert: tokens.windowAtRisk, text: LimitText.fiveHour(five))
                if let week = tokens.weekLimit {
                    meter("Semana", week, alert: false, text: LimitText.week(week)).padding(.top, 12)
                }
                if let hot = tokens.hottest, hot.rate >= 1 {
                    Button { model.focus(sessionId: hot.runtime.id) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(model.displayLabel(hot.runtime)).font(.system(size: 13)).foregroundStyle(Theme.primary)
                                Text("gasta mais agora, \(model.project(hot.runtime.projectId)?.project.name ?? "")")
                                    .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            }
                            .lineLimit(1)
                            Spacer(minLength: 8)
                            HStack(spacing: 4) {
                                if tokens.risingFast(hot.runtime) { RisingArrow() }
                                Text("\(TokenFormat.percent(hot.rate)) por hora")
                            }
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.support)
                        }
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
        }
    }

    private func meter(_ title: String, _ limit: TokenMonitor.Limit, alert: Bool, text: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.primary)
                if alert {
                    Image(systemName: "exclamationmark.triangle").font(.system(size: 10)).foregroundStyle(Theme.warning)
                }
                Spacer()
                Text(TokenFormat.percent(limit.used)).font(.system(size: 13, weight: .semibold).monospacedDigit())
            }
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.1))
                    Capsule().fill(alert ? Theme.warning : Theme.primary).frame(width: w * min(limit.used / 100, 1))
                    if !limit.estimated {
                        RoundedRectangle(cornerRadius: 1).fill(Theme.secondary)
                            .frame(width: 2, height: 11)
                            .offset(x: w * min(limit.forecast.atReset / 100, 1) - 1)
                    }
                }
            }
            .frame(height: 5)
            .padding(.top, 7)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)
        }
        .accessibilityElement(children: .combine)
    }
}
