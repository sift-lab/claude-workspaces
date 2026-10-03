import Charts
import SwiftUI
import WorkspacesCore

// The Consumo window's token tabs ("Agora", "Semana") and one session in full.

private extension View {
    func card(alert: Bool = false) -> some View {
        padding(.horizontal, 18)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(alert ? Theme.warning.opacity(0.45) : Theme.divider))
    }
}

private struct Tile: View {
    let title: String
    let value: String
    let note: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
            Text(value).font(.system(size: 20, weight: .semibold)).foregroundStyle(Theme.primary).lineLimit(1).minimumScaleFactor(0.7)
            Text(note).font(.system(size: 11)).foregroundStyle(Theme.secondary)
                .lineLimit(2, reservesSpace: true)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider))
    }
}

private struct Key: View {
    let color: Color
    let text: String
    var dashed = false

    var body: some View {
        HStack(spacing: 5) {
            if dashed {
                DashKey(color: color)
            } else {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            }
            Text(text)
        }
    }
}

private struct Loading: View {
    var body: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Lendo os registros do Claude Code das últimas duas semanas...")
                .font(.system(size: 13))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.vertical, 40)
        .frame(maxWidth: .infinity)
    }
}

private struct UsedPoint: Identifiable {
    var time: Date
    var percent: Double
    var series: String
    var id: String { series + "\(time.timeIntervalSince1970)" }
}

// MARK: Agora

struct TokensNowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.tokens.overview == nil {
            Loading()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 12) {
                    FiveHourCard()
                    WeekCard()
                }
                SessionsNow()
            }
        }
    }
}

private struct FiveHourCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tokens = model.tokens
        if let o = tokens.overview, let limit = tokens.fiveHourLimit {
            let alert = tokens.windowAtRisk
            let now = o.now
            let scale = o.weightInWindow > 0 ? limit.used / tokens.windowPercent(o.weightInWindow) : 1
            let used = o.windowCurve.map {
                UsedPoint(time: o.windowStart.addingTimeInterval($0.offset), percent: tokens.windowPercent($0.weight) * scale, series: "usado")
            }
            let end = limit.estimated ? now : limit.resetsAt
            let out = limit.forecast.runsOutAt
            let ahead: [UsedPoint] = limit.estimated ? [] : [
                UsedPoint(time: now, percent: limit.used, series: "ritmo"),
                out.map { UsedPoint(time: $0, percent: 100, series: "ritmo") }
                    ?? UsedPoint(time: limit.resetsAt, percent: limit.forecast.atReset, series: "ritmo"),
            ]
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel(text: limit.estimated ? "Últimas 5 h" : "Janela de 5 h")
                    Spacer()
                    Text(limit.estimated ? "estimado" : "renova às \(TokenFormat.clock(limit.resetsAt)), em \(TokenFormat.span(limit.resetsAt.timeIntervalSince(now)))")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(TokenFormat.percent(limit.used)).font(.system(size: 34, weight: .semibold))
                    Text(limit.estimated ? "da janela, pelos registros" : "usados desde \(TokenFormat.clock(o.windowStart))")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .padding(.top, 4)
                if let out {
                    HStack(spacing: 7) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.warning)
                        Text("Acaba perto das \(TokenFormat.clock(out)) e só renova às \(TokenFormat.clock(limit.resetsAt)).")
                    }
                    .font(.system(size: 13))
                    .padding(.top, 6)
                }
                Chart {
                    if let out {
                        RectangleMark(xStart: .value("De", out), xEnd: .value("Até", limit.resetsAt), yStart: .value("Base", 0), yEnd: .value("Topo", 100))
                            .foregroundStyle(Theme.warning.opacity(0.1))
                    }
                    RuleMark(y: .value("Limite", 100)).foregroundStyle(Color.white.opacity(0.28)).lineStyle(StrokeStyle(lineWidth: 1))
                    ForEach(used) { p in
                        AreaMark(x: .value("Hora", p.time), y: .value("Usado", p.percent)).foregroundStyle(Color.white.opacity(0.07))
                        LineMark(x: .value("Hora", p.time), y: .value("Usado", p.percent), series: .value("Linha", p.series))
                            .foregroundStyle(Theme.primary)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    ForEach(ahead) { p in
                        LineMark(x: .value("Hora", p.time), y: .value("Usado", p.percent), series: .value("Linha", p.series))
                            .foregroundStyle(out == nil ? Theme.secondary : Theme.warning)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
                    }
                    PointMark(x: .value("Hora", now), y: .value("Usado", limit.used))
                        .symbol { Circle().fill(Theme.primary).overlay(Circle().stroke(Theme.surface, lineWidth: 2)).frame(width: 9, height: 9) }
                }
                .chartXScale(domain: o.windowStart...max(end, now.addingTimeInterval(60)))
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(position: .leading, values: [50, 100]) { value in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: limit.estimated ? [o.windowStart, now] : [o.windowStart, now, limit.resetsAt]) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(abs(date.timeIntervalSince(now)) < 60 ? "agora" : TokenFormat.clock(date))
                                    .font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                            }
                        }
                    }
                }
                .frame(height: 130)
                .padding(.top, 14)
                HStack(spacing: 14) {
                    Key(color: Theme.primary, text: "usado")
                    if !limit.estimated {
                        Key(color: out == nil ? Theme.secondary : Theme.warning, text: "no ritmo da última hora", dashed: true)
                    }
                    if out != nil { Key(color: Theme.warning.opacity(0.3), text: "sem janela até renovar") }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 10)
                Text(caption(limit))
                    .font(.system(size: 12)).foregroundStyle(Theme.support)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .card(alert: alert)
            .frame(maxWidth: .infinity)
        }
    }

    private func caption(_ limit: TokenMonitor.Limit) -> String {
        if limit.estimated { return LimitText.fiveHour(limit) }
        let rate = TokenFormat.percent(limit.forecast.rate)
        if limit.forecast.runsOutAt != nil {
            return "\(rate) por hora na última hora. Nesse ritmo, faltam \(TokenFormat.span((limit.forecast.runsOutAt ?? Date()).timeIntervalSinceNow)) para acabar."
        }
        return "\(rate) por hora na última hora. Nesse ritmo, chega a \(TokenFormat.percent(limit.forecast.atReset)) quando renovar. Cabe."
    }
}

