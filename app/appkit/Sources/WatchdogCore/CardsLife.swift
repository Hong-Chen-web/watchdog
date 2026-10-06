import AppKit

// MARK: - 生活类卡:今日待办 / 收支账本 / 预算 / 目标 / 日志与复盘

// MARK: 今日待办(回车即存;勾完成弹一句话总结)

func makeTodoCard() -> CardView {
    let c = CardView(title: t("今日待办"), icon: "list-checks", id: "todo")
    let list = NSStackView()
    list.orientation = .vertical; list.alignment = .leading; list.spacing = 7
    c.block(list)
    // 添加行:回车即存
    let input = NSTextField()
    input.placeholderString = t("添加待办,回车保存")
    input.font = .systemFont(ofSize: 12)
    input.translatesAutoresizingMaskIntoConstraints = false
    input.widthAnchor.constraint(equalToConstant: 240).isActive = true
    let addBtn = textButton(t("添加")) {
        let s = input.stringValue.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return }
        input.stringValue = ""
        Task {
            _ = try? await API.post("/api/todos", body: ["title": s])
            await reload()
        }
    }
    let enterT = NullableTarget { addBtn.performClick(nil) }
    input.target = enterT
    input.action = #selector(NullableTarget.fire)
    c.row([input, addBtn], spacing: 8)

    @Sendable func reload() async {
        guard let todos = try? await API.get("/api/todos", as: [TodoItem].self) else { return }
        await MainActor.run {
            list.views.forEach { $0.removeFromSuperview() }
            for td in todos {
                let cb = NSButton(checkboxWithTitle: td.title, target: nil, action: nil)
                cb.font = .systemFont(ofSize: 12.5)
                cb.state = td.done ? .on : .off
                cb.setContentHuggingPriority(.defaultLow, for: .horizontal)
                let info = label([td.dueDate ?? "", td.summary != nil ? "📝" : ""]
                    .filter { !$0.isEmpty }.joined(separator: "  "),
                    size: 10, color: .wdText3, mono: true)
                // 优先级彩条(Web 稿同款:1红/2黄/3蓝)
                let strip = NSView()
                strip.wantsLayer = true
                strip.layer?.backgroundColor = (td.priority <= 1 ? NSColor(hex: "FF453A")
                    : td.priority == 2 ? NSColor(hex: "FFD60A") : NSColor(hex: "0A84FF")).cgColor
                strip.layer?.cornerRadius = 1.5
                strip.translatesAutoresizingMaskIntoConstraints = false
                strip.widthAnchor.constraint(equalToConstant: 3).isActive = true
                strip.heightAnchor.constraint(equalToConstant: 14).isActive = true
                let r = NSStackView(views: [strip, cb, info])
                r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 8
                list.addView(r, in: .leading)
                cb.onAction {
                    let on = cb.state == .on
                    Task {
                        _ = try? await API.request("PATCH", "/api/todos/\(td.id)", ["done": on])
                        await reload()
                    }
                    if on {
                        if let s = inputAlert(title: (wdLang == "en" ? "Summary of '" : "一句话总结「") + td.title + (wdLang == "en" ? "'" : "」"), placeholder: wdLang == "en" ? "What did it produce…" : "今天这件事的产出是…") {
                            Task { _ = try? await API.request("PATCH", "/api/todos/\(td.id)", ["summary": s]) }
                        }
                    }
                }
            }
        }
    }
    Task {
        while true {
            await reload()
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }
    return c
}

// MARK: 收支账本(收入/支出/结余 + 月/年双环 + 记一笔 + 最近明细)

