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
            let ws = (q.watchlist ?? []).sorted {
                ($0.chgPct ?? -999) > ($1.chgPct ?? -999)   // 涨幅最大在最上
            }
            // 增量更新:行数一致时复用 QuoteRowView 只更新文本(3s 轮询不再全量重建,不丢滚动/无闪动)
            let existing = list.views.compactMap { $0 as? QuoteRowView }
            let sameOrder = existing.count == ws.count && existing.count > 0
                && zip(existing, ws).allSatisfy { $0.0.code == $0.1.code }
            if sameOrder {
                for (i, w) in ws.enumerated() {
                    let chg = w.chgPct ?? 0
                    existing[i].set(name: w.name, price: String(format: "%.2f", w.price ?? 0),
                                    chg: String(format: "%+.2f%%", chg), up: chg >= 0, code: w.code) {
                        openChart(w.code, w.name)
                    }
                }
            } else {
                list.views.forEach { $0.removeFromSuperview() }
                for w in ws {
                    let chg = w.chgPct ?? 0
                    let row = QuoteRowView()
                    row.set(name: w.name, price: String(format: "%.2f", w.price ?? 0),
                            chg: String(format: "%+.2f%%", chg), up: chg >= 0, code: w.code) {
                        openChart(w.code, w.name)
                    }
                    // 行尾 ✕ 删除自选(一次挂载)
                    let code = w.code
                    row.setRemove {
                        Task { _ = try? await API.request("DELETE", "/api/market/watchlist/\(code)") }
                    }
                    list.addView(row, in: .leading)
                }
                list.fitTo(minHeight: 210)
            }
        }
    }
    // 轮询引擎:交易日+股票时段内 3s 拉行情K线(8787 同款开关);初始快照一次
    let poll = PollEngine(label: "market",
                          inHours: { TradingHours.isTradingDay() && TradingHours.stock() },
                          interval: 3) { await reloadMarket() }
    poll.start()
    // 监控级别胶囊:嵌在卡片标题行右侧(紧凑字号,不另占一行);选中即落库+立即触发扫描,持久化
    let lvlBar = PillBar(items: [("5m", "5m"), ("15m", "15m"), ("30m", "30m"),
                                 ("60m", "60m"), ("4h", "4h"), ("day", "日线")], fontSize: 10)
    lvlBar.setAccessibilityIdentifier("wd-monitor-level")
    lvlBar.toolTip = t("信号监控级别")
    lvlBar.select("4h", fire: false)   // 默认级:回填前不误导
    c.addHeadAccessory(lvlBar)   // 标题行尾,紧跟 meta,栈管理不漂移
    Task {
        struct LevelResp: Decodable { let level: String; let choices: [String] }
        // 回填带重试:App 启动快于后端就绪时一次 GET 会连接失败,胶囊会卡在默认级
        for _ in 0..<30 {
            if let r = try? await API.get("/api/chan/monitor-level", as: LevelResp.self) {
                await MainActor.run {
                    let ids = [("5m", "5m"), ("15m", "15m"), ("30m", "30m"),
                               ("60m", "60m"), ("4h", "4h"), ("day", "日线")].map(\.0)
                    if let i = ids.firstIndex(of: r.level) { lvlBar.select(ids[i], fire: false) }
                }
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
    lvlBar.onSelect = { lv in
        Task {
            _ = try? await API.request("PUT", "/api/chan/monitor-level", ["level": lv])
            NotificationCenter.default.post(name: .init("wd.smartRefresh"), object: nil)
        }
    }
    // 「策略信号」立即选股按钮(行尾靠右):点击→后台跑选股→完成后全卡刷新
    let runBtn = ProgressButton(title: t("⚡ 策略信号"))
    runBtn.setAccessibilityIdentifier("wd-selection-run")
    let spring = NSView()
    spring.setContentHuggingPriority(.init(1), for: .horizontal)
    let runT = NullableTarget {
        Task {
            await MainActor.run {
                runBtn.isEnabled = false
                runBtn.title = t("选股中…")
                runBtn.progress = 0.35
            }
            struct SelRun: Decodable { let ok: Bool }
            _ = try? await API.postJSON("/api/chan/selection/run", body: [:], as: SelRun.self)
            struct SelStatus: Decodable { let running: Bool }
            for _ in 0..<240 {                      // 上限8分钟防悬挂
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let st = try? await API.get("/api/chan/selection/status",
                                                  as: SelStatus.self) else { continue }
                if !st.running { break }
            }
            await MainActor.run {
                runBtn.progress = 0
                runBtn.title = t("⚡ 策略信号")
                runBtn.isEnabled = true
                NotificationCenter.default.post(name: .init("wd.smartRefresh"), object: nil)
            }
        }
    }
    runBtn.target = runT
    runBtn.action = #selector(NullableTarget.fire)
    c.row([poll.button, spring, runBtn], spacing: 10)
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

    // 头部:轮次(安静灰字) + 下一选股日(更弱)
    let roundBadge = ChipView("—", tint: .wdText3)   // 灰化:金色只留给"会被执行的决策"
    let nextL = label("", size: 10, color: .wdText3, mono: true)
    let head = NSStackView(views: [roundBadge, NSView(), nextL])
    head.orientation = .horizontal; head.alignment = .centerY; head.spacing = 8
    c.block(head)

    let list = FlippedStack()
    list.orientation = .vertical; list.alignment = .leading; list.spacing = 9
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
            let willBuy = i < 3   // 策略:收盘买入评分前三(金色细条=会被执行的决策)
            // 名次:灰字序号;前三金色加粗
            let rankL = label(String(i + 1), size: 11.5, bold: willBuy,
                              color: willBuy ? accent : NSColor.wdText3, mono: true)
            rankL.translatesAutoresizingMaskIntoConstraints = false
            rankL.widthAnchor.constraint(equalToConstant: 18).isActive = true
            rankL.alignment = .right
            // 名称 + 副行(入选理由/出场标记);名称保持主字色(金色只留细条/名次/评分)
            let nameL = label(st.name, size: 13, bold: willBuy, color: .wdText)
            nameL.lineBreakMode = .byTruncatingTail
            let exited = !(st.exitWhy ?? "").isEmpty
            let hitsTxt = exited
                ? (en ? "exited · " : "已出场 · ") + (st.exitWhy ?? "")
                : (st.hits ?? []).prefix(2).joined(separator: " · ")
            let hitsL = label(hitsTxt, size: 9.5,
                              color: exited ? NSColor.wdWarn : NSColor.wdText3)
            hitsL.lineBreakMode = .byTruncatingTail
            let nameCol = NSStackView(views: [nameL, hitsL])
            nameCol.orientation = .vertical; nameCol.alignment = .leading; nameCol.spacing = 3
            // 评分:主字色大数字右对齐;快照轮退化参考价(小灰)
            let scoreL = st.score != nil
                ? label(String(format: "%.0f", st.score ?? 0), size: 15, bold: true,
                        color: willBuy ? accent : .wdText, mono: true)
                : label(String(format: "%.2f", st.price ?? 0), size: 12, bold: false,
                        color: .wdText2, mono: true)
            // 前三:左侧 2px 金色细条(克制标记,替代"拟买"补丁)
            var rowViews: [NSView] = []
            if willBuy {
                let bar = NSView()
                bar.wantsLayer = true
                bar.layer?.backgroundColor = accent.withAlphaComponent(0.85).cgColor
                bar.layer?.cornerRadius = 1
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.widthAnchor.constraint(equalToConstant: 2.5).isActive = true
                bar.heightAnchor.constraint(equalToConstant: 30).isActive = true
                rowViews.append(bar)
            } else {
                let sp = NSView()
                sp.translatesAutoresizingMaskIntoConstraints = false
                sp.widthAnchor.constraint(equalToConstant: 2.5).isActive = true
                rowViews.append(sp)
            }
            let row = NSStackView(views: rowViews + [rankL, nameCol, NSView(), scoreL])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 9
            nameCol.setContentHuggingPriority(.defaultLow, for: .horizontal)
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
    /// 后端返回的当前级别(权威);卡片只在用户点胶囊时才 PUT 切换。
    /// 轮询绝不带 ?level= 参数——snapshot 的语义是"带参即切换",默认 5m 会把重启后的 4h 改写回去。
    var onServerLevel: ((String) -> Void)?
    private(set) var hasData = false
    func reload(_ rows: NSStackView) async {
        guard let f = try? await API.get("/api/chan/futures", as: FuturesState.self) else { return }
        hasData = !(f.stocks ?? []).isEmpty
        await MainActor.run {
            if let lv = f.level { onServerLevel?(lv) }
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
    let rows = NSStackView()
    rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 3
    c.block(rows)
    let state = LevelState()
    let reloadAll: () async -> Void = { await state.reload(rows) }
    // 监控级别胶囊:标题行尾(与自选行情同款);期货级别独立持久化,与股票互不相干
    let lvlBar = PillBar(items: [("1m", "1m"), ("5m", "5m"), ("15m", "15m"), ("30m", "30m"),
                                 ("60m", "60m"), ("4h", "4h")], fontSize: 10)
    lvlBar.setAccessibilityIdentifier("wd-futures-level")
    lvlBar.toolTip = t("期货信号监控级别")
    lvlBar.select("5m", fire: false)   // 默认级:回填前不误导
    c.addHeadAccessory(lvlBar)
    // 后端级别回填(每 3s 轮询响应都带 level,这里兜底处理休市时段轮询不跑的情况)
    state.onServerLevel = { lv in
        if lvlBar.selected != lv { lvlBar.select(lv, fire: false) }
    }
    lvlBar.onSelect = { lv in
        Task {
            _ = try? await API.request("PUT", "/api/chan/futures-level", ["level": lv])
            await state.reload(rows)
            NotificationCenter.default.post(name: .init("wd.smartRefresh"), object: nil)
        }
    }
    Task {
        struct FLevelResp: Decodable { let level: String; let choices: [String] }
        // 回填带重试:App 启动快于后端就绪时一次 GET 会连接失败,胶囊会永远卡在默认 5m
        for _ in 0..<30 {
            if let r = try? await API.get("/api/chan/futures-level", as: FLevelResp.self) {
                await MainActor.run {
                    if r.choices.contains(r.level) { lvlBar.select(r.level, fire: false) }
                }
                break
            }
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        // 首拉重试:App 先于后端期货首轮扫描启动(scан约6秒)或休市轮询停摆时,
        // 空数据会一直空着——重试直到出数据(最多 ~40 秒)
        for _ in 0..<20 {
            await state.reload(rows)
            if state.hasData { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
    // 轮询引擎:交易日+期货时段(日盘+夜盘)3s;休市按钮显示休市态
    let poll = PollEngine(label: "futures",
                          inHours: { TradingHours.isTradingDay() && TradingHours.futures() },
                          interval: 3) { await reloadAll() }
    poll.start()
    c.row([poll.button])
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