private struct WeekCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tokens = model.tokens
        if let o = tokens.overview, let limit = tokens.weekLimit {
            let now = o.now
            let scale = o.weightInWeek > 0 ? limit.used / tokens.weekPercent(o.weightInWeek) : 1
            let mine = o.weekCurve.map {
                UsedPoint(time: o.weekStart.addingTimeInterval($0.offset), percent: tokens.weekPercent($0.weight) * scale, series: "esta")
            }
            let last = o.lastWeekCurve.map {
                UsedPoint(time: o.weekStart.addingTimeInterval($0.offset), percent: tokens.weekPercent($0.weight) * scale, series: "passada")
            }
            let out = limit.forecast.runsOutAt
            let end = o.weekStart.addingTimeInterval(7 * 86_400)
            let ahead: [UsedPoint] = limit.estimated ? [] : [
                UsedPoint(time: now, percent: limit.used, series: "ritmo"),
                out.map { UsedPoint(time: $0, percent: 100, series: "ritmo") }
                    ?? UsedPoint(time: limit.resetsAt, percent: limit.forecast.atReset, series: "ritmo"),
            ]
            let sameHour = percentAt(now.timeIntervalSince(o.weekStart), in: last)
            let lastTotal = last.last?.percent ?? 0
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    SectionLabel(text: limit.estimated ? "Últimos 7 dias" : "Semana")
                    Spacer()
                    Text(limit.estimated ? "estimado" : "renova \(TokenFormat.moment(limit.resetsAt, now: now))")
                        .font(.system(size: 12).monospacedDigit()).foregroundStyle(Theme.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(TokenFormat.percent(limit.used)).font(.system(size: 34, weight: .semibold))
                    Text(limit.estimated ? "da semana, pelos registros" : "usados desde \(TokenFormat.moment(o.weekStart, now: now))")
                        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                .padding(.top, 4)
                Chart {
                    RuleMark(y: .value("Limite", 100)).foregroundStyle(Color.white.opacity(0.28)).lineStyle(StrokeStyle(lineWidth: 1))
                    ForEach(last) { p in
                        LineMark(x: .value("Dia", p.time), y: .value("Usado", p.percent), series: .value("Linha", p.series))
                            .foregroundStyle(Color(white: 0.42))
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    ForEach(mine) { p in
                        AreaMark(x: .value("Dia", p.time), y: .value("Usado", p.percent)).foregroundStyle(Color.white.opacity(0.07))
                        LineMark(x: .value("Dia", p.time), y: .value("Usado", p.percent), series: .value("Linha", p.series))
                            .foregroundStyle(Theme.primary)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    ForEach(ahead) { p in
                        LineMark(x: .value("Dia", p.time), y: .value("Usado", p.percent), series: .value("Linha", p.series))
                            .foregroundStyle(out == nil ? Theme.secondary : Theme.warning)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, dash: [3, 4]))
                    }
                    PointMark(x: .value("Dia", now), y: .value("Usado", limit.used))
                        .symbol { Circle().fill(Theme.primary).overlay(Circle().stroke(Theme.surface, lineWidth: 2)).frame(width: 9, height: 9) }
                }
                .chartXScale(domain: o.weekStart...end)
                .chartYScale(domain: 0...max(100, (last + mine).map(\.percent).max() ?? 100))
                .chartYAxis {
                    AxisMarks(position: .leading, values: [50, 100]) { value in
                        AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                        AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day)) { value in
                        AxisValueLabel {
                            if let date = value.as(Date.self) {
                                Text(TokenFormat.weekday(date)).font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                            }
                        }
                    }
                }
                .frame(height: 130)
                .padding(.top, 14)
                HStack(spacing: 14) {
                    Key(color: Theme.primary, text: "esta semana")
                    Key(color: Color(white: 0.42), text: "semana passada")
                    if !limit.estimated { Key(color: out == nil ? Theme.secondary : Theme.warning, text: "no ritmo da semana", dashed: true) }
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.secondary)
                .padding(.top, 10)
                Text(caption(limit, sameHour: sameHour, lastTotal: lastTotal))
                    .font(.system(size: 12)).foregroundStyle(Theme.support)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 8)
            }
            .card(alert: out != nil)
            .frame(maxWidth: .infinity)
        }
    }

    private func percentAt(_ offset: TimeInterval, in points: [UsedPoint]) -> Double? {
        guard let start = points.first?.time else { return nil }
        let target = start.addingTimeInterval(offset)
        guard let after = points.firstIndex(where: { $0.time >= target }), after > 0 else { return points.last?.percent }
        let a = points[after - 1], b = points[after]
        let f = b.time > a.time ? target.timeIntervalSince(a.time) / b.time.timeIntervalSince(a.time) : 1
        return a.percent + (b.percent - a.percent) * f
    }

    private func caption(_ limit: TokenMonitor.Limit, sameHour: Double?, lastTotal: Double) -> String {
        var text = ""
        if let sameHour, lastTotal > 0 {
            let pace = limit.used <= sameHour ? "Mais devagar que a passada" : "Mais rápido que a passada"
            text = "\(pace), que fechou em \(TokenFormat.percent(lastTotal)): na mesma hora ela estava em \(TokenFormat.percent(sameHour)). "
        }
        return text + LimitText.week(limit)
    }
}

