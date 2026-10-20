import AppKit

// MARK: - 缠论图弹窗(原生绘制:K线+笔+中枢+买卖点;替代 WKWebView/HTML,开窗即渲染)
// 数据:GET /api/chan/chartdata(code,level;后端60s缓存)→ JSON → CandleChartView 直绘。
// 交互:拖拽平移 / 滚轮·双指捏合缩放 / 十字线OHLC / 双击复位。

public struct ChanChartPayload: Decodable {
    public struct Bar: Decodable {
        public let date: String
        public let open: Double, close: Double, high: Double, low: Double, volume: Double
    }
    public struct Bi: Decodable {
        public let d1: String, p1: Double, d2: String, p2: Double
        public let dir: String?
    }
    public struct Zs: Decodable {
        public let d1: String, d2: String, lo: Double, hi: Double
    }
    public struct Bsp: Decodable {
        public let d: String, p: Double, k: String
    }
    public let ok: Bool
    public let error: String?
    public let bars: [Bar]?
    public let bis: [Bi]?
    public let zss: [Zs]?
    public let bsps: [Bsp]?
}

private var chartWindowRefs: [NSWindow] = []   // 图表窗强引用(局部变量窗口在 ARC/关闭时序上不稳)
public var tradesWindowRef: NSWindow?

public func openChartWindow(code: String, name: String) {
    let full = chanFullCode(code)
    let bare = full.replacingOccurrences(of: "[^0-9]", with: "", options: .regularExpression)
    let isStock = bare.count == 6
    let levels = ["5m", "15m", "30m", "60m", "4h", "day"]   // 两侧一致(股票监控也支持 15m)
    let path = isStock ? "/api/chan/monitor-level" : "/api/chan/futures-level"
    Task {
        // 默认级别跟随对应监控级别(股票=monitor-level,期货=futures-level),与外面所选一致
        struct LevelResp: Decodable { let level: String }
        let defLv = (try? await API.get(path, as: LevelResp.self))?.level
        await MainActor.run {
            _openChart(full: full, name: name, levels: levels, defaultLevel: defLv, levelPath: path)
        }
    }
}

