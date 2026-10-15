import AppKit

// MARK: - 设置窗口(侧栏+右侧圆角卡片组;参考 Synology Drive 偏好设置范式)
// 侧栏:偏好设置 / 大模型 / 飞书机器人;右侧=页标题+✕ + 分节小标题+圆角卡片组。
// 保留:⌘V 兜底粘贴 / LLM 存取测试 / 机器人 CRUD / 主题语言切换。

public var settingsWindowRef: NSWindow?

private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}

public final class SettingsPane: NSView, NSTextFieldDelegate {
    static let presets: [(name: String, base: String, model: String)] = [
        ("DeepSeek", "https://api.deepseek.com", "deepseek-chat"),
        ("智谱 GLM", "https://open.bigmodel.cn/api/paas/v4", "glm-5.3"),
        ("Kimi · 月之暗面", "https://api.moonshot.cn/v1", "kimi-latest"),
        ("通义千问 Qwen", "https://dashscope.aliyuncs.com/compatible-mode/v1", "qwen-turbo"),
        ("自定义", "", ""),
    ]

    let baseField = NSTextField(string: "")
    let keyField = NSSecureTextField(string: "")
    let modelField = NSTextField(string: "")
    let providerPop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 210, height: 28), pullsDown: false)
    let statusL = NSTextField(labelWithString: "")
    let resultL = NSTextField(labelWithString: "")
    let saveBtn = NSButton(title: "保存", target: nil, action: nil)
    private var busy = false

    // 页骨架
    private let paneW: CGFloat = 780, sidebarW: CGFloat = 184, cardW: CGFloat = 512
    private var pageHost: NSView!
    private var pageTitleL = NSTextField(labelWithString: "")
    private var navButtons: [(String, NSButton)] = []
    private var currentNav = ""

    private let sidebarView = NSView()

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: paneW, height: 560))
        wantsLayer = true
        layer?.backgroundColor = NSColor.wdWin.cgColor
        // 主题切换:设置窗外观+整页重建(颜色在建页时定死,不重建就是旧主题)
        NotificationCenter.default.addObserver(forName: .init("wd.themeChanged"),
                                               object: nil, queue: .main) { [weak self] _ in
            self?.applyTheme()
        }
        for f in [baseField, keyField, modelField] {
            f.isEditable = true; f.isSelectable = true
            f.isBezeled = true; f.bezelStyle = .roundedBezel; f.drawsBackground = true
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        }
        baseField.placeholderString = "https://api.deepseek.com"
        keyField.placeholderString = "sk-..."
        modelField.placeholderString = "deepseek-chat"
        baseField.delegate = self; keyField.delegate = self; modelField.delegate = self
        for p in Self.presets { providerPop.addItem(withTitle: p.name) }
        providerPop.onAction { [weak self] in self?.applyPreset() }
        statusL.font = .systemFont(ofSize: 10.5); statusL.textColor = .wdText3
        resultL.font = .systemFont(ofSize: 10.5); resultL.textColor = .wdText3
        resultL.lineBreakMode = .byTruncatingTail
        saveBtn.bezelStyle = .rounded; saveBtn.controlSize = .regular
        saveBtn.font = .systemFont(ofSize: 12, weight: .semibold)
        saveBtn.keyEquivalent = "\r"
        saveBtn.onAction { [weak self] in self?.save() }

        // ---- 侧栏 ----
        let sb = sidebarView
        sb.frame = NSRect(x: 0, y: 0, width: sidebarW, height: 560)
        sb.wantsLayer = true
        sb.layer?.backgroundColor = NSColor.wdSide.cgColor
        let cap = label(t("设置"), size: 11, color: .wdText3)
        cap.frame = NSRect(x: 16, y: flippedY(sb, top: 18, h: 16), width: 100, height: 16)
        sb.addSubview(cap)
        let navs: [(String, String, String)] = [
            ("general", "sliders-horizontal", "偏好设置"),
            ("llm", "cpu", "大模型"),
        ]
        var ny: CGFloat = 46
        for (id, ic, title) in navs {
            let btn = NSButton(title: "", target: nil, action: nil)
            btn.isBordered = false
            btn.frame = NSRect(x: 10, y: flippedY(sb, top: ny, h: 36), width: sidebarW - 20, height: 36)
            btn.layer?.cornerRadius = 8
            btn.wantsLayer = true
            let glyph = label(Ph.glyph(ic), size: 14, color: .wdText2)
            glyph.font = phosphorFont(14) ?? .systemFont(ofSize: 14)
            let txt = label(title, size: 13, color: .wdText2)
            glyph.frame = NSRect(x: 14, y: 10, width: 20, height: 16)
            txt.frame = NSRect(x: 40, y: 10, width: sidebarW - 60, height: 16)
            btn.addSubview(glyph); btn.addSubview(txt)
            btn.onAction { [weak self] in self?.select(id) }
            sb.addSubview(btn)
            navButtons.append((id, btn))
            ny += 42
        }
        addSubview(sb)

        // ---- 右侧:页标题 + ✕ + 页面宿主 ----
        pageTitleL = label(t("偏好设置"), size: 16, bold: true, color: .wdText)
        pageTitleL.frame = NSRect(x: sidebarW + 28, y: flippedY(self, top: 22, h: 22), width: 300, height: 22)
        addSubview(pageTitleL)
        let close = textButton("✕", size: 13) { settingsWindowRef?.performClose(nil) }
        let csz = close.fittingSize
        close.frame = NSRect(x: paneW - 24 - csz.width, y: flippedY(self, top: 20, h: csz.height),
                             width: csz.width + 2, height: csz.height)
        addSubview(close)

        pageHost = NSView(frame: NSRect(x: sidebarW, y: 0, width: paneW - sidebarW, height: 560))
        addSubview(pageHost)

        select("general")
    }
    public required init?(coder: NSCoder) { fatalError() }

    func applyTheme() {
        settingsWindowRef?.appearance = NSAppearance(named: wdThemeID == "mist" ? .aqua : .darkAqua)
        settingsWindowRef?.backgroundColor = .wdWin
        layer?.backgroundColor = NSColor.wdWin.cgColor
        sidebarView.wantsLayer = true
        sidebarView.layer?.backgroundColor = NSColor.wdSide.cgColor
        select(currentNav)   // 整页重建,所有 label/控件吃新调色板
    }

    /// 视图未翻转,把"距顶 y"换算成 AppKit y
    private func flippedY(_ v: NSView, top: CGFloat, h: CGFloat) -> CGFloat {
        v.bounds.height - top - h
    }

    // MARK: 导航

    func select(_ id: String) {
        currentNav = id
        for (bid, btn) in navButtons {
            let on = bid == id
            btn.layer?.backgroundColor = on ? NSColor.wdAccent.cgColor : NSColor.clear.cgColor
            for v in btn.subviews {
                if let lb = v as? NSTextField {
                    lb.textColor = on ? NSColor.white : NSColor.wdText2
                }
            }
        }
        pageHost.subviews.forEach { $0.removeFromSuperview() }
        let root = FlippedContainer(frame: NSRect(x: 0, y: 0, width: paneW - sidebarW, height: 560))
        pageHost.addSubview(root)
        switch id {
        case "llm": buildLLMPage(root)
        default: buildGeneralPage(root)
        }
    }

    // MARK: 卡片装配(flipped 容器内,y 从顶往下走光标)

    private var cursor: CGFloat = 24

    private func caption(_ text: String, _ root: NSView) {
        let l = label(text, size: 11, color: .wdText3)
        let sz = l.fittingSize
        l.frame = NSRect(x: 30, y: cursor, width: sz.width + 2, height: sz.height)
        root.addSubview(l)
        cursor += sz.height + 8
    }

    /// 圆角卡片:rows = (视图, 行高);行内视图自己负责 frame(相对卡片)
    private func card(_ rows: [(NSView, CGFloat)], _ root: NSView) {
        let total = rows.reduce(0) { $0 + $1.1 } + (rows.count > 1 ? CGFloat(rows.count - 1) : 0)
        let card = NSView(frame: NSRect(x: 30, y: cursor, width: cardW, height: total))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.wdCard.cgColor
        card.layer?.cornerRadius = 10
        card.layer?.borderWidth = 0.5
        card.layer?.borderColor = NSColor.wdBorder.cgColor
        var y: CGFloat = 0
        for (i, r) in rows.enumerated() {
            r.0.frame = NSRect(x: 0, y: y, width: cardW, height: r.1)
            card.addSubview(r.0)
            y += r.1
            if i < rows.count - 1 {
                let line = NSBox()
                line.boxType = .separator
                line.frame = NSRect(x: 16, y: y, width: cardW - 32, height: 1)
                card.addSubview(line)
                y += 1
            }
        }
        root.addSubview(card)
        cursor += total + 22
    }

    /// 行视图:标题(+副标题)左 / 控件右
    private func row(title: String, sub: String? = nil, control: NSView, cw: CGFloat? = nil) -> (NSView, CGFloat) {
        let h: CGFloat = sub == nil ? 52 : 64
        let row = NSView(frame: NSRect(x: 0, y: 0, width: cardW, height: h))
        let tl = label(title, size: 13, bold: true, color: .wdText)
        let tls = tl.fittingSize
        tl.frame = NSRect(x: 16, y: h / 2 - tls.height / 2 - (sub == nil ? 0 : 7), width: tls.width + 2, height: tls.height)
        row.addSubview(tl)
        if let sub {
            let sl = label(sub, size: 10.5, color: .wdText3)
            let sls = sl.fittingSize
            sl.frame = NSRect(x: 16, y: tl.frame.maxY + 4, width: min(sls.width + 2, cardW - 160), height: sls.height)
            row.addSubview(sl)
        }
        let csize = control.fittingSize
        let cwidth = cw ?? min(csize.width + 8, cardW - 150)
        control.frame = NSRect(x: cardW - 16 - cwidth, y: h / 2 - max(csize.height, 24) / 2,
                               width: cwidth, height: max(csize.height, 24))
        row.addSubview(control)
        return (row, h)
    }

    private func seg(_ titles: [String], select idx: Int, _ on: @escaping (Int) -> Void) -> NSSegmentedControl {
        let sc = NSSegmentedControl(labels: titles, trackingMode: .selectOne, target: nil, action: nil)
        sc.selectedSegment = idx
        sc.font = .systemFont(ofSize: 12)
        sc.onAction { on(sc.selectedSegment) }
        return sc
    }

    // MARK: 三页

    private func buildGeneralPage(_ root: NSView) {
        pageTitleL.stringValue = t("偏好设置")
        cursor = 24
        caption(t("外观"), root)
        card([row(title: t("主题"), sub: t("深色或浅色界面"),
                  control: seg([t("深色"), t("浅色")], select: wdThemeID == "sky" ? 0 : 1) { i in
                      wdThemeID = i == 0 ? "sky" : "mist"
                      NotificationCenter.default.post(name: .init("wd.themeChanged"), object: nil)
                  }, cw: 130)], root)
        caption(t("语言"), root)
        card([row(title: t("界面语言"), sub: t("默认中文"),
                  control: seg([t("中文"), "EN"], select: wdLang == "zh" ? 0 : 1) { i in
                      wdLang = i == 0 ? "zh" : "en"
                      NotificationCenter.default.post(name: .init("wd.langChanged"), object: nil)
                  }, cw: 150)], root)
    }

    private func buildLLMPage(_ root: NSView) {
        pageTitleL.stringValue = t("大模型")
        cursor = 24
        caption(t("服务商"), root)
        card([row(title: t("大模型服务商"), sub: t("选中即自动填接口地址与推荐模型"), control: providerPop, cw: 210)], root)
        caption(t("接口与凭据"), root)
        card([row(title: t("接口地址"), control: baseField, cw: 260),
              row(title: "API Key", control: keyField, cw: 260),
              row(title: t("模型"), control: modelField, cw: 260)], root)
        caption(t("测试与保存"), root)
        card([row(title: t("连接测试"), sub: t("测试通过后保存;清空保存 = 回落本地规则"),
                  control: hstack([testButton(), saveBtn]), cw: 190)], root)
        let rl = resultL
        rl.frame = NSRect(x: 30, y: cursor, width: cardW, height: 18)
        root.addSubview(rl)
    }

    private func testButton() -> NSButton {
        let b = textButton(t("测试连接"), size: 12) { [weak self] in self?.runTest() }
        b.bezelStyle = .rounded; b.controlSize = .regular
        b.font = .systemFont(ofSize: 12)
        return b
    }

    private func hstack(_ views: [NSView]) -> NSView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal; s.alignment = .centerY; s.spacing = 10
        return s
    }


    // 新增行(定制定制宽度)



    // MARK: 逻辑(自旧版平移)

    func bindPasteFeedback() {
        let p = settingsWindowRef as? WdSettingsWindow
        p?.pasteCheck = { [weak self] in
            (self?.baseField.stringValue.count ?? 0) + (self?.keyField.stringValue.count ?? 0)
                + (self?.modelField.stringValue.count ?? 0)
        }
        NotificationCenter.default.addObserver(forName: .init("wd.pasteFail"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pb = NSPasteboard.general
                let types = (pb.types ?? []).compactMap { $0.rawValue.split(separator: ".").last }.joined(separator: ",")
                let hasText = (pb.string(forType: .string)?.isEmpty == false)
                self.resultL.textColor = NSColor.systemRed
                self.resultL.stringValue = hasText
                    ? "✗ 粘贴被系统拦截(见状态行)"
                    : "✗ 剪贴板没有文本(内容类型: \(types) — 截图会覆盖已复制的key,请重新复制)"
            }
        }
        NotificationCenter.default.addObserver(forName: .init("wd.pasteOK"), object: nil, queue: .main) { _ in
        }
    }

    public func controlTextDidChange(_ obj: Notification) {
        let b = baseField.stringValue, k = keyField.stringValue, m = modelField.stringValue
        statusL.stringValue = wdLang == "en"
            ? "chars — base \(b.count) · key \(k.count) · model \(m.count)"
            : "字符数 — 接口 \(b.count) · Key \(k.count) · 模型 \(m.count)"
    }

    private func applyPreset() {
        guard let p = Self.presets.first(where: { $0.name == providerPop.titleOfSelectedItem }),
              !p.base.isEmpty else { return }
        baseField.stringValue = p.base
        modelField.stringValue = p.model
    }

    public func loadNow() {
        Task {
            let cfg = try? await API.get("/api/llm", as: LLMConfig.self)
            await MainActor.run {
                guard let cfg else { statusL.stringValue = "后端未就绪"; return }
                baseField.stringValue = cfg.base ?? ""
                keyField.stringValue = cfg.key ?? ""
                modelField.stringValue = cfg.model ?? ""
                let b = cfg.base ?? ""
                let idx = Self.presets.firstIndex { !$0.base.isEmpty && $0.base == b }
                    ?? Self.presets.count - 1
                providerPop.selectItem(at: idx)
                switch cfg.source {
                case "db": statusL.stringValue = "✓ " + (wdLang == "en" ? "Configured (saved in app) · " : "已配置(存于应用)· ") + (cfg.model ?? "")
                case "env": statusL.stringValue = "✓ " + (wdLang == "en" ? "Configured (env vars) · " : "已配置(环境变量)· ") + (cfg.model ?? "")
                default: statusL.stringValue = wdLang == "en" ? "Not configured" : "未配置 · 顶栏输入走本地规则"
                }
            }
        }
    }

    private func save() {
        guard !busy else { return }
        busy = true
        Task {
            let ok = (try? await API.request("PUT", "/api/llm", [
                "base": baseField.stringValue, "key": keyField.stringValue, "model": modelField.stringValue])) ?? false
            await MainActor.run {
                busy = false
                resultL.textColor = ok ? NSColor.systemGreen : NSColor.systemRed
                resultL.stringValue = ok ? "✓ " + (wdLang == "en" ? "Saved" : "已保存") : "✗ " + (wdLang == "en" ? "Save failed" : "保存失败")
                loadNow()
            }
        }
    }

    private func runTest() {
        guard !busy else { return }
        busy = true
        Task {
            await MainActor.run { resultL.textColor = .wdText3; resultL.stringValue = "…" }
            let r = try? await API.postJSON("/api/llm/test", body: [
                "base": baseField.stringValue, "key": keyField.stringValue, "model": modelField.stringValue],
                as: LLMTestResult.self)
            await MainActor.run {
                busy = false
                guard let r else {
                    resultL.textColor = NSColor.systemRed
                    resultL.stringValue = "✗ " + (wdLang == "en" ? "Request failed" : "请求失败(后端未就绪?)")
                    return
                }
                if r.ok {
                    resultL.textColor = NSColor.systemGreen
                    resultL.stringValue = "✓ \((r.model ?? "")) → \((r.reply ?? ""))"
                } else {
                    resultL.textColor = NSColor.systemRed
                    resultL.stringValue = "✗ \((r.error ?? "unknown"))"
                }
            }
        }
    }
}