/// Sessions grouped by workspace, with what each one carries and spends now.
private struct SessionsNow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let tokens = model.tokens
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.config.workspaces) { workspace in
                let rows = model.sessions(inWorkspace: workspace.id)
                    .filter { !$0.isTerminal && $0.claudeSessionId != nil }
                    .sorted { (tokens.tokens($0)?.weightInWindow ?? 0) > (tokens.tokens($1)?.weightInWindow ?? 0) }
                if !rows.isEmpty {
                    let total = rows.reduce(0.0) { $0 + tokens.windowPercent(tokens.tokens($1)?.weightInWindow ?? 0) }
                    groupHeader(workspace.name, total)
                    header
                    VStack(spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                            SessionNowRow(session: session)
                            if index < rows.count - 1 { Rectangle().fill(Theme.divider).frame(height: 1) }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider))
                }
            }
            outside
            Text("Contexto e gasto vêm dos registros do Claude Code, com os agentes somados à sessão que os abriu. A janela e a semana são o medidor da sua conta, lido na status line; a parte de cada sessão é estimada pelo peso dos tokens dela.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 18)
        }
    }

    private func groupHeader(_ name: String, _ percent: Double) -> some View {
        HStack {
            SectionLabel(text: name)
            Spacer()
            Text("\(TokenFormat.percent(percent)) da janela").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.tertiary)
        }
        .padding(.horizontal, 4)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("Sessão").frame(width: 200, alignment: .leading)
            Text("Contexto").frame(width: 170, alignment: .leading)
            Text("Última hora").frame(width: 170, alignment: .leading)
            Text("Na janela").frame(width: 76, alignment: .trailing)
            Text("Ritmo").frame(width: 96, alignment: .trailing)
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.tertiary)
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
    }

    /// Sessions that ran in a plain terminal: they count against the same limit.
    @ViewBuilder
    private var outside: some View {
        let tokens = model.tokens
        let mine = Set(model.sessions.compactMap(\.claudeSessionId))
        let others = (tokens.overview?.windowSessions ?? []).filter { !mine.contains($0.id) && tokens.windowPercent($0.weight) >= 0.1 }.prefix(6)
        if !others.isEmpty {
            groupHeader("Fora do Workspaces", others.reduce(0.0) { $0 + tokens.windowPercent($1.weight) })
            VStack(spacing: 0) {
                ForEach(Array(others.enumerated()), id: \.element.id) { index, s in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(s.branch ?? "sessão").font(.system(size: 13)).lineLimit(1)
                            Text(s.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "").font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                        .frame(width: 200 + 24, alignment: .leading)
                        HStack(spacing: 10) {
                            FillBar(fraction: Double(s.context) / Double(TokenMonitor.contextDefault), width: 80)
                            Text(TokenFormat.tokens(s.context)).font(.system(size: 12).monospacedDigit())
                        }
                        .frame(width: 170, alignment: .leading)
                        Text("última às \(TokenFormat.clock(s.last))").font(.system(size: 11)).foregroundStyle(Theme.tertiary)
                            .frame(width: 170, alignment: .leading)
                        Text(TokenFormat.percent(tokens.windowPercent(s.weight))).font(.system(size: 12).monospacedDigit())
                            .frame(width: 76, alignment: .trailing)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .frame(height: 48)
                    if index < others.count - 1 { Rectangle().fill(Theme.divider).frame(height: 1) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider))
        }
    }
}

private struct SessionNowRow: View {
    let session: SessionRuntime
    @Environment(AppModel.self) private var model

