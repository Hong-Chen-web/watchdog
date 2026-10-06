import AppKit

// MARK: - 持仓概览(宽卡:左资产+曲线 / 右四列表+footer)

func makePortfolioCard() -> CardView {
    let c = CardView(title: t("持仓概览"), icon: "chart-line-up", meta: "CHAN-BRIDGE", id: "portfolio")

    // 左列:总资产 + 日涨跌 + 资产曲线(约 36% 宽)
    let capL = label(wdLang == "en" ? "TOTAL" : "总资产", size: 10.5, color: .wdText3)
    let total = label("—", size: 27, bold: true, mono: true)
    let day = label(" ", size: 12, mono: true)
    let curve = CurveView()
    curve.translatesAutoresizingMaskIntoConstraints = false
    curve.heightAnchor.constraint(equalToConstant: 92).isActive = true
    let leftCol = NSStackView(views: [capL, total, day, curve])
    leftCol.orientation = .vertical; leftCol.alignment = .leading; leftCol.spacing = 7

    // 右列:四列持仓表 + footer(表头列宽与数据行一致:118/160/96/84)
    func headLabel(_ s: String, _ w: CGFloat) -> NSTextField {
        let v = label(s, size: 9.5, color: .wdText3)
        v.translatesAutoresizingMaskIntoConstraints = false
        v.widthAnchor.constraint(equalToConstant: w).isActive = true
        return v
    }
    let head = NSStackView(views: [
        headLabel(wdLang == "en" ? "HOLDING" : "持仓", 118),
        headLabel(wdLang == "en" ? "COST → LAST" : "成本 → 现价", 160),
        headLabel(wdLang == "en" ? "VALUE" : "市值", 96),
        headLabel(wdLang == "en" ? "P&L" : "盈亏", 84),
    ])
    head.orientation = .horizontal; head.spacing = 0; head.alignment = .centerY
    let table = NSStackView()
    table.orientation = .vertical; table.alignment = .leading; table.spacing = 6
    let footL = label("", size: 11, color: .wdText2, mono: true)
    let rightCol = NSStackView(views: [head, table, footL])
    rightCol.orientation = .vertical; rightCol.alignment = .leading; rightCol.spacing = 8

    let hWrap = NSStackView(views: [leftCol, rightCol])
    hWrap.orientation = .horizontal; hWrap.alignment = .top; hWrap.spacing = 24
    c.block(hWrap)
    // 左右比例:左 36%(约束到父容器,不在兄弟间加约束)
    leftCol.translatesAutoresizingMaskIntoConstraints = false
    leftCol.widthAnchor.constraint(equalTo: hWrap.widthAnchor, multiplier: 0.36).isActive = true

    Task {
        if let h = try? await API.get("/api/portfolio/history?days=30", as: [PortfolioHistoryPoint].self), h.count > 1 {
            await MainActor.run {
                curve.values = h.map(\.total)
                curve.dates = h.map(\.date)
            }
        }
    }
    // 四列固定宽度(名称 118 · 成本→现价 160 · 市值 96 · 盈亏 84)
    @Sendable func colRow(_ name: String, _ mid: String, _ mv: String, _ pnl: String, _ pnlPct: Double) -> NSStackView {
        let nm = label(name, size: 12)
        nm.translatesAutoresizingMaskIntoConstraints = false; nm.widthAnchor.constraint(equalToConstant: 118).isActive = true
        let md = label(mid, size: 11.5, color: .wdText2, mono: true)
        md.translatesAutoresizingMaskIntoConstraints = false; md.widthAnchor.constraint(equalToConstant: 160).isActive = true
        let mvv = label(mv, size: 11.5, color: .wdText2, mono: true)
        mvv.translatesAutoresizingMaskIntoConstraints = false; mvv.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let pl = label(pnl, size: 12, bold: true, color: pctColor(pnlPct), mono: true)
        pl.translatesAutoresizingMaskIntoConstraints = false; pl.widthAnchor.constraint(equalToConstant: 84).isActive = true
        let r = NSStackView(views: [nm, md, mvv, pl])
        r.orientation = .horizontal; r.alignment = .centerY; r.spacing = 0
        return r
    }
    @Sendable func reload() async {
        guard let p = try? await API.get("/api/portfolio", as: Portfolio.self) else { return }
        await MainActor.run {
            total.stringValue = "¥ " + fmtWan(p.total)
            let up = p.dayPnl >= 0
            day.stringValue = (up ? "▲" : "▼") + String(format: " %+.0f", p.dayPnl)
            day.textColor = up ? .wdUp : .wdDown
            table.views.forEach { $0.removeFromSuperview() }
            for h in p.holdings {
                let last = h.last ?? h.buyPrice
                let rowView = colRow(h.name,
                                     String(format: "%.2f → %.2f", h.buyPrice, last),
                                     String(format: "%.0f股·%@", h.shares, fmtWan(h.value)),
                                     String(format: "%+.1f%%", h.pnlPct),
                                     h.pnlPct)
                // 右键:校准实际股数(chan 轮缺省 100 股演示口径)
                let code = h.code, name = h.name
                let menu = NSMenu()
                let mi = NSMenuItem(title: (wdLang == "en" ? "Set actual shares: " : "设置实际股数:") + name, action: nil, keyEquivalent: "")
                mi.onAction {
                    if let txt = inputAlert(title: (wdLang == "en" ? "Actual shares of " : "实际股数:") + name,
                                            placeholder: wdLang == "en" ? "e.g. 2000 (0=clear)" : "如 2000(填 0 清除)"),
                       let n = Double(txt), n >= 0 {
                        Task {
                            _ = try? await API.request("PUT", "/api/portfolio/calib", ["shares": [code: n]])
                            await reload()
                        }
                    }
                }
                menu.addItem(mi)
                rowView.menu = menu
                table.addView(rowView, in: .leading)
            }
            let pct = p.total > 0 ? p.marketValue / p.total * 100 : 0
            let calMark = (p.calibrated ?? false) ? "  ✓" + (wdLang == "en" ? "calibrated" : "已校准") : ""
            footL.stringValue = String(format: "%@ ¥%.0f   %@ ¥%.0f   %@ %.0f%%%@",
                wdLang == "en" ? "Cash" : "可用", p.cash,
                wdLang == "en" ? "Value" : "市值", p.marketValue,
                wdLang == "en" ? "Expo" : "仓位", pct, calMark)
        }
    }
    // 明细 + 校准现金
    c.row([
        textButton(wdLang == "en" ? "Trades" : "买卖明细") { openTradesWindow() },
        textButton(wdLang == "en" ? "Calibrate cash" : "校准现金") {
        if let txt = inputAlert(title: t("可用资金"), placeholder: wdLang == "en" ? "e.g. 50000" : "如 50000"),
           let v = Double(txt) {
            Task {
                _ = try? await API.request("PUT", "/api/portfolio/calib", ["cash": v])
                await reload()
            }
        }
    },
    ])
    Task {
        while true {
            await reload()
            try? await Task.sleep(nanoseconds: 30_000_000_000)
        }
    }
    return c
}
