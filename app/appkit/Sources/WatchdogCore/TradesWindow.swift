import AppKit

// MARK: - 买卖明细窗口(全部实盘交易,滚动表格)

public struct TradeRow: Codable {
    public let roundDate: String
    public let code: String
    public let name: String?
    public let shares: Double
    public let buy: Double
    public let sell: Double?
    public let sellDate: String?
    public let net: Double?
    public let pct: Double?
}

public func openTradesWindow() {
    Task {
        let rows = (try? await API.get("/api/portfolio/trades?limit=300", as: [TradeRow].self)) ?? []
        await MainActor.run {
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 620),
                               styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            win.title = t("看门狗") + " · " + (wdLang == "en" ? "Trades" : "买卖明细")
            win.appearance = NSAppearance(named: wdThemeID == "mist" ? .aqua : .darkAqua)
            win.backgroundColor = .wdWin

            func col(_ s: String, _ w: CGFloat, _ bold: Bool = false) -> NSTextField {
                let v = label(s, size: 10.5, bold: bold, color: .wdText3, mono: true)
                v.translatesAutoresizingMaskIntoConstraints = false
                v.widthAnchor.constraint(equalToConstant: w).isActive = true
                return v
            }
            let widths: [CGFloat] = [82, 96, 70, 64, 64, 76, 64, 86]
            let headTitles = wdLang == "en"
                ? ["ROUND", "NAME", "SHARES", "BUY", "SELL", "NET", "PCT", "SELL DATE"]
                : ["轮次", "名称", "股数", "买入", "卖出", "净额", "盈亏%", "卖出日"]
            let head = NSStackView()
            head.orientation = .horizontal; head.spacing = 10; head.alignment = .centerY
            for (t2, w) in zip(headTitles, widths) { head.addView(col(t2, w), in: .leading) }

            let list = FlippedStack()
            list.orientation = .vertical; list.alignment = .leading; list.spacing = 5
            for r in rows {
                let holding = r.sell == nil
                let net = r.net ?? 0
                let row = NSStackView()
                row.orientation = .horizontal; row.spacing = 10; row.alignment = .centerY
                row.addView(col(String(r.roundDate.prefix(10)), widths[0]), in: .leading)
                let nm = label(r.name ?? r.code, size: 11.5)
                nm.translatesAutoresizingMaskIntoConstraints = false
                nm.widthAnchor.constraint(equalToConstant: widths[1]).isActive = true
                row.addView(nm, in: .leading)
                row.addView(col(String(format: "%.0f", r.shares), widths[2]), in: .leading)
                row.addView(col(String(format: "%.2f", r.buy), widths[3]), in: .leading)
                let sellL = col(holding ? (wdLang == "en" ? "holding" : "持仓中")
                                        : String(format: "%.2f", r.sell ?? 0), widths[4])
                sellL.textColor = holding ? .wdWarn : .wdText2
                sellL.font = .systemFont(ofSize: 10.5)
                row.addView(sellL, in: .leading)
                let netL = col(holding ? "—" : String(format: "%+.0f", net), widths[5])
                netL.textColor = holding ? .wdText3 : pctColor(net)
                row.addView(netL, in: .leading)
                let pctL = col(holding ? "—" : String(format: "%+.1f%%", r.pct ?? 0), widths[6])
                pctL.textColor = holding ? .wdText3 : pctColor(r.pct ?? 0)
                row.addView(pctL, in: .leading)
                row.addView(col(String((r.sellDate ?? "").prefix(10)), widths[7]), in: .leading)
                list.addView(row, in: .leading)
            }
            list.fitTo(minHeight: 480)

            let doc = NSStackView(views: [head, NSBox().also { $0.boxType = .separator }, list])
            doc.orientation = .vertical; doc.alignment = .leading; doc.spacing = 10
            doc.edgeInsets = NSEdgeInsets(top: 14, left: 18, bottom: 16, right: 14)
            let scroll = NSScrollView()
            scroll.documentView = doc
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.scrollerStyle = .overlay
            doc.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor).isActive = true

            let summary = label("\(wdLang == "en" ? "Total" : "共") \(rows.count) \(wdLang == "en" ? "trades" : "笔")",
                                size: 11, color: .wdText3, mono: true)
            let wrap = NSStackView(views: [scroll, summary])
            wrap.orientation = .vertical; wrap.spacing = 0; wrap.alignment = .leading
            wrap.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 8, right: 0)
            win.contentView = wrap
            win.center()
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            tradesWindowRef = win
        }
    }
}

extension NSBox {
    func also(_ configure: (NSBox) -> Void) -> NSBox { configure(self); return self }
}