private func _openChart(full: String, name: String, levels: [String], defaultLevel: String? = nil,
                        levelPath: String = "") {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1080, height: 680),
                       styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
    win.isReleasedWhenClosed = false
    win.title = "\(name)  \(full)"
    win.appearance = NSAppearance(named: .darkAqua)
    win.backgroundColor = .wdWin

    let chart = CandleChartView()
    let side = ChartSidePanel()
    let lvBar = PillBar(items: levels.map { ($0, $0) })

    func load(_ lv: String) {
        chart.beginLoading()
        side.rebuild(nil)
        let enc = full.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? full
        Task {
            let p = try? await API.get("/api/chan/chartdata?code=\(enc)&level=\(lv)", as: ChanChartPayload.self)
            await MainActor.run {
                chart.apply(p ?? ChanChartPayload(ok: false, error: "网络失败", bars: nil, bis: nil, zss: nil, bsps: nil))
                side.rebuild(p)
            }
        }
    }
    lvBar.onSelect = { load($0) }
    var pick = (defaultLevel.flatMap { levels.contains($0) ? $0 : nil })   // 跟随监控级别
        ?? (levels.contains("30m") ? "30m" : (levels.first ?? "day"))      // 兜底:30m
    lvBar.select(pick, fire: false)

    let barRow = NSStackView(views: [
        label(t("级别"), size: 10.5, color: .wdText3), lvBar,
        NSView(),
        label("原生渲染 · czsc · 腾讯", size: 10, color: .wdText3),
    ])
    barRow.orientation = .horizontal
    barRow.alignment = .centerY
    barRow.spacing = 10
    barRow.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)

    // 主体纯约束装配(NSStackView 装大图会循环解算高度,图被压成一条):工具栏/分隔线/图/竖分隔/右栏
    let sep = NSBox()
    sep.boxType = .separator
    let divider = NSView()
    divider.wantsLayer = true
    divider.layer?.backgroundColor = NSColor.wdBorder.cgColor
    let container = NSView()
    for v in [barRow, sep, chart, divider, side] as [NSView] {
        v.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(v)
    }
    NSLayoutConstraint.activate([
        barRow.topAnchor.constraint(equalTo: container.topAnchor),
        barRow.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        barRow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        sep.topAnchor.constraint(equalTo: barRow.bottomAnchor),
        sep.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        sep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        chart.topAnchor.constraint(equalTo: sep.bottomAnchor),
        chart.leadingAnchor.constraint(equalTo: container.leadingAnchor),
        chart.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        divider.leadingAnchor.constraint(equalTo: chart.trailingAnchor),
        divider.topAnchor.constraint(equalTo: sep.bottomAnchor),
        divider.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        divider.widthAnchor.constraint(equalToConstant: 1),
        side.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
        side.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        side.topAnchor.constraint(equalTo: sep.bottomAnchor),
        side.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        side.widthAnchor.constraint(equalToConstant: 300),
    ])
    win.contentView = container
    win.center()
    win.makeKeyAndOrderFront(nil)
    load(lvBar.selected)
    // 跟随监控级别:外面切股票/期货级别后,已开着的图窗 3s 内自动跟到新级别(不必重开)。
    // 基准=开窗时的监控级别;只有它"变化"才跟,所以图窗内手动选的临时级别不会被无端覆盖。
    if !levelPath.isEmpty {
        var lastSrv = defaultLevel ?? ""
        let timer = Timer(timeInterval: 3.0, repeats: true) { tm in
            guard win.isVisible else { tm.invalidate(); return }
            Task {
                struct LevelResp: Decodable { let level: String }
                guard let srv = (try? await API.get(levelPath, as: LevelResp.self))?.level,
                      levels.contains(srv) else { return }
                await MainActor.run {
                    if lastSrv.isEmpty {
                        lastSrv = srv          // 开窗时没取到监控级别 → 首次对齐
                        if srv != lvBar.selected { lvBar.select(srv, fire: false); load(srv) }
                    } else if srv != lastSrv {
                        lastSrv = srv
                        if srv != lvBar.selected { lvBar.select(srv, fire: false); load(srv) }
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
    }
    chartWindowRefs.append(win)
    chartWindowRefs.removeAll { !$0.isVisible }   // 已关的窗清引用
}

// MARK: - 右侧记录面板(买卖点最近6 + 中枢最近1;原生)

final class ChartSidePanel: NSView {
    private let list = FlippedStack()

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 8
        let scroll = NSScrollView()
        scroll.documentView = list
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.scrollerStyle = .overlay
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
        list.widthAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.widthAnchor, constant: -4).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    func rebuild(_ p: ChanChartPayload?) {
        list.views.forEach { $0.removeFromSuperview() }
        list.addView(label(t("买卖点(最近6个)"), size: 11, bold: true, color: .wdText3), in: .leading)
        let bsps = (p?.bsps ?? []).suffix(6)
        if bsps.isEmpty {
            list.addView(label(t("暂无(背驰需足够笔数)"), size: 10.5, color: NSColor.wdText3), in: .leading)
        }
        let names = ["B1": "买·1", "B1P": "买·1p", "B2": "买·2", "B2S": "买·2s", "B3": "买·3",
                     "S1": "卖·1", "S1P": "卖·1p", "S2": "卖·2", "S2S": "卖·2s", "S3": "卖·3"]
        let arr = Array(bsps)
        for (i, b) in arr.enumerated() {
            let isBuy = b.k.hasPrefix("B")
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 6
            // 时间去年份(07-17 10:30)控宽;ChipView 无固有尺寸会被 StackView 拉宽→定宽
            let tm = b.d.count > 10 ? String(b.d.dropFirst(5)) : b.d
            row.addView(label(tm, size: 9.5, color: .wdText3, mono: true), in: .leading)
            let chip = ChipView(names[b.k] ?? b.k, tint: isBuy ? NSColor.wdUp : NSColor.wdDown)
            chip.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                chip.widthAnchor.constraint(equalToConstant: 56),
                chip.heightAnchor.constraint(equalToConstant: 17),
            ])
            row.addView(chip, in: .leading)
            row.addView(label("@\(fmt2(b.p))", size: 11, color: .wdText, mono: true), in: .leading)
            let sp = NSView()
            sp.setContentHuggingPriority(.init(1), for: .horizontal)
            row.addView(sp, in: .leading)
            row.addView(label(t("已确认"), size: 9.5, color: NSColor.wdText3), in: .leading)
            if i == arr.count - 1 {
                let nw = ChipView("NEW", tint: NSColor.wdAccent)
                nw.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    nw.widthAnchor.constraint(equalToConstant: 38),
                    nw.heightAnchor.constraint(equalToConstant: 17),
                ])
                row.addView(nw, in: .leading)
            }
            list.addView(row, in: .leading)
        }
        list.addView(label(""), in: .leading)
        list.addView(label(t("中枢(最近1个)"), size: 11, bold: true, color: .wdText3), in: .leading)
        if let z = p?.zss?.last {
            let col2 = NSStackView()
            col2.orientation = .vertical
            col2.alignment = .leading
            col2.spacing = 3
            col2.addView(label("\(z.d1) ~ \(z.d2)", size: 11, color: .wdText), in: .leading)
            col2.addView(label("区间 [\(fmt2(z.lo)), \(fmt2(z.hi))]", size: 11, color: .wdText2, mono: true), in: .leading)
            list.addView(col2, in: .leading)
        } else {
            list.addView(label(t("暂无"), size: 10.5, color: .wdText3), in: .leading)
        }
        list.fitTo(minHeight: 60)
    }

    private func fmt2(_ v: Double) -> String {
        let s = String(format: "%.2f", v)
        return s.hasSuffix(".00") ? String(s.dropLast(3)) : s
    }
}

