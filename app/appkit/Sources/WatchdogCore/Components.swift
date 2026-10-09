import AppKit

// MARK: - 可复用自绘组件(全部单视图自绘,零叠加约束问题)

// MARK: - NullableTarget(全局保活:target 是 weak,内联创建即释放变死键)

public final class NullableTarget: NSObject {
    private static let lock = NSLock()
    private static var arena: [NullableTarget] = []
    private let fn: () -> Void
    public init(_ fn: @escaping () -> Void) {
        self.fn = fn
        super.init()
        Self.lock.lock(); Self.arena.append(self); Self.lock.unlock()
    }
    @objc public func fire() { fn() }
}

// MARK: target+action 必须成对——只设 target 的控件全是死键(胶囊/清理按钮/开关三次踩坑)

public extension NSControl {
    func onAction(_ fn: @escaping () -> Void) {
        target = NullableTarget(fn)
        action = #selector(NullableTarget.fire)
    }
}

public extension NSMenuItem {
    func onAction(_ fn: @escaping () -> Void) {
        target = NullableTarget(fn)
        action = #selector(NullableTarget.fire)
    }
}

// MARK: - Phosphor 图标

public enum Ph {
    public static let codes: [String: String] = [
        "chart-line-up": "\u{e156}", "flask": "\u{e79e}", "list-checks": "\u{eadc}",
        "wallet": "\u{e68a}", "chart-line": "\u{e154}", "stethoscope": "\u{e7ea}",
        "lightning": "\u{e2de}", "compass": "\u{e1c8}", "calendar-blank": "\u{e10a}",
        "broom": "\u{ec54}", "notebook": "\u{e34e}", "paper-plane-tilt": "\u{e398}",
        "chart-donut": "\u{eaa6}", "flag-banner": "\u{e622}", "cpu": "\u{e610}",
        "memory": "\u{e9c4}", "gauge": "\u{e628}", "hard-drive": "\u{e29e}",
        "wifi-high": "\u{e4ea}", "battery-high": "\u{e0c2}", "check": "\u{e182}",
        "x": "\u{e4f6}", "plus": "\u{e3d4}", "arrows-clockwise": "\u{e094}",
        "trash": "\u{e4a6}", "caret-down": "\u{e136}", "note-pencil": "\u{e34c}",
        "sliders-horizontal": "\u{e434}", "dog": "\u{e74a}", "pulse": "\u{e0f0}",
        "puzzle-piece": "\u{e475}", "clock": "\u{e252}", "globe": "\u{e77b}",
    ]
    public static func glyph(_ name: String) -> String { codes[name] ?? "" }
}

private var _phFontRegistered = false
func phosphorFontURL() -> URL {
    // 优先 bundle 资源(.app 打包后 #filePath 指向构建目录,源码树不在)
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("Phosphor.ttf")
    // Sources/WatchdogCore/Components.swift → 上三级 = appkit(Assets 在 appkit/Assets)
    let src = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // WatchdogCore
        .deletingLastPathComponent()  // Sources
        .appendingPathComponent("../Assets/Phosphor.ttf")
        .standardizedFileURL
    return (bundled != nil && FileManager.default.fileExists(atPath: bundled!.path)) ? bundled! : src
}
public func registerPhosphor() {
    guard !_phFontRegistered else { return }
    var err: Unmanaged<CFError>?
    let ok = CTFontManagerRegisterFontsForURL(phosphorFontURL() as CFURL, .process, &err)
    // 注册后必须验证可解析;fontd 瞬时失败不锁死,允许下次 IconView 重试
    if ok, NSFont(name: "Phosphor", size: 14) != nil {
        _phFontRegistered = true
    } else {
        let msg = "[watchdog] phosphor register failed ok=\(ok) \(err?.takeRetainedValue().localizedDescription ?? "-")\n"
        FileHandle.standardError.write(msg.data(using: .utf8)!)
    }
}

/// 字体解析三级兜底:NSFont(name:) → 重试注册 → CTFontDescriptor 直取(免疫注册竞态)
public func phosphorFont(_ size: CGFloat) -> NSFont {
    func diag(_ m: String) { FileHandle.standardError.write(("[phosphorFont] \(m)\n").data(using: .utf8)!) }
    if let f = NSFont(name: "Phosphor", size: size) { return f }
    diag("L1 miss")
    registerPhosphor()
    if let f = NSFont(name: "Phosphor", size: size) { diag("L2 hit"); return f }
    let url = phosphorFontURL()
    diag("L2 miss url=\(url.path) exists=\(FileManager.default.fileExists(atPath: url.path))")
    if let descs = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor] {
        diag("L3 descs=\(descs.count)")
        if let d = descs.first, let f = NSFont(descriptor: d, size: size) {
            diag("L3 hit")
            return f
        }
        diag("L3 descriptor font nil")
    } else { diag("L3 descs nil") }
    diag("fall to systemFont")
    return .systemFont(ofSize: size)
}

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

// MARK: - 胶囊分段栏(设计稿同款:选中白底黑字)

public final class PillBar: NSView {
    public var onSelect: ((String) -> Void)?
    private var buttons: [(String, NSButton)] = []
    public private(set) var selected: String = ""

    public init(items: [(String, String)]) {  // (id, label)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.wdPillBg.cgColor
        layer?.cornerRadius = 14
        layer?.borderColor = NSColor.wdPillBorder.cgColor
        layer?.borderWidth = 1
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        for (id, text) in items {
            let b = NSButton(title: text, target: nil, action: nil)
            b.font = .systemFont(ofSize: 12, weight: .medium)
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = 11
            b.layer?.backgroundColor = NSColor.clear.cgColor
            b.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.wdText2])
            b.contentTintColor = .wdText2
            b.translatesAutoresizingMaskIntoConstraints = false
            b.heightAnchor.constraint(equalToConstant: 25).isActive = true
            b.onAction { [weak self] in self?.select(id, fire: true) }
            stack.addView(b, in: .leading)
            buttons.append((id, b))
        }
        addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 0),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: 0),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: 0),
        ])
        if let first = items.first { select(first.0, fire: false) }
    }
    public required init?(coder: NSCoder) { fatalError() }

    public func select(_ id: String, fire: Bool) {
        selected = id
        for (bid, b) in buttons {
            let on = bid == id
            b.layer?.backgroundColor = on ? NSColor.wdPillSelectedBg.cgColor : NSColor.clear.cgColor
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: on ? .semibold : .medium),
                .foregroundColor: on ? NSColor.wdPillSelectedText : NSColor.wdText2])
        }
        if fire { onSelect?(id) }
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

// MARK: - 翻转竖排容器(做 scroll documentView:默认不翻转+零初始尺寸=视口空白)

public final class FlippedStack: NSStackView {
    public override var isFlipped: Bool { true }
    /// 铺到至少视口高(滚动容器裁剪计算依赖真实 frame)
    public func fitTo(minHeight: CGFloat, minWidth: CGFloat = 300) {
        layoutSubtreeIfNeeded()
        let sz = fittingSize
        frame = NSRect(x: 0, y: 0,
                       width: max(sz.width, minWidth),
                       height: max(sz.height, minHeight))
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

    public func set(name: String, price: String, chg: String, up: Bool,
                    code: String = "", click: @escaping () -> Void) {
        nameL.stringValue = name
        codeL.stringValue = code
        codeL.isHidden = code.isEmpty
        priceL.stringValue = price
        chgL.stringValue = chg
        chgL.textColor = up ? .wdUp : .wdDown
        onClick = click
    }
    public override func mouseDown(with event: NSEvent) { onClick?() }

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