final class WdSettingsWindow: NSWindow {
    var pasteCheck: (() -> Int)?
    var pasteBefore = 0
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "v" {
            pasteBefore = pasteCheck?() ?? -1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                let after = self.pasteCheck?() ?? -1
                if after > self.pasteBefore {
                    NotificationCenter.default.post(name: .init("wd.pasteOK"), object: nil)
                } else {
                    self.manualPaste()
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func manualPaste() {
        let raw = NSPasteboard.general.string(forType: .string)
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            NotificationCenter.default.post(name: .init("wd.pasteFail"), object: nil)
            return
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if let fe = self.firstResponder as? NSTextView {
                fe.insertText(text, replacementRange: fe.selectedRange())
            }
            let after = self.pasteCheck?() ?? -1
            NotificationCenter.default.post(
                name: .init(after > self.pasteBefore ? "wd.pasteOK" : "wd.pasteFail"), object: nil)
        }
    }
}

public func openSettingsWindow() {
    if let w = settingsWindowRef {
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
    }
    let pane = SettingsPane()
    let win = WdSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 560),
                               styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
    win.isReleasedWhenClosed = false
    win.title = t("看门狗") + " · " + t("设置")
    win.titlebarAppearsTransparent = true
    win.appearance = NSAppearance(named: wdThemeID == "mist" ? .aqua : .darkAqua)
    win.backgroundColor = .wdWin
    win.contentView = pane
    win.center()
    NSApp.activate(ignoringOtherApps: true)
    win.makeKeyAndOrderFront(nil)
    settingsWindowRef = win
    pane.bindPasteFeedback()
    pane.loadNow()
}
