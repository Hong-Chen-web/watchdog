// [LEGACY] 旧原生仪表盘(App 壳已停用;保留供回退参考与渲染测试)。见 AGENTS.md §2 结构说明。

import AppKit

// MARK: - 旧原生仪表盘控件(仅 Legacy/ 下 UI 与渲染测试使用)

/// Phosphor 图标视图
public final class IconView: NSView {
    private let tf = NSTextField(labelWithString: "")
    public init(_ name: String, size: CGFloat = 15, color: NSColor = .wdIcon) {
        super.init(frame: NSRect(x: 0, y: 0, width: size + 4, height: size + 4))
        wantsLayer = true   // 嵌在 layer-backed 容器(如卡片头 iconBox)里必须自身也 layer-backed,否则文字不绘制
        registerPhosphor()
        // 该 ttf 的 PostScript 名是 "Phosphor"(无 -Regular 后缀);三级兜底防注册竞态
        tf.font = phosphorFont(size)
        tf.textColor = color
        tf.stringValue = Ph.glyph(name)
        tf.alignment = .center
        addSubview(tf)
        tf.translatesAutoresizingMaskIntoConstraints = false
        // 必须自带尺寸约束:否则 Auto Layout 会把 frame 压成 0x0(图标框空白的真因)
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size + 4),
            heightAnchor.constraint(equalToConstant: size + 4),
            tf.centerXAnchor.constraint(equalTo: centerXAnchor),
            tf.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }
    public required init?(coder: NSCoder) { fatalError() }
}

// MARK: - 自绘圆环(环+中心文字+caption)

public final class RingLabelView: NSView {
    public var pct: Double = 0 { didSet { needsDisplay = true } }
    public var valueText: String = "" { didSet { needsDisplay = true } }
    public var caption: String = "" { didSet { needsDisplay = true } }
    public var tint: NSColor = .wdDown
    public var lineWidth: CGFloat = 6
    public var ringSize: CGFloat = 84 { didSet { invalidateIntrinsicContentSize(); needsDisplay = true } }

    public override var intrinsicContentSize: NSSize { NSSize(width: ringSize, height: ringSize) }
    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let side = min(bounds.width, bounds.height) - lineWidth - 4
        guard side > 4 else { return }
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        let vSize: CGFloat = ringSize >= 90 ? 20 : (ringSize >= 74 ? 15 : 13)
        let cSize: CGFloat = ringSize >= 90 ? 11 : (ringSize >= 74 ? 9.5 : 8.5)
        ctx.setLineWidth(lineWidth)
        ctx.setLineCap(.round)
        ctx.setStrokeColor(NSColor.wdTrack.cgColor)
        ctx.strokeEllipse(in: CGRect(x: c.x - side/2, y: c.y - side/2, width: side, height: side))
        let p = CGFloat(min(max(pct, 0), 1))
        if p > 0.005 {
            ctx.setStrokeColor(tint.cgColor)
            ctx.addArc(center: c, radius: side/2, startAngle: .pi/2,
                       endAngle: .pi/2 - p * 2 * .pi, clockwise: true)
            ctx.strokePath()
        }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: vSize, weight: .bold), .foregroundColor: tint]
        let s = NSAttributedString(string: valueText, attributes: attrs)
        let sz = s.size()
        s.draw(at: CGPoint(x: bounds.midX - sz.width/2, y: bounds.midY - sz.height/2))
        if !caption.isEmpty {
            let c2 = NSAttributedString(string: caption, attributes: [
                .font: NSFont.systemFont(ofSize: cSize, weight: .medium), .foregroundColor: NSColor.wdText3])
            let s2 = c2.size()
            c2.draw(at: CGPoint(x: bounds.midX - s2.width/2, y: bounds.midY - sz.height/2 - s2.height - 1))
        }
    }
}

// MARK: - 深蓝夜空 + 极光晕背景(设计稿 body 多层径向渐变)