    var body: some View {
        let tokens = model.tokens
        let s = tokens.tokens(session)
        let context = tokens.context(session) ?? 0
        let limit = tokens.contextLimit(session)
        let now = tokens.overview?.now ?? Date()
        let hour = (s?.points ?? []).filter { $0.time >= now.addingTimeInterval(-3600) }
        let moving = hour.count > 1 && (hour.last?.tokens ?? 0) != (hour.first?.tokens ?? 0)
        let rate = tokens.windowPercent(s?.weightLastHour ?? 0)
        Button { tokens.focused = session.id } label: {
            HStack(spacing: 12) {
                StatusGlyph(status: session.status, attention: session.attention)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.displayLabel(session)).font(.system(size: 13)).foregroundStyle(Theme.primary).lineLimit(1)
                    Text(model.project(session.projectId)?.project.name ?? "").font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                .frame(width: 200, alignment: .leading)
                HStack(spacing: 10) {
                    FillBar(fraction: Double(context) / Double(limit), width: 80, fill: tokens.nearCeiling(session) ? Theme.primary : Theme.secondary)
                    Text(TokenFormat.tokens(context))
                        .font(.system(size: 12, weight: tokens.nearCeiling(session) ? .semibold : .regular).monospacedDigit())
                }
                .frame(width: 170, alignment: .leading)
                HStack(spacing: 10) {
                    Sparkline(points: moving ? hour : [])
                    Text(moving ? delta(hour) : "parada").font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
                }
                .frame(width: 170, alignment: .leading)
                Text(TokenFormat.percent(tokens.windowPercent(s?.weightInWindow ?? 0)))
                    .font(.system(size: 12).monospacedDigit())
                    .frame(width: 76, alignment: .trailing)
                Text(rate > 0.05 ? "\(TokenFormat.percent(rate)) por hora" : "0")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(rate >= 8 ? Theme.primary : Theme.secondary)
                    .frame(width: 96, alignment: .trailing)
                Spacer(minLength: 8)
                tag(s)
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Ver a sessão inteira")
    }

    private func delta(_ points: [ContextPoint]) -> String {
        let change = (points.last?.tokens ?? 0) - (points.first?.tokens ?? 0)
        return (change >= 0 ? "+" : "-") + TokenFormat.tokens(abs(change))
    }

    @ViewBuilder
    private func tag(_ s: SessionTokens?) -> some View {
        let tokens = model.tokens
        if session.sleep != .awake {
            SleepTag(sleep: session.sleep)
        } else if tokens.nearCeiling(session) {
            pill("Perto do teto: compactar ou abrir outra", strong: true)
        } else if tokens.risingFast(session) {
            HStack(spacing: 5) { RisingArrow(); Text("Subindo rápido") }.pillStyle(strong: true)
        } else if let agents = s?.activeAgents, agents > 0 {
            AgentsLabel(count: agents).pillStyle(strong: false)
        } else {
            pill(session.status.label, strong: false)
        }
    }

    private func pill(_ text: String, strong: Bool) -> some View {
        Text(text).pillStyle(strong: strong)
    }
}

private extension View {
    func pillStyle(strong: Bool) -> some View {
        font(.system(size: 11))
            .foregroundStyle(strong ? Theme.support : Theme.secondary)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(strong ? Color.clear : Theme.control))
            .overlay(Capsule().stroke(strong ? Color.white.opacity(0.14) : Color.clear))
            .lineLimit(1)
    }
}

/// The last hour of context, on its own scale: the shape is the trend, the number says the size.
private struct Sparkline: View {
    let points: [ContextPoint]

    var body: some View {
        Group {
            if points.count > 1 {
                Chart(points) { p in
                    LineMark(x: .value("Hora", p.time), y: .value("Tokens", p.tokens))
                        .foregroundStyle(Theme.support)
                        .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                }
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: .automatic(includesZero: false))
            } else {
                Rectangle().fill(Theme.faint).frame(height: 1.5)
            }
        }
        .frame(width: 88, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: Semana

struct TokensWeekView: View {
    @Environment(AppModel.self) private var model
    @State private var hovered: Date?

    var body: some View {
        let tokens = model.tokens
        if let o = tokens.overview {
            let week = tokens.weekLimit
            let lastWeek = tokens.weekPercent(o.lastWeekCurve.last?.weight ?? 0) * scale(o)
            let elapsedDays = max(o.now.timeIntervalSince(o.weekStart) / 86_400, 1.0 / 24)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Tile(title: week?.estimated == false ? "Esta semana" : "Últimos 7 dias", value: TokenFormat.percent(week?.used ?? 0),
                         note: week.map { $0.estimated ? "estimado pelos registros" : "renova \(TokenFormat.moment($0.resetsAt, now: o.now)); no ritmo, fecha perto de \(TokenFormat.percent($0.forecast.atReset))" } ?? "")
                    Tile(title: "Ritmo", value: "\(TokenFormat.percent((week?.used ?? 0) / elapsedDays)) por dia",
                         note: lastWeek > 0 ? "a semana passada foi a \(TokenFormat.percent(lastWeek / 7)) por dia e fechou em \(TokenFormat.percent(lastWeek))" : "sem a semana passada nos registros")
                    Tile(title: "Agentes", value: TokenFormat.percent(share(o.agentWeight, o)), note: "do gasto dos últimos 7 dias veio de agentes")
                    Tile(title: "Reler o contexto", value: TokenFormat.percent(share(o.cacheRead, o)),
                         note: "do gasto dos últimos 7 dias foi o Claude relendo o que já estava na conversa")
                }
                DailyChart(overview: o, hovered: $hovered)
                Shares(overview: o)
                TopSessions(overview: o)
            }
        } else {
            Loading()
        }
    }

    private func share(_ part: Double, _ o: TokenOverview) -> Double { o.total > 0 ? part / o.total * 100 : 0 }

