// [LEGACY] 旧原生仪表盘(App 壳已停用;保留供回退参考与渲染测试)。见 AGENTS.md §2 结构说明。

import AppKit

// MARK: - 总览面板:三指标小方块 + 今日待办明细(2026-10-16 用户定版)
// 总览不再铺全部卡片:卡片分散在各组里,总览只做"今天怎么样"的三个数 + 待办明细。
// 点方块直接跳到对应组(待办/账本/行情)。

/// 日预算(用户令:先按每天 50;后续可接预算表)
let overviewDailyBudget: Double = 50

func makeOverviewCard(openGroup: @escaping (String) -> Void) -> CardView {
    let c = CardView(title: t("总览"), icon: "squares-four", meta: "", id: "__overview")

    // ---- 三方块 ----
    let tilesRow = NSStackView()
    tilesRow.orientation = .horizontal
    tilesRow.alignment = .top
    tilesRow.spacing = 12
    c.block(tilesRow)

    // ---- 待办明细 ----
    c.caption(t("今日待办明细"))
    let todoList = NSStackView()
    todoList.orientation = .vertical
    todoList.alignment = .leading
    todoList.spacing = 7
    c.block(todoList)
    let todoEmpty = label(t("今天没有待办"), size: 12, color: .wdText3)
    c.block(todoEmpty)

    /// 单个小方块:图标 + 大数字 + 标题 + 副行;点击跳组
    func tile(icon: String, tint: NSColor, onTap: @escaping () -> Void) -> (NSView, NSTextField, NSTextField) {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.wdOverlaySoft.cgColor
        v.layer?.cornerRadius = 12
        v.layer?.borderColor = NSColor.wdBorder.cgColor
        v.layer?.borderWidth = 1
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: 196).isActive = true
        v.heightAnchor.constraint(equalToConstant: 112).isActive = true

        let iconBox = NSView()
        iconBox.wantsLayer = true
        iconBox.layer?.backgroundColor = tint.cgColor
        iconBox.layer?.cornerRadius = 7
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        iconBox.widthAnchor.constraint(equalToConstant: 28).isActive = true
        iconBox.heightAnchor.constraint(equalToConstant: 28).isActive = true
        let ic = IconView(icon, size: 15, color: .white)
        ic.translatesAutoresizingMaskIntoConstraints = false
        iconBox.addSubview(ic)
        NSLayoutConstraint.activate([
            ic.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            ic.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
        ])

        let titleL = label("", size: 11.5, color: .wdText3)
        let numL = label("—", size: 26, bold: true, color: .wdText, mono: true)
        let subL = label("", size: 11, color: .wdText3)

        for sv in [iconBox, titleL, numL, subL] {
            sv.translatesAutoresizingMaskIntoConstraints = false
            v.addSubview(sv)
        }
        NSLayoutConstraint.activate([
            iconBox.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            iconBox.topAnchor.constraint(equalTo: v.topAnchor, constant: 14),
            titleL.leadingAnchor.constraint(equalTo: iconBox.trailingAnchor, constant: 8),
            titleL.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor),
            numL.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            numL.topAnchor.constraint(equalTo: iconBox.bottomAnchor, constant: 10),
            subL.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 14),
            subL.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12),
        ])

        let btn = NSButton(title: "", target: nil, action: nil)
        btn.isBordered = false
        btn.wantsLayer = true
        btn.layer?.backgroundColor = NSColor.clear.cgColor
        btn.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(btn)
        NSLayoutConstraint.activate([
            btn.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            btn.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            btn.topAnchor.constraint(equalTo: v.topAnchor),
            btn.bottomAnchor.constraint(equalTo: v.bottomAnchor),
        ])
        btn.onAction { onTap() }
        return (v, numL, subL)
    }

    let (spendV, spendNum, spendSub) = tile(icon: "basket", tint: .wdWarn) { openGroup("账本") }
    let (todoV, todoNum, todoSub) = tile(icon: "list-checks", tint: .wdAccent) { openGroup("待办") }
    let (pnlV, pnlNum, pnlSub) = tile(icon: "chart-line-up", tint: .wdUp) { openGroup("行情") }
    spendV.setAccessibilityIdentifier("wd-ov-spend")
    todoV.setAccessibilityIdentifier("wd-ov-todo")
    pnlV.setAccessibilityIdentifier("wd-ov-pnl")
    for tv in [spendV, todoV, pnlV] { tilesRow.addView(tv, in: .leading) }

    // ---- 数据 ----
    @Sendable func reload() async {
        let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
        let today = df.string(from: Date())
        async let todosT = API.get("/api/todos", as: [TodoItem].self)
        async let ledgerT = API.get("/api/ledger/summary?start=\(today)&end=\(today)", as: LedgerSummary.self)
        async let portT = API.get("/api/portfolio", as: Portfolio.self)
        let (todos, ledger, port) = await (try? todosT, try? ledgerT, try? portT)
        await MainActor.run {
            // ① 支出:今天已花 / 预算
            if let expense = ledger?.expense {
                spendNum.stringValue = "¥" + String(format: "%.1f", expense)
                let left = overviewDailyBudget - expense
                spendSub.stringValue = left >= 0
                    ? String(format: t("预算 ¥%.0f · 剩 ¥%.1f"), overviewDailyBudget, left)
                    : String(format: t("预算 ¥%.0f · 超 ¥%.1f"), overviewDailyBudget, -left)
                spendSub.textColor = left >= 0 ? .wdText3 : .wdDown
            } else {
                spendNum.stringValue = "—"; spendSub.stringValue = t("账本未连上")
            }
            // ② 待办:今天未完成数 + 明细
            if let todos = todos {
                let todayStr = today
                let undone = todos.filter { !$0.done && ($0.dueDate ?? todayStr) <= todayStr }
                let doneToday = todos.filter { $0.done && ($0.completedAt ?? "").hasPrefix(todayStr) }
                todoNum.stringValue = "\(undone.count)"
                todoSub.stringValue = undone.isEmpty
                    ? (doneToday.isEmpty ? t("今天没有待办") : String(format: t("今日已完成 %d 件"), doneToday.count))
                    : String(format: t("未完成 %d · 已完成 %d"), undone.count, doneToday.count)
                todoEmpty.isHidden = !undone.isEmpty
                todoList.views.forEach { $0.removeFromSuperview() }
                for td in undone.prefix(8) {
                    let dot = NSView()
                    dot.wantsLayer = true
                    dot.layer?.backgroundColor = (td.priority <= 1 ? NSColor(hex: "FF453A")
                        : td.priority == 2 ? NSColor(hex: "FFD60A") : NSColor(hex: "0A84FF")).cgColor
                    dot.layer?.cornerRadius = 3
                    dot.translatesAutoresizingMaskIntoConstraints = false
                    dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
                    dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
                    let row = NSStackView(views: [dot, label(td.title, size: 12.5, color: .wdText)])
                    row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
                    todoList.addView(row, in: .leading)
                }
                if undone.count > 8 {
                    todoList.addView(label(String(format: t("… 另 %d 件"), undone.count - 8),
                                           size: 11, color: .wdText3), in: .leading)
                }
            } else {
                todoNum.stringValue = "—"; todoSub.stringValue = t("待办未连上")
            }
            // ③ 持仓:今日盈亏(A股口径:红涨绿跌)
            if let p = port {
                let d = p.dayPnl
                pnlNum.stringValue = (d >= 0 ? "+" : "") + fmtMoney(d)
                pnlNum.textColor = d >= 0 ? .wdUp : .wdDown
                pnlSub.stringValue = String(format: t("今日 · 持仓 %d 只"), p.holdings.count)
            } else {
                pnlNum.stringValue = "—"; pnlSub.stringValue = t("持仓未连上")
            }
            // 卡内容高度变了(待办行数),让主窗栅格重摆
            NotificationCenter.default.post(name: .init("wd.cardHeightChanged"), object: nil)
        }
    }
    Task { await reload() }
    let poll = PollEngine(label: "overview", inHours: { true }, interval: 60) { await reload() }
    poll.start()
    return c
}