public final class GradientBackdrop: NSView {
    public override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true   // 显式 layer-backed:防止窗口层树重组时的 flattening 残影(切主题后底部出现旧帧水印)
    }
    public required init?(coder: NSCoder) { fatalError() }
    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = wdPalette
        let base = CGGradient(colorsSpace: nil, colors: [
            p.backdropTop.cgColor, p.backdropMid.cgColor, p.backdropBottom.cgColor,
        ] as CFArray, locations: nil)!
        ctx.drawLinearGradient(base, start: .zero, end: CGPoint(x: 0, y: bounds.height), options: [])
        func glow(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat, _ c: NSColor) {
            let g = CGGradient(colorsSpace: nil, colors: [c.cgColor, c.withAlphaComponent(0).cgColor] as CFArray, locations: nil)!
            ctx.drawRadialGradient(g,
                startCenter: CGPoint(x: cx, y: cy), startRadius: 0,
                endCenter: CGPoint(x: cx, y: cy), endRadius: r,
                options: [.drawsAfterEndLocation])
        }
        glow(bounds.width * 0.82, bounds.height * 1.12, bounds.width * 0.62, p.glow1)
        glow(bounds.width * -0.16, bounds.height * -0.10, bounds.width * 0.55, p.glow2)
        glow(bounds.width * 0.55, bounds.height * -0.20, bounds.width * 0.5, p.glow3)
    }
}

// MARK: - 曲线图(面积渐变填充)

public final class CurveView: NSView {
    public var values: [Double] = [] { didSet { needsDisplay = true } }
    /// 与 values 对应的日期标签(悬停气泡显示;空则只显示数值)
    public var dates: [String] = [] { didSet { needsDisplay = true } }
    public var tint: NSColor = .wdUp
    public var showEndDot = true
    private var hoverIdx: Int? { didSet { if oldValue != hoverIdx { needsDisplay = true } } }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = trackingAreas.first { removeTrackingArea(t) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
    }

    public override func mouseMoved(with event: NSEvent) {
        let pt = convert(event.locationInWindow, from: nil)
        guard values.count > 1, bounds.width > 6 else { return }
        let inset: CGFloat = 3
        let frac = (pt.x - inset) / max(1, bounds.width - inset * 2)
        let idx = Int(round(frac * CGFloat(values.count - 1)))
        hoverIdx = (0..<values.count).contains(idx) ? idx : nil
    }

    public override func mouseExited(with event: NSEvent) { hoverIdx = nil }

    private func drawHover(_ idx: Int) {
        guard let ctx = NSGraphicsContext.current?.cgContext, values.count > 1 else { return }
        let inset: CGFloat = 3
        let x = inset + CGFloat(idx) / CGFloat(values.count - 1) * (bounds.width - inset * 2)
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let span = (hi - lo) == 0 ? 1 : hi - lo
        let y = inset + CGFloat((values[idx] - lo) / span) * (bounds.height - inset * 2)
        // 十字参考线 + 锚点
        ctx.setStrokeColor(NSColor.wdText3.withAlphaComponent(0.5).cgColor)
        ctx.setLineWidth(0.8)
        ctx.setLineDash(phase: 0, lengths: [2, 3])
        ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: bounds.height)); ctx.strokePath()
        ctx.setLineDash(phase: 0, lengths: [])
        let v = values[idx]
        let dateTxt = idx < dates.count ? String(dates[idx].prefix(10)) : ""
        let valTxt = "¥" + fmtWan(v)
        let txt = dateTxt.isEmpty ? valTxt : dateTxt + "  " + valTxt
        let attr = NSAttributedString(string: txt, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: NSColor.wdText])
        let sz = attr.size()
        // 气泡(锚点上方,左右不出界)
        var bx = x - sz.width / 2 - 6
        bx = max(2, min(bx, bounds.width - sz.width - 14))
        let by = min(y + 8, bounds.height - sz.height - 8)
        let box = NSRect(x: bx, y: by, width: sz.width + 12, height: sz.height + 6)
        let path = NSBezierPath(roundedRect: box, xRadius: 5, yRadius: 5)
        NSColor.wdCard.withAlphaComponent(0.97).setFill()
        path.fill()
        NSColor.wdBorder.setStroke()
        path.lineWidth = 1
        path.stroke()
        attr.draw(at: NSPoint(x: bx + 6, y: by + 3))
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: x - 3, y: y - 3, width: 6, height: 6)).fill()
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard values.count > 1, let ctx = NSGraphicsContext.current?.cgContext else { return }
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let span = (hi - lo) == 0 ? 1 : hi - lo
        let inset: CGFloat = 3
        func pt(_ i: Int) -> CGPoint {
            CGPoint(x: inset + CGFloat(i) / CGFloat(values.count - 1) * (bounds.width - inset * 2),
                    y: inset + CGFloat((values[i] - lo) / span) * (bounds.height - inset * 2))
        }
        let path = NSBezierPath()
        path.move(to: pt(0))
        for i in 1..<values.count { path.line(to: pt(i)) }
        let area = path.copy() as! NSBezierPath
        area.line(to: CGPoint(x: bounds.width - inset, y: 0))
        area.line(to: CGPoint(x: inset, y: 0))
        area.close()
        (NSColor(cgColor: tint.cgColor.copy(alpha: 0.18)!) ?? tint.withAlphaComponent(0.18)).setFill()
        area.fill()
        path.lineWidth = 1.8
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        tint.setStroke()
        path.stroke()
        if showEndDot {
            let last = pt(values.count - 1)
            (NSColor(cgColor: tint.cgColor.copy(alpha: 0.25)!) ?? tint.withAlphaComponent(0.25)).setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 5, y: last.y - 5, width: 10, height: 10)).fill()
            tint.setFill()
            NSBezierPath(ovalIn: NSRect(x: last.x - 2.5, y: last.y - 2.5, width: 5, height: 5)).fill()
        }
        if let i = hoverIdx { drawHover(i) }
        _ = ctx
    }
}