    private func scale(_ o: TokenOverview) -> Double {
        guard let week = model.tokens.weekLimit, o.weightInWeek > 0 else { return 1 }
        return week.used / model.tokens.weekPercent(o.weightInWeek)
    }
}

/// The groups of the last two weeks, heaviest first; past three, the rest join "Outros".
@MainActor
private func dayGroups(_ o: TokenOverview) -> [String] {
    var totals: [String: Double] = [:]
    for day in o.days { for (name, w) in day.groups { totals[name, default: 0] += w } }
    let named = totals.filter { $0.key != "Outros" }.sorted { $0.value > $1.value }.map(\.key)
    let hasOthers = totals["Outros"] != nil || named.count > 3
    return Array(named.prefix(3)) + (hasOthers ? ["Outros"] : [])
}

private struct DailyChart: View {
    let overview: TokenOverview
    @Binding var hovered: Date?
    @Environment(AppModel.self) private var model

    private struct Bar: Identifiable {
        var day: Date
        var group: String
        var percent: Double
        var id: String { group + "\(day.timeIntervalSince1970)" }
    }

    var body: some View {
        let tokens = model.tokens
        let groups = dayGroups(overview)
        let bars = overview.days.flatMap { day -> [Bar] in
            var merged: [String: Double] = [:]
            for (name, w) in day.groups { merged[groups.contains(name) ? name : "Outros", default: 0] += w }
            return groups.compactMap { g in merged[g].map { Bar(day: day.day, group: g, percent: tokens.weekPercent($0)) } }
        }
        let shown = hovered ?? overview.days.max { $0.total < $1.total }?.day
        let detail = overview.days.first { $0.day == shown }
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Por dia, em % da semana")
                Spacer()
                HStack(spacing: 14) {
                    ForEach(Array(groups.enumerated()), id: \.element) { i, g in
                        Key(color: Theme.groupGreys[min(i, Theme.groupGreys.count - 1)], text: g == "Outros" ? "Outros, fora do app" : g)
                    }
                }
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            if let detail {
                Text(describe(detail, groups: groups, tokens: tokens))
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(hovered == nil ? Theme.secondary : Theme.primary)
                    .padding(.top, 8)
            }
            Chart(bars) { bar in
                BarMark(x: .value("Dia", bar.day, unit: .day), y: .value("Gasto", bar.percent), width: .fixed(22))
                    .foregroundStyle(by: .value("Grupo", bar.group))
                    .opacity(hovered == nil || hovered == bar.day ? 1 : 0.45)
            }
            .chartForegroundStyleScale(domain: groups, range: Array(Theme.groupGreys.prefix(groups.count)))
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                    AxisValueLabel { Text("\(value.as(Int.self) ?? 0)%").font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { value in
                    AxisValueLabel(centered: true) {
                        if let date = value.as(Date.self) {
                            VStack(spacing: 1) {
                                Text(TokenFormat.weekday(date))
                                Text(date.formatted(.dateTime.day(.twoDigits).month(.twoDigits)))
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(date == hovered ? Theme.primary : Theme.tertiary)
                        }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(Color.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame else { return }
                                let x = location.x - geo[frame].origin.x
                                if let date: Date = proxy.value(atX: x) {
                                    hovered = Calendar.current.startOfDay(for: date)
                                }
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .frame(height: 210)
            .padding(.top, 12)
        }
        .card()
    }

    private func describe(_ day: DayUsage, groups: [String], tokens: TokenMonitor) -> String {
        let date = day.day.formatted(.dateTime.weekday(.wide).day().month(.twoDigits).locale(Locale(identifier: "pt_BR")))
        var merged: [String: Double] = [:]
        for (name, w) in day.groups { merged[groups.contains(name) ? name : "Outros", default: 0] += w }
        let parts = groups.compactMap { g in merged[g].map { "\(g) \(TokenFormat.percent(tokens.weekPercent($0)))" } }
        let lead = hovered == nil ? "Dia mais pesado: " : ""
        return "\(lead)\(date), \(TokenFormat.percent(tokens.weekPercent(day.total))) da semana" + (parts.isEmpty ? "" : ". " + parts.joined(separator: ", "))
    }
}

private struct Shares: View {
    let overview: TokenOverview

    var body: some View {
        let o = overview
        let total = max(o.total, 1)
        let read = o.cacheRead / total * 100, write = o.cacheWrite / total * 100, out = (o.output + o.input) / total * 100
        let models = o.modelWeights.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key), \(TokenFormat.percent($0.value / total * 100))" }.joined(separator: "; ")
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "O que pesa, últimos 7 dias")
                Spacer()
                HStack(spacing: 14) {
                    Key(color: Theme.groupGreys[0], text: "reler o contexto \(TokenFormat.percent(read))")
                    Key(color: Theme.groupGreys[1], text: "guardar contexto novo \(TokenFormat.percent(write))")
                    Key(color: Theme.groupGreys[2], text: "escrever as respostas \(TokenFormat.percent(out))")
                }
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            GeometryReader { geo in
                let w = geo.size.width - 4
                HStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.groupGreys[0]).frame(width: w * read / 100)
                    RoundedRectangle(cornerRadius: 2).fill(Theme.groupGreys[1]).frame(width: w * write / 100)
                    RoundedRectangle(cornerRadius: 2).fill(Theme.groupGreys[2])
                }
            }
            .frame(height: 10)
            .padding(.top, 12)
            .accessibilityHidden(true)
            Text("\(read >= 70 ? "Quase 4 de cada 5 partes do gasto são" : "A maior parte do gasto é") o Claude relendo a conversa a cada resposta. Contexto menor e menos agentes ao mesmo tempo é o que mais economiza. Por modelo: \(models).")
                .font(.system(size: 12)).foregroundStyle(Theme.support)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
        }
        .card()
    }
}