// MARK: - K线主图(纯 AppKit 绘制)

final class CandleChartView: NSView {
    private var bars: [ChanChartPayload.Bar] = []
    private var bis: [ChanChartPayload.Bi] = []
    private var zss: [ChanChartPayload.Zs] = []
    private var bsps: [ChanChartPayload.Bsp] = []
    private var idx: [String: Int] = [:]
    private var statusText = t("加载中…")
    private var visStart = 0
    private var visCount = 0
    private var mouse: NSPoint?
    private var dragOrigin: (x: CGFloat, start: Int)?

    private let axisW: CGFloat = 62
    private let axisH: CGFloat = 22
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for ta in trackingAreas { removeTrackingArea(ta) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeInKeyWindow, .activeAlways],
                                       owner: self, userInfo: nil))
    }

    // MARK: 数据

    func beginLoading() {
        bars = []; bis = []; zss = []; bsps = []
        statusText = t("加载中…")
        needsDisplay = true
    }

    func apply(_ p: ChanChartPayload) {
        guard p.ok, let b = p.bars, !b.isEmpty else {
            bars = []
            statusText = p.error ?? t("暂无K线数据")
            needsDisplay = true
            return
        }
        bars = b
        bis = p.bis ?? []
        zss = p.zss ?? []
        bsps = p.bsps ?? []
        idx = Dictionary(uniqueKeysWithValues: bars.enumerated().map { ($1.date, $0) })
        visCount = min(bars.count, 140)
        visStart = max(0, bars.count - visCount)
        needsDisplay = true
    }

    // MARK: 几何

    private var plot: NSRect {
        NSRect(x: 0, y: 0, width: max(50, bounds.width - axisW), height: max(40, bounds.height - axisH))
    }
    private var barW: CGFloat { plot.width / CGFloat(max(12, visCount)) }

    private func priceRange() -> (lo: Double, hi: Double) {
        let s = clampStart()
        let e = min(bars.count, s + visCount)
        var lo = Double.greatestFiniteMagnitude, hi = -lo
        for b in bars[s..<e] { lo = min(lo, b.low); hi = max(hi, b.high) }
        let pad = (hi - lo) * 0.05 + 1e-9
        return (lo - pad, hi + pad)
    }
    private func clampStart() -> Int {
        guard !bars.isEmpty else { return 0 }
        visCount = max(12, min(visCount, bars.count))
        return max(0, min(visStart, bars.count - visCount))
    }
    private func yOf(_ p: Double, lo: Double, hi: Double) -> CGFloat {
        plot.height * CGFloat((hi - p) / (hi - lo))
    }
    private func xMid(_ i: Int, s: Int) -> CGFloat {
        plot.width * (CGFloat(i - s) + 0.5) / CGFloat(max(12, visCount))
    }

    // MARK: 绘制

    override func draw(_ dirty: NSRect) {
        NSColor.wdWin.setFill()
        bounds.fill()
        guard !bars.isEmpty, visCount > 0 else {
            let a = NSAttributedString(string: statusText, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.wdText3,
            ])
            a.draw(at: NSPoint(x: (bounds.width - a.size().width) / 2,
                               y: (bounds.height - a.size().height) / 2))
            return
        }
        let s = clampStart()
        let e = min(bars.count, s + visCount)
        let (lo, hi) = priceRange()
        let bw = barW

        // 网格 + 价格轴(6档)
        let axisAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.wdText3,
        ]
        for i in 0...5 {
            let pv = lo + (hi - lo) * Double(i) / 5
            let y = yOf(pv, lo: lo, hi: hi)
            NSColor.wdBorder.withAlphaComponent(0.55).setFill()
            NSRect(x: 0, y: y, width: plot.width, height: 0.5).fill()
            let txt = NSAttributedString(string: fmtPv(pv), attributes: axisAttrs)
            txt.draw(at: NSPoint(x: plot.width + 6, y: y - 6))
        }

        // 时间轴:日内按日界标注,日线等距标注
        let intraday = bars.first?.date.count ?? 10 > 10
        let tickAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .regular),
            .foregroundColor: NSColor.wdText3,
        ]
        var lastLabelX: CGFloat = -40
        for i in s..<e {
            let d = bars[i].date
            let isTick: Bool
            if intraday {
                isTick = i > s && d.prefix(10) != bars[i - 1].date.prefix(10)
            } else {
                let step = max(1, visCount / 8)
                isTick = (i - s) % step == 0
            }
            guard isTick else { continue }
            let x = xMid(i, s: s)
            guard x - lastLabelX > 34 else { continue }
            lastLabelX = x
            NSColor.wdBorder.withAlphaComponent(0.55).setFill()
            NSRect(x: x, y: 0, width: 0.5, height: plot.height).fill()
            let txt = d.prefix(10).suffix(5)
            let a = NSAttributedString(string: String(txt), attributes: tickAttrs)
            a.draw(at: NSPoint(x: x - a.size().width / 2, y: plot.height + 6))
        }

        // 中枢(黄框,先画在蜡烛下)
        for z in zss {
            guard let i1 = idx[z.d1], let i2 = idx[z.d2], i2 >= s, i1 <= e else { continue }
            let x1 = xMid(max(i1, s), s: s) - bw / 2
            let x2 = xMid(min(i2, e - 1), s: s) + bw / 2
            let yTop = yOf(z.hi, lo: lo, hi: hi)
            let yBot = yOf(z.lo, lo: lo, hi: hi)
            let rect = NSRect(x: x1, y: yTop, width: max(4, x2 - x1), height: max(2, yBot - yTop))
            NSColor(srgbRed: 0.902, green: 0.706, blue: 0.133, alpha: 0.07).setFill()
            rect.fill()
            let path = NSBezierPath(rect: rect)
            NSColor(srgbRed: 0.902, green: 0.706, blue: 0.133, alpha: 0.9).setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        // 蜡烛
        for i in s..<e {
            let b = bars[i]
            let x = xMid(i, s: s)
            let up = b.close >= b.open
            let c = up ? NSColor.wdUp : NSColor.wdDown
            c.setStroke()
            let wick = NSBezierPath()
            wick.move(to: NSPoint(x: x, y: yOf(b.high, lo: lo, hi: hi)))
            wick.line(to: NSPoint(x: x, y: yOf(b.low, lo: lo, hi: hi)))
            wick.lineWidth = 1
            wick.stroke()
            let yO = yOf(b.open, lo: lo, hi: hi)
            let yC = yOf(b.close, lo: lo, hi: hi)
            let body = NSRect(x: x - bw * 0.32, y: min(yO, yC),
                              width: max(1, bw * 0.64), height: max(1, abs(yC - yO)))
            c.setFill()
            body.fill()
        }

        // 笔(蓝虚线)
        let biPath = NSBezierPath()
        for bi in bis {
            guard let i1 = idx[bi.d1], let i2 = idx[bi.d2] else { continue }
            biPath.move(to: NSPoint(x: xMid(i1, s: s), y: yOf(bi.p1, lo: lo, hi: hi)))
            biPath.line(to: NSPoint(x: xMid(i2, s: s), y: yOf(bi.p2, lo: lo, hi: hi)))
        }
        biPath.lineWidth = 1.2
        NSColor.wdAccent.setStroke()
        biPath.setLineDash([3, 3], count: 2, phase: 0)
        biPath.stroke()

        // 买卖点(箭头+文字):B=红上箭头在低点下方,S=绿下箭头在高点上方
        let markFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)
        for m in bsps {
            guard let i = idx[m.d], i >= s, i < e else { continue }
            let x = xMid(i, s: s)
            let isBuy = m.k.hasPrefix("B")
            let c = isBuy ? NSColor.wdUp : NSColor.wdDown
            let ty = isBuy ? yOf(bars[i].low, lo: lo, hi: hi) + 3 : yOf(bars[i].high, lo: lo, hi: hi) - 3
            let tri = NSBezierPath()
            if isBuy {                  // 翻转坐标系:y+向下 → 买=尖朝上(远离K线),卖=尖朝下
                tri.move(to: NSPoint(x: x, y: ty - 9))
                tri.line(to: NSPoint(x: x - 4.5, y: ty))
                tri.line(to: NSPoint(x: x + 4.5, y: ty))
            } else {
                tri.move(to: NSPoint(x: x, y: ty + 9))
                tri.line(to: NSPoint(x: x - 4.5, y: ty))
                tri.line(to: NSPoint(x: x + 4.5, y: ty))
            }
            tri.close()
            c.setFill()
            tri.fill()
            let txt = m.k.dropFirst().lowercased()
            let a = NSAttributedString(string: String(txt), attributes: [.font: markFont, .foregroundColor: c])
            let ly = isBuy ? ty + 11 : ty - 11 - a.size().height
            a.draw(at: NSPoint(x: x - a.size().width / 2, y: ly))
        }

        // 现价虚线 + 右轴标签
        let last = bars[bars.count - 1]
        let ly = yOf(last.close, lo: lo, hi: hi)
        if ly >= 0 && ly <= plot.height {
            let lp = NSBezierPath()
            lp.move(to: NSPoint(x: 0, y: ly))
            lp.line(to: NSPoint(x: plot.width, y: ly))
            lp.setLineDash([2, 3], count: 2, phase: 0)
            lp.lineWidth = 0.8
            NSColor.wdText3.setStroke()
            lp.stroke()
            let up = last.close >= (bars.count > 1 ? bars[bars.count - 2].close : last.open)
            let tagTxt = fmtPv(last.close)
            let a = NSAttributedString(string: tagTxt, attributes: [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.white,
            ])
            let tagW = a.size().width + 10, tagH = 16
            let tagRect = NSRect(x: plot.width + 2, y: ly - CGFloat(tagH) / 2, width: tagW, height: CGFloat(tagH))
            (up ? NSColor.wdUp : NSColor.wdDown).setFill()
            NSBezierPath(roundedRect: tagRect, xRadius: 3, yRadius: 3).fill()
            a.draw(at: NSPoint(x: tagRect.minX + 5, y: ly - a.size().height / 2))
        }

        // 十字线 + OHLC 信息
        if let m = mouse, plot.contains(m) {
            NSColor.wdText3.withAlphaComponent(0.5).setStroke()
            let ch = NSBezierPath()
            ch.move(to: NSPoint(x: m.x, y: 0)); ch.line(to: NSPoint(x: m.x, y: plot.height))
            ch.move(to: NSPoint(x: 0, y: m.y)); ch.line(to: NSPoint(x: plot.width, y: m.y))
            ch.setLineDash([2, 3], count: 2, phase: 0)
            ch.lineWidth = 0.7
            ch.stroke()
            let i = s + Int(m.x / bw)
            if i >= s && i < e {
                let b = bars[i]
                let prev = i > 0 ? bars[i - 1].close : b.open
                let chg = (b.close / prev - 1) * 100
                let info = "\(b.date)   开 \(fmtPv(b.open))  高 \(fmtPv(b.high))  低 \(fmtPv(b.low))  收 \(fmtPv(b.close))  \(chg >= 0 ? "+" : "")\(String(format: "%.2f", chg))%"
                let a = NSAttributedString(string: info, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
                    .foregroundColor: chg >= 0 ? NSColor.wdUp : NSColor.wdDown,
                ])
                a.draw(at: NSPoint(x: 8, y: 6))
            }
            let pv = lo + (hi - lo) * Double(m.y / plot.height)
            let a2 = NSAttributedString(string: fmtPv(pv), attributes: axisAttrs)
            a2.draw(at: NSPoint(x: plot.width + 6, y: m.y - 6))
        }
    }

    private func fmtPv(_ v: Double) -> String {
        String(format: "%.2f", v)
    }

    // MARK: 交互(拖拽平移 / 滚轮·捏合缩放 / 十字线)

    override func mouseMoved(with event: NSEvent) {
        mouse = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }
    override func mouseExited(with event: NSEvent) {
        mouse = nil
        needsDisplay = true
    }
    override func mouseDown(with event: NSEvent) {
        dragOrigin = (convert(event.locationInWindow, from: nil).x, clampStart())
    }
    override func mouseDragged(with event: NSEvent) {
        guard let o = dragOrigin, !bars.isEmpty else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let delta = Int(((x - o.x) / barW).rounded())
        visStart = max(0, min(o.start - delta, bars.count - visCount))
        needsDisplay = true
    }
    override func mouseUp(with event: NSEvent) {
        dragOrigin = nil
        if event.clickCount == 2 {   // 双击复位到默认视图(最近140根)
            visCount = min(bars.count, 140)
            visStart = max(0, bars.count - visCount)
            needsDisplay = true
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard !bars.isEmpty else { return }
        let dy = abs(event.deltaY) >= abs(event.deltaX) ? event.deltaY : event.deltaX
        guard dy != 0 else { return }
        zoom(by: pow(1.12, dy), at: convert(event.locationInWindow, from: nil).x)
    }
    override func magnify(with event: NSEvent) {
        guard !bars.isEmpty, event.magnification != 0 else { return }
        zoom(by: 1 - event.magnification, at: bounds.width / 2)
    }
    private func zoom(by factor: Double, at anchorX: CGFloat) {
        let s0 = clampStart()
        let anchorBar = Double(s0) + Double(anchorX / plot.width) * Double(visCount)
        let nc = max(12, min(Int((Double(visCount) * factor).rounded()), bars.count))
        guard nc != visCount else { return }
        let newStart = Int((anchorBar - Double(anchorX / plot.width) * Double(nc)).rounded())
        visCount = nc
        visStart = max(0, min(newStart, bars.count - nc))
        needsDisplay = true
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { window?.makeFirstResponder(nil) }
    }
}