public extension NSImage {
    func resized(_ px: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: px, height: px))
        img.lockFocus()
        draw(in: NSRect(origin: .zero, size: img.size),
             from: .zero, operation: .sourceOver, fraction: 1)
        unlockFocus()
        return img
    }
}

// MARK: - 交易时段轮询引擎(按钮控制;交易日+时段内快轮,休市自动慢轮)

public final class PollEngine {
    public let button = NSButton()
    private var paused = false
    private let inHours: () -> Bool
    private let activeInterval: TimeInterval
    private let tick: () async -> Void
    private var started = false

    /// - inHours: 交易时段判定(股票/期货各自)
    /// - interval: 时段内的轮询间隔
    public init(label: String, inHours: @escaping () -> Bool,
                interval: TimeInterval, tick: @escaping () async -> Void) {
        self.inHours = inHours
        self.activeInterval = interval
        self.tick = tick
        button.bezelStyle = .recessed
        button.controlSize = .small
        button.font = .systemFont(ofSize: 11.5)
        button.onAction { [weak self] in self?.toggle() }
        refreshTitle(open: inHours())
    }

    public func start() {
        guard !started else { return }
        started = true
        Task { await loop() }
    }

    private func toggle() {
        paused.toggle()
        refreshTitle(open: isActive)
    }

    private var isActive: Bool { !paused && inHours() }

    private func refreshTitle(open: Bool) {
        button.title = paused
            ? (wdLang == "en" ? "▶ Resume" : "▶ 续轮")
            : (open ? (wdLang == "en" ? "⏸ Pause" : "⏸ 暂停")
                    : (wdLang == "en" ? "⏸ Closed" : "⏸ 休市"))
    }

    private func loop() async {
        while true {
            let open = inHours()
            refreshTitle(open: open)
            if !paused && open {
                await tick()
                try? await Task.sleep(nanoseconds: UInt64(activeInterval * 1_000_000_000))
            } else {
                // 休市/暂停:60s 探测一次时段变化(暂停时也维持按钮状态刷新)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
    }
}

// MARK: - 透明点击捕获层(整行可点)

public final class ClickView: NSView {
    public var onClick: (() -> Void)?
    public override func mouseDown(with event: NSEvent) { onClick?() }
    public override var mouseDownCanMoveWindow: Bool { false }
}

// MARK: - 自绘渐变进度条

public final class BarView: NSView {
    public var ratio: Double = 0 { didSet { needsDisplay = true } }
    public var tint: NSColor = .wdDown
    public override var intrinsicContentSize: NSSize { NSSize(width: 110, height: 6) }
    public override func draw(_ dirtyRect: NSRect) {
        let r = bounds
        let track = NSBezierPath(roundedRect: r, xRadius: r.height/2, yRadius: r.height/2)
        NSColor.wdTrack.setFill()
        track.fill()
        let w = CGFloat(min(max(ratio, 0), 1)) * r.width
        if w > 1 {
            let fill = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: r.height),
                                    xRadius: r.height/2, yRadius: r.height/2)
            (NSColor(cgColor: tint.cgColor.copy(alpha: 0.9)!) ?? tint).setFill()
            fill.fill()
        }
    }
}