private struct TopSessions: View {
    let overview: TokenOverview
    @Environment(AppModel.self) private var model

    var body: some View {
        let tokens = model.tokens
        let top = Array(overview.topSessions.prefix(6))
        let largest = max(top.first?.weight ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Sessões que mais gastaram nos últimos 7 dias").frame(width: 260, alignment: .leading)
                Text("Workspace").frame(width: 96, alignment: .leading)
                Text("Gasto, em % da semana").frame(width: 190, alignment: .leading)
                Text("Agentes").frame(width: 64, alignment: .trailing)
                Text("Pico").frame(width: 76, alignment: .trailing)
                Text("Compactou").frame(width: 76, alignment: .trailing)
                Spacer()
                Text("Quando")
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 8)
            VStack(spacing: 0) {
                ForEach(Array(top.enumerated()), id: \.element.id) { index, s in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(label(s)).font(.system(size: 13)).lineLimit(1)
                            Text(s.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "").font(.system(size: 11)).foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                        .frame(width: 260, alignment: .leading)
                        Text(workspace(s)).font(.system(size: 12)).foregroundStyle(Theme.secondary).frame(width: 96, alignment: .leading)
                        HStack(spacing: 10) {
                            FillBar(fraction: s.weight / largest, width: 110, fill: Theme.secondary)
                            Text(TokenFormat.percent(tokens.weekPercent(s.weight)))
                        }
                        .frame(width: 190, alignment: .leading)
                        Text(TokenFormat.percent(s.weight > 0 ? s.agentWeight / s.weight * 100 : 0)).frame(width: 64, alignment: .trailing)
                        Text(TokenFormat.tokens(s.peak)).frame(width: 76, alignment: .trailing)
                        Text(s.compactions == 0 ? "não" : (s.compactions == 1 ? "1 vez" : "\(s.compactions) vezes")).frame(width: 76, alignment: .trailing)
                        Spacer()
                        Text(when(s)).foregroundStyle(Theme.secondary)
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .padding(.horizontal, 14)
                    .frame(height: 44)
                    if index < top.count - 1 { Rectangle().fill(Theme.divider).frame(height: 1) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider))
        }
    }

    private func label(_ s: SessionSummary) -> String {
        if let runtime = model.sessions.first(where: { $0.claudeSessionId == s.id }) { return model.displayLabel(runtime) }
        return s.branch ?? "sessão"
    }

    private func workspace(_ s: SessionSummary) -> String {
        s.cwd.flatMap { model.config.project(containing: $0)?.workspace.name } ?? "Outros"
    }

    private func when(_ s: SessionSummary) -> String {
        let calendar = Calendar.current
        let day = { (d: Date) in d.formatted(.dateTime.day(.twoDigits).month(.twoDigits)) }
        if calendar.isDateInToday(s.first) { return "hoje" }
        if calendar.isDate(s.first, inSameDayAs: s.last) { return day(s.first) }
        return "\(day(s.first)) a \(calendar.isDateInToday(s.last) ? "hoje" : day(s.last))"
    }
}

// MARK: One session in full

struct SessionTokensDetail: View {
    let session: SessionRuntime
    @Environment(AppModel.self) private var model
    @State private var selected: Date?

