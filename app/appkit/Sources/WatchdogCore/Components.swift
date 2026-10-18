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
        "sliders-horizontal": "\u{e434}", "dog": "\u{e74a}",
        // 注:pulse/puzzle-piece/clock/globe 四个码点在本字体版本缺字形(全表扫描确认,显示为?),已删;新图标先过 glyph 检测再入表
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
    // 注册后必须验证可解析;fontd 瞬时失败不锁死,允许下次字体解析时重试
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

// MARK: - 胶囊分段栏(设计稿同款:选中白底黑字)

public final class PillBar: NSView {
    public var onSelect: ((String) -> Void)?
    private var buttons: [(String, NSButton)] = []
    private var widthCons: [NSLayoutConstraint] = []
    private let fontSize: CGFloat
    public private(set) var selected: String = ""

    public init(items: [(String, String)], fontSize: CGFloat = 12) {  // (id, label)
        self.fontSize = fontSize
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.wdPillBg.cgColor
        layer?.cornerRadius = fontSize + 2
        layer?.borderColor = NSColor.wdPillBorder.cgColor
        layer?.borderWidth = 1
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 3, bottom: 3, right: 3)
        for (id, text) in items {
            let b = NSButton(title: text, target: nil, action: nil)
            b.font = .systemFont(ofSize: fontSize, weight: .medium)
            b.bezelStyle = .regularSquare
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.cornerRadius = fontSize - 1
            b.layer?.backgroundColor = NSColor.clear.cgColor
            b.attributedTitle = NSAttributedString(string: text, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: .medium),
                .foregroundColor: NSColor.wdText2])
            b.contentTintColor = .wdText2
            b.translatesAutoresizingMaskIntoConstraints = false
            // 按文字实测宽定宽(regularSquare 残留固有宽会虚胖)
            let wc = b.widthAnchor.constraint(equalToConstant: textWidth(text) + 10)
            wc.isActive = true
            widthCons.append(wc)
            b.heightAnchor.constraint(equalToConstant: fontSize + 13).isActive = true
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

    /// 文字实测宽(建栏/换语言都用同一把尺)
    private func textWidth(_ s: String) -> CGFloat {
        NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .medium)]).size().width
    }

    /// 语言切换:换文字 + 重算按钮宽 + 重新套用选中态
    /// (旧实现只改 attributedTitle,会把选中 tab 的文字也刷成普通灰 = 深底深字看不见;宽度也不随文案变)
    public func setLabels(_ labels: [String]) {
        for (i, item) in buttons.enumerated() where i < labels.count {
            item.1.title = labels[i]
            if i < widthCons.count { widthCons[i].constant = textWidth(labels[i]) + 10 }
        }
        select(selected, fire: false)
    }

    /// 主题切换:胶囊底色/描边 + 选中态重新上色(cgColor 在建栏时已定死,不重取就是旧主题)
    public func refreshTheme() {
        layer?.backgroundColor = NSColor.wdPillBg.cgColor
        layer?.borderColor = NSColor.wdPillBorder.cgColor
        select(selected, fire: false)
    }

    public func select(_ id: String, fire: Bool) {
        selected = id
        for (bid, b) in buttons {
            let on = bid == id
            b.layer?.backgroundColor = on ? NSColor.wdPillSelectedBg.cgColor : NSColor.clear.cgColor
            b.layer?.borderWidth = on ? 1 : 0
            b.layer?.borderColor = on ? NSColor.wdPillBorder.cgColor : NSColor.clear.cgColor
            let col = on ? NSColor.wdPillSelectedText : NSColor.wdText2
            b.attributedTitle = NSAttributedString(string: b.title, attributes: [
                .font: NSFont.systemFont(ofSize: fontSize, weight: on ? .semibold : .medium),
                .foregroundColor: col])
            b.contentTintColor = col
        }
        if fire { onSelect?(id) }
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

// MARK: - NSBox 链式配置(自 TradesWindow 迁移:活窗口 Settings/Chart 也在用)

extension NSBox {
    func also(_ configure: (NSBox) -> Void) -> NSBox { configure(self); return self }
}