// MARK: - 按钮内进度条(一键清理:进度色衬底 + 标题叠加)

public final class ProgressButton: NSButton {
    public var progress: Double = 0 { didSet { needsDisplay = true } }
    public var progressTint: NSColor = .wdUp
    public init(title: String) {
        super.init(frame: NSRect(x: 0, y: 0, width: 140, height: 24))
        self.title = title
        isBordered = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.wdOverlayStrong.cgColor
        layer?.cornerRadius = 6
        font = .systemFont(ofSize: 11.5)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    public required init?(coder: NSCoder) { fatalError() }
    public override func draw(_ dirtyRect: NSRect) {
        if progress > 0.001 {
            let w = bounds.width * CGFloat(min(max(progress, 0), 1))
            let path = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: bounds.height),
                                    xRadius: 6, yRadius: 6)
            progressTint.withAlphaComponent(0.30).setFill()
            path.fill()
        }
        super.draw(dirtyRect)   // isBordered=false → 只画标题,叠在进度衬底上
    }
}

// MARK: - 行情行(名称左 · 价格/涨跌右,点击回调)

public final class QuoteRowView: NSView {
    private let nameL = NSTextField(labelWithString: "")
    private let codeL = NSTextField(labelWithString: "")
    private let priceL = NSTextField(labelWithString: "")
    private let chgL = NSTextField(labelWithString: "")
    public var onClick: (() -> Void)?

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 300, height: 20))
        for (v, w) in [(nameL, 88.0), (priceL, 72.0), (chgL, 64.0)] {
            v.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
            addSubview(v)
            v.translatesAutoresizingMaskIntoConstraints = false
        }
        nameL.font = .systemFont(ofSize: 11.5)
        nameL.widthAnchor.constraint(equalToConstant: 88).isActive = true
        nameL.lineBreakMode = .byTruncatingTail
        nameL.cell?.wraps = false
        codeL.font = .monospacedDigitSystemFont(ofSize: 9.5, weight: .regular)
        codeL.textColor = .tertiaryLabelColor
        addSubview(codeL)
        codeL.translatesAutoresizingMaskIntoConstraints = false
        chgL.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
        NSLayoutConstraint.activate([
            nameL.leadingAnchor.constraint(equalTo: leadingAnchor),
            nameL.centerYAnchor.constraint(equalTo: centerYAnchor),
            codeL.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 92),
            codeL.centerYAnchor.constraint(equalTo: centerYAnchor),
            priceL.trailingAnchor.constraint(equalTo: chgL.leadingAnchor, constant: -10),
            priceL.centerYAnchor.constraint(equalTo: centerYAnchor),
            chgL.trailingAnchor.constraint(equalTo: trailingAnchor),
            chgL.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 20),
        ])
    }
    public required init?(coder: NSCoder) { fatalError() }

    public private(set) var code = ""

    public func set(name: String, price: String, chg: String, up: Bool,
                    code: String = "", click: @escaping () -> Void) {
        self.code = code
        nameL.stringValue = name
        codeL.stringValue = code
        codeL.isHidden = code.isEmpty
        priceL.stringValue = price
        chgL.stringValue = chg
        chgL.textColor = up ? .wdUp : .wdDown
        onClick = click
        axName = name
    }
    private var axName = ""
    public override func mouseDown(with event: NSEvent) { onClick?() }
    public override func isAccessibilityElement() -> Bool { true }
    public override func accessibilityRole() -> NSAccessibility.Role? { .button }
    public override func accessibilityLabel() -> String? { "chart-\(axName)" }
    public override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }

    /// 行尾删除按钮(返回自身供布局;点击回调由调用方接 DELETE)
    public func setRemove(_ onRemove: @escaping () -> Void) {
        let btn = textButton("✕", size: 10) { onRemove() }
        addSubview(btn)
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
            btn.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        chgL.trailingAnchor.constraint(equalTo: btn.leadingAnchor, constant: -8).isActive = true
    }
}