    var body: some View {
        let tokens = model.tokens
        let s = tokens.tokens(session)
        let now = tokens.overview?.now ?? Date()
        VStack(alignment: .leading, spacing: 0) {
            Button { tokens.focused = nil } label: {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left").font(.system(size: 10, weight: .semibold))
                    Text("Consumo")
                }
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.escape, modifiers: [])
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text(model.project(session.projectId)?.project.name ?? "").foregroundStyle(Theme.tertiary)
                    Text("/").foregroundStyle(Theme.faint)
                    Text(model.displayLabel(session)).fontWeight(.bold)
                }
                .font(.system(size: 22))
                .lineLimit(1)
                Text(session.status.label)
                    .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                    .padding(.horizontal, 8).frame(height: 20)
                    .overlay(Capsule().stroke(Theme.border))
                Spacer()
                Text(subtitle(s)).font(.system(size: 12)).foregroundStyle(Theme.tertiary)
            }
            .padding(.top, 10)

            if let s {
                tiles(s)
                charts(s, now: now)
                segments(s, now: now)
            } else {
                Text("Esta sessão ainda não respondeu nada que conte tokens.")
                    .font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.top, 24)
            }
        }
    }

    private func subtitle(_ s: SessionTokens?) -> String {
        var parts: [String] = []
        if let workspace = model.workspace(session.workspaceId) { parts.append(workspace.name) }
        if let name = s?.model { parts.append(TokenPrice.family(name)) }
        return parts.joined(separator: " · ")
    }

    private func tiles(_ s: SessionTokens) -> some View {
        let tokens = model.tokens
        let context = tokens.context(session) ?? s.context
        let limit = tokens.contextLimit(session)
        let windowUsed = tokens.fiveHourLimit?.used ?? 0
        let isTop = tokens.sessions.values.allSatisfy { $0.weightSinceFrom <= s.weightSinceFrom }
        let n = s.compactions.count
        return HStack(spacing: 12) {
            Tile(title: "Contexto agora", value: TokenFormat.tokens(context), note: "de \(TokenFormat.tokens(limit)); cada resposta relê tudo isso")
            Tile(title: "Gasto hoje", value: "\(TokenFormat.percent(tokens.weekPercent(s.weightSinceFrom))) da semana",
                 note: isTop && tokens.sessions.count > 1 ? "a sessão aberta que mais gastou hoje" : "desde \(TokenFormat.clock(s.points.first?.time ?? Date()))")
            Tile(title: "Na janela de 5 h", value: TokenFormat.percent(tokens.windowPercent(s.weightInWindow)),
                 note: "dos \(TokenFormat.percent(windowUsed)) usados até agora")
            Tile(title: "Agentes", value: TokenFormat.percent(s.weightSinceFrom > 0 ? s.agentWeightSinceFrom / s.weightSinceFrom * 100 : 0),
                 note: s.activeAgents > 0 ? "do gasto de hoje; \(s.activeAgents) rodando agora" : "do gasto de hoje")
            Tile(title: "Compactou", value: n == 0 ? "nenhuma vez" : (n == 1 ? "1 vez" : "\(n) vezes"),
                 note: s.compactions.map { TokenFormat.clock($0.time) }.joined(separator: ", "))
        }
        .padding(.top, 18)
    }

    private struct Bar: Identifiable {
        var start: Date
        var low: Double
        var high: Double
        var kind: String
        var id: String { kind + "\(start.timeIntervalSince1970)" }
    }

    private func charts(_ s: SessionTokens, now: Date) -> some View {
        let tokens = model.tokens
        let limit = tokens.contextLimit(session)
        let projection = contextProjection(tokens, session, now: now, horizon: 5 * 3600)
        let start = s.points.first?.time ?? s.bins.first?.start ?? now
        let end = max(projection.last?.time ?? now, now).addingTimeInterval(10 * 60)
        let bars = s.bins.flatMap { bin -> [Bar] in
            let conversation = tokens.windowPercent(bin.weight - bin.agents), agents = tokens.windowPercent(bin.agents)
            var out: [Bar] = []
            if conversation > 0 { out.append(Bar(start: bin.start, low: 0, high: conversation, kind: "conversa")) }
            if agents > 0 { out.append(Bar(start: bin.start, low: conversation, high: conversation + agents, kind: "agentes")) }
            return out
        }
        let top = max(bars.map(\.high).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                SectionLabel(text: "Hoje, das \(TokenFormat.clock(start)) até agora")
                Spacer()
                HStack(spacing: 14) {
                    Key(color: Theme.primary, text: "contexto")
                    HStack(spacing: 5) {
                        Circle().fill(Theme.control).overlay(Circle().stroke(Theme.primary, lineWidth: 1.5)).frame(width: 7, height: 7)
                        Text("compactou")
                    }
                    if !projection.isEmpty { Key(color: Theme.secondary, text: "no ritmo da última hora", dashed: true) }
                    Key(color: Theme.support, text: "gasto da conversa")
                    Key(color: Color(white: 0.42), text: "gasto dos agentes")
                }
                .font(.system(size: 11)).foregroundStyle(Theme.secondary)
            }
            Text(readout(s, at: selected))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(selected == nil ? Theme.tertiary : Theme.primary)
                .padding(.top, 8)
            Text("Contexto, em tokens").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary).padding(.top, 10)
            ContextChart(points: s.points, compactions: s.compactions, limit: limit, domain: start...end,
                         projection: projection, selected: selected, showsXAxis: false)
                .frame(height: 190)
                .padding(.top, 6)
                .chartOverlay { proxy in hover(proxy) }
            Text("Gasto a cada 5 min, em % da janela de 5 h").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary).padding(.top, 14)
            Chart {
                ForEach(bars) { bar in
                    RectangleMark(xStart: .value("De", bar.start.addingTimeInterval(30)), xEnd: .value("Até", bar.start.addingTimeInterval(270)),
                                  yStart: .value("Base", bar.low), yEnd: .value("Topo", bar.high))
                        .foregroundStyle(bar.kind == "conversa" ? Theme.support : Color(white: 0.42))
                }
                if let selected {
                    RuleMark(x: .value("Hora", selected)).foregroundStyle(Color.white.opacity(0.4)).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: start...end)
            .chartYScale(domain: 0...(top * 1.1))
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                    AxisGridLine().foregroundStyle(Color.white.opacity(0.07))
                    AxisValueLabel {
                        Text("\(TokenFormat.decimal(value.as(Double.self) ?? 0))%").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                            .frame(width: ContextChart.labelWidth, alignment: .trailing)
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 8)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) { Text(TokenFormat.clock(date)).font(.system(size: 10)).foregroundStyle(Theme.tertiary) }
                    }
                }
            }
            .frame(height: 110)
            .padding(.top, 6)
            .chartOverlay { proxy in hover(proxy) }
            Text(caption(s))
                .font(.system(size: 12)).foregroundStyle(Theme.support)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
        }
        .card()
        .padding(.top, 12)
    }

    private func hover(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let location):
                        guard let frame = proxy.plotFrame else { return }
                        selected = proxy.value(atX: location.x - geo[frame].origin.x)
                    case .ended:
                        selected = nil
                    }
                }
        }
    }

    private func readout(_ s: SessionTokens, at date: Date?) -> String {
        guard let date else { return "Passe o ponteiro sobre os gráficos para ler um momento." }
        let tokens = model.tokens
        let context = s.points.last { $0.time <= date }?.tokens
        let bin = s.bins.last { $0.start <= date }
        var parts = [bin.map { "\(TokenFormat.clock($0.start)) a \(TokenFormat.clock($0.start.addingTimeInterval(300)))" } ?? TokenFormat.clock(date)]
        if let context { parts.append("contexto \(TokenFormat.tokens(context))") }
        if let bin {
            parts.append("gasto \(TokenFormat.percent(tokens.windowPercent(bin.weight))) da janela")
            if bin.agents > 0 { parts.append("\(TokenFormat.percent(tokens.windowPercent(bin.agents))) de agentes") }
        }
        return parts.joined(separator: ", ")
    }

    private func caption(_ s: SessionTokens) -> String {
        let tokens = model.tokens
        var text = ""
        if let last = s.compactions.last {
            let lows = s.compactions.map(\.after)
            let typical = lows.sorted()[lows.count / 2]
            let context = tokens.context(session) ?? s.context
            text += "\(s.compactions.count == 1 ? "A compactação derrubou" : "Cada compactação derrubou") o contexto para perto de \(TokenFormat.tokens(typical)). "
            let until = s.lastCall ?? Date()
            text += "Desde a última, às \(TokenFormat.clock(last.time)), foram mais \(TokenFormat.tokens(max(context - last.after, 0))) em \(TokenFormat.span(until.timeIntervalSince(last.time))). "
        }
        if let peak = s.bins.max(by: { $0.weight < $1.weight }), peak.weight > 0 {
            text += "O gasto mais alto veio às \(TokenFormat.clock(peak.start))"
            text += peak.agents > peak.weight / 2 ? ", com agentes." : "."
        }
        return text
    }

    private func segments(_ s: SessionTokens, now: Date) -> some View {
        let tokens = model.tokens
        let start = s.points.first?.time ?? now
        let bounds = [start] + s.compactions.map(\.time)
        struct Segment: Identifiable { var id: Int; var range: String; var first: Int; var peak: Int; var weight: Double; var agents: Double; var open: Bool }
        let list: [Segment] = bounds.enumerated().map { i, from in
            let to = i + 1 < bounds.count ? bounds[i + 1] : nil
            let inside = s.bins.filter { $0.start.addingTimeInterval(300) > from && (to == nil || $0.start < to!) }
            let first = s.points.first { $0.time >= from }?.tokens ?? 0
            let peak = to != nil ? s.compactions[i].before : (tokens.context(session) ?? s.context)
            return Segment(id: i, range: "\(TokenFormat.clock(from)) a \(to.map(TokenFormat.clock) ?? "agora")", first: first, peak: peak,
                           weight: inside.reduce(0) { $0 + $1.weight }, agents: inside.reduce(0) { $0 + $1.agents }, open: to == nil)
        }
        let largest = max(list.map(\.weight).max() ?? 1, 1)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Text("Trecho").frame(width: 130, alignment: .leading)
                Text("Começou com").frame(width: 110, alignment: .trailing)
                Text("Chegou a").frame(width: 110, alignment: .trailing)
                Text("Gasto, em % da janela").frame(width: 220, alignment: .trailing)
                Text("Dos agentes").frame(width: 100, alignment: .trailing)
                Spacer()
                Text("Terminou")
            }
            .font(.system(size: 11)).foregroundStyle(Theme.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 16)
            VStack(spacing: 0) {
                ForEach(list) { seg in
                    HStack(spacing: 12) {
                        Text(seg.range).frame(width: 130, alignment: .leading)
                        Text(TokenFormat.tokens(seg.first)).frame(width: 110, alignment: .trailing)
                        Text(TokenFormat.tokens(seg.peak)).frame(width: 110, alignment: .trailing)
                        HStack(spacing: 10) {
                            FillBar(fraction: seg.weight / largest, width: 110, fill: Theme.secondary)
                            Text(TokenFormat.percent(tokens.windowPercent(seg.weight)))
                        }
                        .frame(width: 220, alignment: .trailing)
                        Text(TokenFormat.percent(seg.weight > 0 ? seg.agents / seg.weight * 100 : 0)).frame(width: 100, alignment: .trailing)
                        Spacer()
                        Text(seg.open ? "ainda aberto" : "compactou").foregroundStyle(Theme.secondary)
                    }
                    .font(.system(size: 12).monospacedDigit())
                    .padding(.horizontal, 14)
                    .frame(height: 40)
                    if seg.id < list.count - 1 { Rectangle().fill(Theme.divider).frame(height: 1) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.surface))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.divider))
        }
    }
}