func makeLedgerCard() -> CardView {
    let c = CardView(title: t("收支账本"), icon: "wallet", meta: "", id: "ledger")
    var month = curMonth()   // 当前筛选月(可翻)
    let income = label("—", size: 17, bold: true, color: .wdUp, mono: true)
    let expense = label("—", size: 17, bold: true, mono: true)
    let net = label("—", size: 17, bold: true, mono: true)
    let mRing = RingLabelView(); mRing.lineWidth = 5; mRing.ringSize = 58
    let yRing = RingLabelView(); yRing.lineWidth = 5; yRing.ringSize = 58
    c.row([label(t("收入"), size: 10.5, color: .wdText3), income,
           label(t("支出"), size: 10.5, color: .wdText3), expense,
           label(t("结余"), size: 10.5, color: .wdText3), net], spacing: 9)
    var catNames: [String] = []   // 提前声明:月份切换闭包经 reload 间接引用
    // 月份切换:◀ 2026-10 ▶(明细/汇总随月)
    let monthLabel = label(month, size: 12, bold: true, mono: true)
    // 闭包不直接调 reload(声明序问题):改发通知,函数末尾订阅执行
    let prevBtn = textButton("◀") {
        month = shiftMonth(month, -1) ?? month
        monthLabel.stringValue = month
        c.metaLabel.stringValue = month
        NotificationCenter.default.post(name: .init("wd.ledgerReload"), object: nil)
    }
    let nextBtn = textButton("▶") {
        month = shiftMonth(month, 1) ?? month
        monthLabel.stringValue = month
        c.metaLabel.stringValue = month
        NotificationCenter.default.post(name: .init("wd.ledgerReload"), object: nil)
    }
    let monthRow = NSStackView(views: [prevBtn, monthLabel, nextBtn])
    monthRow.orientation = .horizontal; monthRow.alignment = .centerY; monthRow.spacing = 10
    let rings = NSStackView(views: [mRing, yRing])
    rings.orientation = .horizontal; rings.alignment = .centerY; rings.spacing = 24
    let topRow = NSStackView(views: [rings, NSView(), monthRow])
    topRow.orientation = .horizontal; topRow.alignment = .centerY; topRow.spacing = 12
    c.block(topRow)

    // 明细区:卡内滚动看全部(当月 200 笔)——先声明,记一笔的刷新闭包会引用
    let entries = FlippedStack()
    entries.orientation = .vertical; entries.alignment = .leading; entries.spacing = 4
    let entriesScroll = NSScrollView()
    entriesScroll.documentView = entries
    entriesScroll.hasVerticalScroller = true
    entriesScroll.drawsBackground = false
    entriesScroll.scrollerStyle = .overlay
    entriesScroll.translatesAutoresizingMaskIntoConstraints = false
    entriesScroll.heightAnchor.constraint(equalToConstant: 240).isActive = true
    entries.widthAnchor.constraint(greaterThanOrEqualTo: entriesScroll.contentView.widthAnchor).isActive = true
    let entriesCaption = label(t("最近明细"), size: 10.5, bold: true, color: .wdText3)
    c.body.addView(entriesCaption, in: .leading)
    c.block(entriesScroll)

    // 智能记一笔:自然语言直接落库(本地规则解析)
    let smartInput = NSTextField()
    smartInput.placeholderString = wdLang == "en" ? "e.g. lunch ¥35 yesterday…" : "直接说:昨天午饭花了35"
    smartInput.font = .systemFont(ofSize: 11.5)
    smartInput.translatesAutoresizingMaskIntoConstraints = false
    smartInput.widthAnchor.constraint(equalToConstant: 205).isActive = true
    let smartHint = label("", size: 10.5, color: .wdText3, mono: true)
    let smartT = NullableTarget {
        let txt = smartInput.stringValue.trimmingCharacters(in: .whitespaces)
        guard !txt.isEmpty else { return }
        smartInput.stringValue = ""
        Task {
            if let r = try? await API.post("/api/ledger/smart", body: ["text": txt]) {
                await MainActor.run {
                    smartHint.textColor = .wdText3
                    smartHint.stringValue = "✓ \(txt)"
                    Task { await reload() }
                }
            } else {
                await MainActor.run {
                    smartHint.textColor = .wdWarn
                    smartHint.stringValue = wdLang == "en" ? "can't parse" : "没识别到金额,试试『午饭花了35』"
                }
            }
        }
    }
    smartInput.target = smartT
    smartInput.action = #selector(NullableTarget.fire)
    let smartRow = NSStackView(views: [smartInput, smartHint])
    smartRow.orientation = .horizontal; smartRow.alignment = .centerY; smartRow.spacing = 8
    c.body.addView(smartRow, in: .leading)

    // 记一笔:弹表单(日期/事项/分类/金额)
    let addBtn = textButton("＋ " + t("记一笔")) {
        let dateF = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        dateF.stringValue = todayStr()
        let payeeF = NSTextField()
        payeeF.placeholderString = wdLang == "en" ? "e.g. lunch" : "比如:吃饭"
        let catPop = NSPopUpButton()
        catPop.addItems(withTitles: catNames.isEmpty ? ["食物"] : catNames)
        let amtF = NSTextField()
        amtF.placeholderString = wdLang == "en" ? "Amount" : "支出金额"
        guard let r = promptForm(title: t("记一笔"), rows: [
            (t("日期"), dateF), (t("事项"), payeeF), (t("分类"), catPop), (t("金额"), amtF),
        ]) else { return }
        let amt = Double(r[t("金额")] ?? "") ?? 0
        let cat = r["__popup__"] ?? catPop.titleOfSelectedItem ?? "其他"
        guard amt > 0 else { return }
        Task {
            _ = try? await API.post("/api/ledger/entries", body: [
                "date": r[t("日期")] ?? todayStr(), "payee": r[t("事项")] ?? "",
                "category": cat, "amount": amt])
            await reload()
        }
    }
    c.row([addBtn])

    @Sendable func reload() async {
        let yStart = String(month.prefix(4)) + "-01-01"
        let yEnd = String(month.prefix(4)) + "-12-31"
        async let s1 = try? await API.get("/api/ledger/summary?month=\(month)", as: LedgerSummary.self)
        async let s2 = try? await API.get("/api/ledger/summary?start=\(yStart)&end=\(yEnd)", as: LedgerSummary.self)
        async let es = try? await API.get("/api/ledger/entries?month=\(month)&limit=200", as: [LedgerEntry].self)
        guard let s = await s1, let y = await s2 else { return }
        let recent = await es ?? []
        await MainActor.run {
            catNames = s.categories.map(\.name)
            income.stringValue = "+" + String(format: "%.0f", s.income)
            expense.stringValue = "-" + String(format: "%.0f", s.expense)
            net.stringValue = String(format: "%+.0f", s.net)
            let mB = s.categories.reduce(0) { $0 + $1.budgetMonth }
            let yB = s.categories.reduce(0) { $0 + ($1.budgetYear > 0 ? $1.budgetYear : $1.budgetMonth * 12) }
            let mp = mB > 0 ? s.expense / mB : 0, yp = yB > 0 ? y.expense / yB : 0
            for (ring, p, cap) in [(mRing, mp, t("月度")), (yRing, yp, t("年度"))] {
                ring.pct = p
                ring.valueText = String(format: "%.0f%%", p * 100)
                ring.caption = cap
                ring.tint = p > 1 ? .wdUp : p > 0.8 ? .wdWarn : .wdDown
            }
            entriesCaption.stringValue = t("最近明细") + "(\(recent.count))"
            entries.views.forEach { $0.removeFromSuperview() }
            let catColor = Dictionary(uniqueKeysWithValues: s.categories.map { ($0.name, NSColor(hex: $0.color)) })
            for e in recent {
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.backgroundColor = (catColor[e.category] ?? .wdAccent).cgColor
                dot.layer?.cornerRadius = 3
                dot.translatesAutoresizingMaskIntoConstraints = false
                dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
                let r = NSStackView(views: [
                    label(String(e.date.prefix(10)), size: 10.5, color: .wdText3, mono: true),
                    dot,
                    label((e.payee?.isEmpty == false ? e.payee! : e.category), size: 12, color: .wdText2),
                    label(e.category, size: 10, color: .wdText3),
                    label(String(format: "%.0f", e.amount), size: 12, bold: true,
                          color: e.amount < 0 ? .wdText : .wdUp, mono: true),
                ])
                r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 10
                entries.addView(r, in: .leading)
            }
            entries.fitTo(minHeight: 240)   // 铺尺寸,否则滚动视口空白
        }
    }
    NotificationCenter.default.addObserver(forName: .init("wd.ledgerReload"), object: nil, queue: .main) { _ in
        MainActor.assumeIsolated { Task { await reload() } }
    }
    Task {
        while true {
            await reload()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
    return c
}

// MARK: 年度财务分析(总览/趋势/异常/建议/下年计划)

func makeAnnualCard() -> CardView {
    let c = CardView(title: wdLang == "en" ? "Annual Finance" : "年度财务分析",
                     icon: "chart-donut", meta: String(Date().description.prefix(4)), id: "annual")
    let accent = wdModuleAccent("budget")
    let en = wdLang == "en"

    func kpi(_ cap: String) -> (NSStackView, NSTextField) {
        let v = label("—", size: 15, bold: true, mono: true)
        let col = NSStackView(views: [label(cap, size: 9.5, color: .wdText3), v])
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 3
        return (col, v)
    }
    let (cOut, vOut) = kpi(en ? "YEAR OUT" : "年度支出")
    let (cAvg, vAvg) = kpi(en ? "AVG/MO" : "月均")
    let (cMax, vMax) = kpi(en ? "MAX ITEM" : "最大单笔")
    let (cSave, vSave) = kpi(en ? "SAVE%" : "结余率")
    let kpiRow = NSStackView(views: [cOut, cAvg, cMax, cSave])
    kpiRow.orientation = .horizontal; kpiRow.alignment = .top; kpiRow.spacing = 34
    c.block(kpiRow)

    // 月度柱状(自绘横排)
    let bars = NSStackView()
    bars.orientation = .horizontal; bars.alignment = .bottom; bars.spacing = 10
    c.block(bars)

    // 左:分类结构 右:异常+建议
    let catL = NSStackView()
    catL.orientation = .vertical; catL.alignment = .leading; catL.spacing = 6
    let rightL = NSStackView()
    rightL.orientation = .vertical; rightL.alignment = .leading; rightL.spacing = 5
    let cols = NSStackView(views: [catL, rightL])
    cols.orientation = .horizontal; cols.alignment = .top; cols.spacing = 24
    c.block(cols)
    catL.translatesAutoresizingMaskIntoConstraints = false
    catL.widthAnchor.constraint(equalTo: cols.widthAnchor, multiplier: 0.34).isActive = true

    let planL = label("", size: 10.5, color: .wdText3, mono: true)
    c.row([planL])

    func apply(_ r: AnnualReport) {
        vOut.stringValue = fmtWan(r.totalOut)
        vAvg.stringValue = fmtWan(r.avgMonth)
        vMax.stringValue = fmtWan(r.maxItem)
        vSave.stringValue = String(format: "%.0f%%", r.saveRate)
        vSave.textColor = r.saveRate >= 20 ? .wdDown : .wdWarn
        c.metaLabel.stringValue = String(r.year) + (en ? " · Annual" : " 年报")
        // 柱
        bars.views.forEach { $0.removeFromSuperview() }
        let mx = r.months.map(\.expense).max() ?? 1
        for m in r.months {
            let col = NSStackView(views: [
                label(String(format: "%.0f", m.expense / 1000), size: 8, color: .wdText3, mono: true),
                NSBox().also { b in b.boxType = .separator; b.translatesAutoresizingMaskIntoConstraints = false
                    b.widthAnchor.constraint(equalToConstant: 16).isActive = true
                    b.heightAnchor.constraint(equalToConstant: max(3, CGFloat(m.expense / mx) * 46)).isActive = true
                    b.fillColor = accent.withAlphaComponent(0.55) },
                label(String(Int(m.month) ?? 0), size: 8, color: .wdText3, mono: true),
            ])
            col.orientation = .vertical; col.alignment = .centerX; col.spacing = 2
            bars.addView(col, in: .leading)
        }
        // 分类
        catL.views.forEach { $0.removeFromSuperview() }
        catL.addView(label(en ? "STRUCTURE" : "分类结构", size: 10.5, bold: true, color: .wdText3), in: .leading)
        for cat in r.cats.prefix(6) {
            let bar = BarView()
            bar.ratio = cat.pct / 100
            bar.tint = accent
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.widthAnchor.constraint(equalToConstant: 90).isActive = true
            bar.heightAnchor.constraint(equalToConstant: 5).isActive = true
            let row = NSStackView(views: [
                label(cat.cat, size: 11.5, color: .wdText2),
                bar,
                label(String(format: "%.0f%%", cat.pct), size: 10.5, color: .wdText3, mono: true)])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
            catL.addView(row, in: .leading)
        }
        // 异常+建议
        rightL.views.forEach { $0.removeFromSuperview() }
        rightL.addView(label(en ? "ANOMALIES" : "异常账单", size: 10.5, bold: true, color: .wdWarn), in: .leading)
        for a in (r.anomalies ?? []).prefix(4) {
            let row = NSStackView(views: [
                label(String(a.date.prefix(7)), size: 10, color: .wdText3, mono: true),
                label(a.payee, size: 11.5),
                label(fmtWan(a.amount), size: 11, bold: true, color: .wdUp, mono: true),
                label(a.why, size: 9.5, color: .wdText3),
            ])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
            rightL.addView(row, in: .leading)
        }
        rightL.addView(label(en ? "TIPS" : "改进建议", size: 10.5, bold: true, color: .wdDown), in: .leading)
        for t in (r.tips ?? []).prefix(4) {
            rightL.addView(label("· " + t, size: 11, color: .wdText2), in: .leading)
        }
        // 下年计划基线
        let plan = r.nextYearPlan ?? [:]
        let top3 = plan.sorted { $0.value > $1.value }.prefix(3)
            .map { "\($0.key)\(Int($0.value))/月" }.joined(separator: " · ")
        planL.stringValue = (en ? "Next-year baseline: " : "下年预算基线: ") + top3
    }

    Task {
        while true {
            if let r = try? await API.get("/api/ledger/annual", as: AnnualReport.self) {
                await MainActor.run { apply(r) }
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000_000)
        }
    }
    return c
}

// MARK: 预算与目标(月/年切换 + 分类增删改 + 目标,合并卡)

func makeBudgetCard() -> CardView {
    let c = CardView(title: wdLang == "en" ? "Budget & Goals" : "预算与目标",
                     icon: "chart-donut", meta: curMonth(), id: "budget")
    let en = wdLang == "en"

    var span = "month"
    let rows = FlippedStack()   // 提前声明:编辑/添加/周期切换闭包都引用
    rows.orientation = .vertical; rows.alignment = .leading; rows.spacing = 7
    let spanBar = PillBar(items: [("month", t("月")), ("year", t("年"))])
    let editBtn = textButton(t("编辑")) {
        Task {
            guard let sm = try? await API.get("/api/ledger/summary?month=\(curMonth())", as: LedgerSummary.self) else { return }
            await MainActor.run { showBudgetEditor(cats: sm.categories) { await reload() } }
        }
    }
    let addCatBtn = textButton("＋" + (en ? " Category" : " 分类")) {
        guard let name = inputAlert(title: en ? "New category" : "新分类名称",
                                    placeholder: en ? "e.g. insurance" : "如:保险") else { return }
        Task {
            _ = try? await API.post("/api/ledger/categories", body: ["name": name])
            await reload()
        }
    }
    let barRow = NSStackView(views: [label(en ? "Span" : "周期", size: 10.5, color: .wdText3),
                                     spanBar, NSView(), addCatBtn, editBtn])
    barRow.orientation = .horizontal; barRow.alignment = .centerY; barRow.spacing = 8
    c.block(barRow)
    spanBar.onSelect = { id in span = id; Task { await reload() } }

    c.block(rows)

    @Sendable func reload() async {
        let month = curMonth()
        let yStart = String(month.prefix(4)) + "-01-01", yEnd = String(month.prefix(4)) + "-12-31"
        async let m1 = try? await API.get("/api/ledger/summary?month=\(month)", as: LedgerSummary.self)
        async let y1 = try? await API.get("/api/ledger/summary?start=\(yStart)&end=\(yEnd)", as: LedgerSummary.self)
        guard let sm = await m1, let sy = await y1 else { return }
        // 年视图实际值:用年度 summary 同名分类的 actual
        let yActual = Dictionary(uniqueKeysWithValues: (sy.categories).map { ($0.name, $0.actual) })
        guard let g = try? await API.get("/api/goals", as: GoalsResponse.self) else { return }
        await MainActor.run {
            rows.views.forEach { $0.removeFromSuperview() }
            for cat in sm.categories {
                let budget = span == "month" ? cat.budgetMonth : cat.budgetYear
                let actual = span == "month" ? cat.actual : (yActual[cat.name] ?? 0)
                guard budget > 0 || actual > 0 else { continue }
                let p = budget > 0 ? actual / budget : 0
                let catC = NSColor(hex: cat.color)
                let bar = BarView()
                bar.ratio = p
                bar.tint = p > 1 ? .wdUp : p > 0.8 ? .wdWarn : catC
                bar.translatesAutoresizingMaskIntoConstraints = false
                bar.widthAnchor.constraint(equalToConstant: 110).isActive = true
                bar.heightAnchor.constraint(equalToConstant: 6).isActive = true
                let dot = NSView()
                dot.wantsLayer = true
                dot.layer?.backgroundColor = catC.cgColor
                dot.layer?.cornerRadius = 3
                dot.translatesAutoresizingMaskIntoConstraints = false
                dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
                dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
                let r = NSStackView(views: [
                    dot,
                    label(cat.name, size: 12, color: .wdText2),
                    bar,
                    label(String(format: "%.0f / %.0f", actual, budget), size: 11, color: .wdText3, mono: true),
                    textButton("✕", size: 10) {
                        Task {
                            _ = try? await API.request("DELETE", "/api/ledger/categories/\(cat.id)")
                            await reload()
                        }
                    },
                ])
                r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 10
                rows.addView(r, in: .leading)
            }
            // —— 目标区块:月视图只看月度目标;年视图看年度+长期 ——
            let wantScopes: Set<String> = span == "month" ? ["month"] : ["year", "long"]
            rows.addView(label(en ? "GOALS" : "目标", size: 10.5, bold: true, color: .wdText3), in: .leading)
            for grp in g.groups where !grp.items.isEmpty && wantScopes.contains(grp.scope) {
                rows.addView(label(grp.label, size: 10.5, bold: true, color: .wdText3), in: .leading)
                for it in grp.items.prefix(5) {
                    let done = !(it.result ?? "").isEmpty
                    let dot = label(done ? "✅" : (it.scope == "long" ? "🟠" : it.scope == "year" ? "🟣" : "🔵"), size: 11)
                    let title = label(it.title + (done ? "(完成)" : ""), size: 12.5,
                                      color: done ? .wdText3 : .wdText)
                    let r = NSStackView(views: [dot, title])
                    r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 8
                    rows.addView(r, in: .leading)
                    let gid = it.id
                    let hit = ClickView(frame: .zero)
                    hit.onClick = {
                        Task {
                            _ = try? await API.request("PATCH", "/api/goals/\(gid)",
                                                       ["result": done ? "" : "已完成"])
                            await reload()
                        }
                    }
                    hit.translatesAutoresizingMaskIntoConstraints = false
                    r.addSubview(hit)
                    NSLayoutConstraint.activate([
                        hit.leadingAnchor.constraint(equalTo: r.leadingAnchor),
                        hit.trailingAnchor.constraint(equalTo: r.trailingAnchor),
                        hit.topAnchor.constraint(equalTo: r.topAnchor),
                        hit.bottomAnchor.constraint(equalTo: r.bottomAnchor),
                    ])
                }
            }
            rows.fitTo(minHeight: 60)
        }
    }
    let addGoal = textButton("＋ " + t("添加目标")) {
        let scopePop = NSPopUpButton()
        scopePop.addItems(withTitles: [t("月度"), t("年度"), t("长期")])
        let titleF = NSTextField()
        titleF.placeholderString = t("目标内容")
        guard let r = promptForm(title: t("添加目标"), rows: [(t("范围"), scopePop), (t("目标内容"), titleF)]),
              let gt = (r[t("目标内容")] ?? "").trimmingCharacters(in: .whitespaces).isEmpty ? nil : r[t("目标内容")] else { return }
        let scope = [t("月度"): "month", t("年度"): "year", t("长期"): "long"][r["__popup__"] ?? t("月度")] ?? "month"
        Task {
            _ = try? await API.post("/api/goals", body: ["scope": scope, "title": gt])
            await reload()
        }
    }
    c.row([addGoal])
    Task {
        while true {
            await reload()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
    return c
}

// MARK: 日志与复盘(左完成+总结 / 右时间线)

func makeJournalCard() -> CardView {
    let c = CardView(title: t("日志与复盘"), icon: "notebook", id: "journal")

    // 左列:今日完成 + 今日总结
    let events = NSStackView()
    events.orientation = .vertical; events.alignment = .leading; events.spacing = 6
    let summary = label("…", size: 11.5, color: .wdText2)
    // 右列时间线先声明(writeBtn 的刷新闭包经由 reload 间接引用)
    let timeline = NSStackView()
    timeline.orientation = .vertical; timeline.alignment = .leading; timeline.spacing = 7
    let writeBtn = textButton("✎ " + t("写今日总结")) {
        guard let s = inputAlert(title: t("今日总结"), placeholder: wdLang == "en" ? "One line — don't let today slip away." : "一句话,别稀里糊涂过完这一天") else { return }
        Task {
            _ = try? await API.post("/api/journal", body: ["kind": "daily", "content": s])
            await reload()
        }
    }
    let leftCol = NSStackView(views: [label(t("今日完成"), size: 10.5, bold: true, color: .wdText3)])
    leftCol.orientation = .vertical; leftCol.alignment = .leading; leftCol.spacing = 8
    leftCol.addView(events, in: .leading)
    leftCol.addView(label(t("今日总结"), size: 10.5, bold: true, color: .wdText3), in: .leading)
    leftCol.addView(summary, in: .leading)
    leftCol.addView(writeBtn, in: .leading)

    // 右列:时间线(entries)
    let rightCol = NSStackView(views: [label(wdLang == "en" ? "TIMELINE" : "时间线", size: 10.5, bold: true, color: .wdText3), timeline])
    rightCol.orientation = .vertical; rightCol.alignment = .leading; rightCol.spacing = 8

    let hWrap = NSStackView(views: [leftCol, rightCol])
    hWrap.orientation = .horizontal; hWrap.alignment = .top; hWrap.spacing = 28
    c.block(hWrap)
    leftCol.translatesAutoresizingMaskIntoConstraints = false
    leftCol.widthAnchor.constraint(equalTo: hWrap.widthAnchor, multiplier: 0.48).isActive = true

    @Sendable func reload() async {
        guard let j = try? await API.get("/api/journal", as: JournalDay.self) else { return }
        await MainActor.run {
            events.views.forEach { $0.removeFromSuperview() }
            for e in j.events.prefix(6) {
                let r = NSStackView(views: [
                    label("✓", size: 11, color: .wdDown),
                    label(e.title, size: 12, color: .wdText2),
                    label(e.summary ?? "", size: 10.5, color: .wdText3),
                ])
                r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 8
                events.addView(r, in: .leading)
            }
            summary.stringValue = j.todaySummary ?? (wdLang == "en" ? "Not written yet" : "还没写总结")
            summary.textColor = (j.todaySummary ?? "").isEmpty ? .wdWarn : .wdText2
            timeline.views.forEach { $0.removeFromSuperview() }
            for e in (j.entries ?? []).prefix(7) {
                let tag = label(e.kind == "daily" ? (wdLang == "en" ? "DAY" : "每日")
                                  : (wdLang == "en" ? "NOTE" : "笔记"), size: 9, color: .wdText3, mono: true)
                tag.translatesAutoresizingMaskIntoConstraints = false
                tag.widthAnchor.constraint(equalToConstant: 30).isActive = true
                let dt = label(String(e.date.prefix(10)), size: 10, color: .wdText3, mono: true)
                dt.translatesAutoresizingMaskIntoConstraints = false
                dt.widthAnchor.constraint(equalToConstant: 76).isActive = true
                let txt = label(e.content, size: 11, color: .wdText2)
                let r = NSStackView(views: [tag, dt, txt])
                r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 8
                timeline.addView(r, in: .leading)
            }
        }
    }
    Task {
        while true {
            await reload()
            try? await Task.sleep(nanoseconds: 60_000_000_000)
        }
    }
    return c
}

