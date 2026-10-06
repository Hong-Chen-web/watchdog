import AppKit

// MARK: - 行情类卡:策略回测 / 自选行情 / 策略信号 / 期货监控 / 市场日历

// MARK: 策略回测(实盘台账:缠论 tail 轮次真金白银统计)

func makeBacktestCard() -> CardView {
    let c = CardView(title: t("策略回测"), icon: "flask", meta: wdLang == "en" ? "LIVE LEDGER" : "实盘台账", id: "backtest")

    func kpi(_ cap: String) -> (NSStackView, NSTextField) {
        let v = label("—", size: 15.5, bold: true, mono: true)
        let col = NSStackView(views: [label(cap, size: 9.5, color: .wdText3), v])
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 3
        return (col, v)
    }
    let en = wdLang == "en"
    let (cPrin, vPrin) = kpi(en ? "PRINCIPAL" : "本金")
    let (cNet, vNet) = kpi(en ? "REALIZED" : "已实现")
    let (cRounds, vRounds) = kpi(en ? "ROUNDS" : "轮次")
    let (cWin, vWin) = kpi(en ? "WIN" : "胜轮")
    let (cWorst, vWorst) = kpi(en ? "WORST" : "最差轮")
    let (cTotal, vTotal) = kpi(en ? "TOTAL NOW" : "总资产")
    let kpiRow = NSStackView(views: [cPrin, cNet, cRounds, cWin, cWorst, cTotal])
    kpiRow.orientation = .horizontal; kpiRow.alignment = .top; kpiRow.spacing = 34
    c.block(kpiRow)

    // 周期筛选:日/月/年 重采样曲线
    var fullCurve: [(date: String, equity: Double)] = []
    let spanBar = PillBar(items: [("day", t("日")), ("month", t("月")), ("year", t("年"))])
    let curve = CurveView()
    curve.translatesAutoresizingMaskIntoConstraints = false
    curve.heightAnchor.constraint(equalToConstant: 96).isActive = true
    func applySpan(_ span: String) {
        let pts = resampleCurve(fullCurve, span: span)
        curve.values = pts.map(\.equity)
        curve.dates = pts.map(\.date)
    }
    spanBar.onSelect = { id in applySpan(id) }
    let spanRow = NSStackView(views: [label(t("周期"), size: 10.5, color: .wdText3), spanBar])
    spanRow.orientation = .horizontal; spanRow.alignment = .centerY; spanRow.spacing = 8
    c.row([spanRow])
    c.block(curve)

    let foot = label("", size: 11, color: .wdText2, mono: true)
    c.row([foot])

    func apply(_ b: LiveBacktest) {
        vPrin.stringValue = fmtWan(b.principal)
        vNet.stringValue = String(format: "%+.0f", b.realizedNet)
        vNet.textColor = b.realizedNet >= 0 ? .wdUp : .wdDown
        vRounds.stringValue = "\(b.rounds)"
        let winRate = b.rounds > 0 ? Double(b.winRounds) / Double(b.rounds) * 100 : 0
        vWin.stringValue = "\(b.winRounds)(\(Int(winRate.rounded()))%)"
        vWorst.stringValue = String(format: "%+.0f", b.worst)
        vWorst.textColor = .wdDown
        if let tn = b.totalNow {
            vTotal.stringValue = fmtWan(tn)   // 与持仓卡同源(现金+浮动市值)
        }
        fullCurve = b.curve.map { (date: $0.date, equity: $0.equity) }
        applySpan(spanBar.selected.isEmpty ? "day" : spanBar.selected)
        curve.tint = b.realizedNet >= 0 ? .wdUp : .wdDown
        let since = b.startDate.map { String($0.prefix(10)) } ?? ""
        foot.stringValue = since + (en ? " · best " : " 起 · 最好轮 ") + String(format: "%+.0f", b.best)
            + (en ? " · hover curve for daily" : " · 曲线悬停看每日资产")
    }

    Task {
        while true {
            if let b = try? await API.get("/api/backtest/live", as: LiveBacktest.self) {
                await MainActor.run { apply(b) }
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }
    return c
}

// MARK: 自选行情(3s 轮询 + 添加/同步/右键删除)

func makeMarketCard(openChart: @escaping (String, String) -> Void) -> CardView {
    let c = CardView(title: t("自选行情"), icon: "chart-line", meta: wdLang == "en" ? "3s · session" : "3s·交易时段", id: "market")
    let idxRow = NSStackView()
    idxRow.orientation = .horizontal; idxRow.alignment = .centerY; idxRow.spacing = 18
    let list = FlippedStack()
    list.orientation = .vertical; list.alignment = .leading; list.spacing = 3
    idxRow.addView(label(wdLang == "en" ? "Loading…" : "加载中…", size: 11, color: .wdText3), in: .leading)
    c.block(idxRow)
    // 自选列表:卡内滚动(全量,含缠论监控同步)
    let listScroll = NSScrollView()
    listScroll.documentView = list
    listScroll.hasVerticalScroller = true
    listScroll.drawsBackground = false
    listScroll.scrollerStyle = .overlay
    listScroll.translatesAutoresizingMaskIntoConstraints = false
    listScroll.heightAnchor.constraint(equalToConstant: 210).isActive = true
    list.widthAnchor.constraint(greaterThanOrEqualTo: listScroll.contentView.widthAnchor).isActive = true
    c.block(listScroll)
    // 底部维护行:轮询开关 + 代码回车添加(poll 在 reload 声明后构建)
    let input = NSTextField()
    input.placeholderString = t("代码回车添加,如 601318")
    input.font = .systemFont(ofSize: 11.5)
    input.translatesAutoresizingMaskIntoConstraints = false
    input.widthAnchor.constraint(equalToConstant: 150).isActive = true
    let enterT = NullableTarget {
        let s = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard s.count >= 4 else { return }
        input.stringValue = ""
        Task { _ = try? await API.post("/api/market/watchlist", body: ["code": s]) }
    }
    input.target = enterT
    input.action = #selector(NullableTarget.fire)
    @Sendable func reloadMarket() async {
        guard let q = try? await API.get("/api/market/quotes", as: QuotesResponse.self) else { return }
        await MainActor.run {
            idxRow.views.forEach { $0.removeFromSuperview() }
            for (name, ix) in (q.indices ?? [:]) {
                let col = NSStackView(views: [
                    label(name, size: 10, color: .wdText3),
                    label(String(format: "%.0f  %+.2f%%", ix.price, ix.chgPct), size: 12.5,
                          bold: true, color: pctColor(ix.chgPct), mono: true),
                ])
                col.orientation = .vertical; col.alignment = .leading; col.spacing = 1
                idxRow.addView(col, in: .leading)
            }
            list.views.forEach { $0.removeFromSuperview() }
            for w in (q.watchlist ?? []) {
                let chg = w.chgPct ?? 0
                let row = QuoteRowView()
                row.set(name: w.name, price: String(format: "%.2f", w.price ?? 0),
                        chg: String(format: "%+.2f%%", chg), up: chg >= 0) {
                    openChart(w.code, w.name)
                }
                // 行尾 ✕ 删除自选
                let code = w.code
                row.setRemove {
                    Task { _ = try? await API.request("DELETE", "/api/market/watchlist/\(code)") }
                }
                list.addView(row, in: .leading)
            }
            list.fitTo(minHeight: 210)
        }
    }
    // 轮询引擎:交易日+股票时段内 3s 拉行情K线(8787 同款开关);初始快照一次
    let poll = PollEngine(label: "market",
                          inHours: { TradingHours.isTradingDay() && TradingHours.stock() },
                          interval: 3) { await reloadMarket() }
    poll.start()
    c.row([poll.button, input], spacing: 10)
    Task { await reloadMarket() }
    return c
}

// MARK: 策略信号(尾盘选股:名次+标签芯片+评分;前三=拟买)

/// 小标签芯片(圆角浅底短文字)
final class ChipView: NSView {
    init(_ text: String, tint: NSColor) {
        let tl = label(text, size: 9, color: tint)
        let sz = tl.fittingSize
        super.init(frame: NSRect(x: 0, y: 0, width: sz.width + 12, height: 17))
        wantsLayer = true
        layer?.backgroundColor = tint.withAlphaComponent(0.14).cgColor
        layer?.cornerRadius = 4
        addSubview(tl)
        tl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tl.centerXAnchor.constraint(equalTo: centerXAnchor),
            tl.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
}

func makeStrategyCard() -> CardView {
    let c = CardView(title: t("策略信号"), icon: "lightning",
                     meta: wdLang == "en" ? "14:55 tail" : "14:55 尾盘", id: "strategy")
    let accent = wdModuleAccent("strategy")
    let en = wdLang == "en"

    // 头部:轮次徽章 + 下一选股日
    let roundBadge = ChipView("—", tint: accent)
    let nextL = label("", size: 10, color: .wdText3, mono: true)
    let head = NSStackView(views: [roundBadge, NSView(), nextL])
    head.orientation = .horizontal; head.alignment = .centerY; head.spacing = 8
    c.block(head)

    let list = FlippedStack()
    list.orientation = .vertical; list.alignment = .leading; list.spacing = 6
    let scroller = NSScrollView()
    scroller.documentView = list
    scroller.hasVerticalScroller = true
    scroller.drawsBackground = false
    scroller.scrollerStyle = .overlay
    scroller.translatesAutoresizingMaskIntoConstraints = false
    scroller.heightAnchor.constraint(equalToConstant: 196).isActive = true
    list.widthAnchor.constraint(greaterThanOrEqualTo: scroller.contentView.widthAnchor).isActive = true
    c.block(scroller)

    func rebuild(round: String?, next: String?, stocks: [ChanTail.S]) {
        roundBadge.subviews.forEach { $0.removeFromSuperview() }
        let rl = label(round ?? "—", size: 9, color: NSColor.wdText2)
        roundBadge.addSubview(rl)
        rl.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            rl.centerXAnchor.constraint(equalTo: roundBadge.centerXAnchor),
            rl.centerYAnchor.constraint(equalTo: roundBadge.centerYAnchor),
        ])
        nextL.stringValue = next.map { (en ? "next " : "下一轮 ") + String($0.prefix(10)) } ?? ""

        list.views.forEach { $0.removeFromSuperview() }
        for (i, st) in stocks.prefix(10).enumerated() {
            let willBuy = i < 3   // 策略:收盘买入评分前三
            // 名次:普通灰字序号;前三金色加粗(唯一的金色)
            let rankL = label(String(i + 1), size: 11, bold: willBuy,
                              color: willBuy ? accent : NSColor.wdText3, mono: true)
            rankL.translatesAutoresizingMaskIntoConstraints = false
            rankL.widthAnchor.constraint(equalToConstant: 16).isActive = true
            // 名称(+拟买小标,金边细字) / 第二行 hits 灰字
            let nameL = label(st.name, size: 12.5, bold: willBuy)
            let buyChip = willBuy ? ChipView(en ? "BUY" : "拟买", tint: accent) : nil
            let nameRow = NSStackView(views: buyChip.map { [nameL, $0] } ?? [nameL])
            nameRow.orientation = .horizontal; nameRow.alignment = .centerY; nameRow.spacing = 6
            // 副行:已出场标状态(快照轮),否则入选理由
            let exited = !(st.exitWhy ?? "").isEmpty
            let hitsTxt = exited
                ? (en ? "exited · " : "已出场 · ") + (st.exitWhy ?? "")
                : (st.hits ?? []).prefix(2).joined(separator: " · ")
            let hitsL = label(hitsTxt, size: 9.5,
                              color: exited ? NSColor.wdWarn : NSColor.wdText3)
            let nameCol = NSStackView(views: [nameRow, hitsL])
            nameCol.orientation = .vertical; nameCol.alignment = .leading; nameCol.spacing = 2
            // 评分:实时轮有大数字;快照轮被剥离→退化为参考价
            let scoreL = st.score != nil
                ? label(String(format: "%.1f", st.score ?? 0), size: 14, bold: true,
                        color: .wdText, mono: true)
                : label(String(format: "%.2f", st.price ?? 0), size: 12, bold: false,
                        color: .wdText2, mono: true)
            let row = NSStackView(views: [rankL, nameCol, NSView(), scoreL])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
            list.addView(row, in: .leading)
        }
        list.fitTo(minHeight: 120)
    }

    // 数据加载:启动即拉一次(非交易日/休市也保留最近一轮展示),之后由轮询引擎在交易时段刷新
    @Sendable func reloadSignal() async {
        guard let tail = try? await API.get("/api/chan/tail", as: ChanTail.self) else { return }
        await MainActor.run { rebuild(round: tail.date, next: tail.nextRunDay,
                                      stocks: tail.stocks ?? []) }
    }
    let poll = PollEngine(label: "strategy",
                          inHours: { TradingHours.isTradingDay() && TradingHours.stock() },
                          interval: 30) { await reloadSignal() }
    poll.start()
    c.row([poll.button])
    Task { await reloadSignal() }   // 上一交易日数据立即可见
    return c
}

// MARK: 期货监控(级别下拉 + 缠论结构摘要)

final class LevelState: @unchecked Sendable {
    var level = "5m"
    func reload(_ rows: NSStackView) async {
        let q = level.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        guard let f = try? await API.get("/api/chan/futures?level=\(q)", as: FuturesState.self) else { return }
        await MainActor.run {
            rows.views.forEach { $0.removeFromSuperview() }
            for s in f.stocks ?? [] {
                let chg = s.chgPct ?? 0
                let cp = s.chanpy
                var sum = "\(cp?.biCount ?? 0)笔·\(cp?.zsCount ?? 0)中枢"
                if let dir = cp?.lastBiDir { sum += "·" + (dir.contains("下") ? "↓" : "↑") }
                if let zs = cp?.lastZs, zs.count == 2 {
                    sum += String(format: " [%.0f,%.0f]", zs[0], zs[1])
                }
                let code = s.code, name = s.name ?? s.code
                let row = QuoteRowView()
                row.set(name: name, price: "\(s.livePrice ?? s.close ?? 0)  \(sum)",
                        chg: String(format: "%+.2f%%", chg), up: chg >= 0) {
                    openChartGlobal(code, name)
                }
                rows.addView(row, in: .leading)
            }
        }
    }
}

var openChartGlobal: (String, String) -> Void = { _, _ in }

func makeFuturesCard(openChart: @escaping (String, String) -> Void) -> CardView {
    openChartGlobal = openChart
    let c = CardView(title: t("期货监控"), icon: "compass", meta: wdLang == "en" ? "3s · session" : "3s·交易时段", id: "futures")
    let pop = NSPopUpButton()
    pop.controlSize = .small
    let rows = NSStackView()
    rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 3
    c.block(rows)
    let state = LevelState()
    pop.onAction {
        state.level = pop.titleOfSelectedItem ?? "5m"
        Task { await state.reload(rows) }
    }
    func reloadAll() async {
        if let f = try? await API.get("/api/chan/futures", as: FuturesState.self) {
            await MainActor.run {
                pop.removeAllItems()
                pop.addItems(withTitles: f.levels ?? [])
                pop.selectItem(withTitle: f.level ?? "5m")
            }
        }
        await state.reload(rows)
    }
    // 轮询引擎:交易日+期货时段(日盘+夜盘)3s;休市按钮显示休市态
    let poll = PollEngine(label: "futures",
                          inHours: { TradingHours.isTradingDay() && TradingHours.futures() },
                          interval: 3) { await reloadAll() }
    poll.start()
    c.row([label(t("级别"), size: 10.5, color: .wdText3), pop, poll.button], spacing: 10)
    Task { await reloadAll() }
    return c
}

// MARK: 市场日历(静态事件)

func makeCalendarCard() -> CardView {
    let c = CardView(title: t("市场日历"), icon: "calendar-blank", meta: "2026 Q4", id: "calendar")
    for (d, e) in [("10-08", "国庆假期后开市"), ("10-13", "9月 CPI/PPI 公布"),
                    ("10-20", "LPR 报价"), ("10-31", "三季报披露截止")] {
        c.row([label(d, size: 11, color: .wdText3, mono: true), label(e, size: 12, color: .wdText2)])
    }
    return c
}
