import AppKit

// MARK: - 设置窗口(大模型配置区:OpenAI 兼容接口,自然语言识别用)

public var settingsWindowRef: NSWindow?

public final class SettingsPane: NSView, NSTextFieldDelegate {
    /// 服务商预设:选中即自动填接口地址+推荐模型(OpenAI 兼容;自定义=不动输入框)
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
    let providerPop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 330, height: 24), pullsDown: false)
    let statusL = NSTextField(labelWithString: "")
    let resultL = NSTextField(labelWithString: "")
    let saveBtn = NSButton(title: "保存", target: nil, action: nil)
    // 飞书推送范围(一级下拉+二级勾选)
    let scopeLabel = NSTextField(labelWithString: "推送范围")
    let scopePop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 160, height: 24), pullsDown: false)
    let scopeHint = NSTextField(labelWithString: "")
    let scopeList = FlippedStack()
    private var scopeStocks: [[String: String]] = []
    private var scopeFutures: [[String: String]] = []
    private var scopeSel: Set<String> = []

    private var busy = false

    public init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 470, height: 470))
        for p in Self.presets { providerPop.addItem(withTitle: p.name) }
        providerPop.onAction { [weak self] in self?.applyPreset() }

        func field(_ ph: String) -> NSTextField {
            let f = NSTextField(string: "")
            f.placeholderString = ph
            f.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            return f
        }
        for f in [baseField, keyField, modelField] {
            f.isEditable = true
            f.isSelectable = true
            f.isBezeled = true
            f.bezelStyle = .roundedBezel
            f.drawsBackground = true
        }
        baseField.placeholderString = "https://api.deepseek.com"
        keyField.placeholderString = "sk-..."
        modelField.placeholderString = "deepseek-chat"
        baseField.delegate = self; keyField.delegate = self; modelField.delegate = self

        func row(_ zh: String, _ en: String, _ f: NSTextField) -> NSStackView {
            let l = label(wdLang == "en" ? en : zh, size: 11.5, color: .wdText2)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 66).isActive = true
            f.translatesAutoresizingMaskIntoConstraints = false
            let s = NSStackView(views: [l, f])
            s.orientation = .horizontal; s.alignment = .centerY; s.spacing = 10
            f.widthAnchor.constraint(equalToConstant: 330).isActive = true
            return s
        }

        let pLabel = label(wdLang == "en" ? "Provider" : "服务商", size: 11.5, color: .wdText2)
        pLabel.translatesAutoresizingMaskIntoConstraints = false
        pLabel.widthAnchor.constraint(equalToConstant: 66).isActive = true
        providerPop.translatesAutoresizingMaskIntoConstraints = false
        let prow = NSStackView(views: [pLabel, providerPop])
        prow.orientation = .horizontal; prow.alignment = .centerY; prow.spacing = 10

        statusL.font = .systemFont(ofSize: 10.5); statusL.textColor = .wdText3
        resultL.font = .systemFont(ofSize: 10.5); resultL.textColor = .wdText3
        resultL.lineBreakMode = .byTruncatingTail
        resultL.translatesAutoresizingMaskIntoConstraints = false
        resultL.widthAnchor.constraint(lessThanOrEqualToConstant: 300).isActive = true

        let hint = label(wdLang == "en"
            ? "Pick a provider to auto-fill the base URL; enter model & API key, test, then save. Save empty = fall back to local rules."
            : "选服务商自动填接口地址;再自己填模型与 API Key,测试通过后保存。清空保存 = 回落本地规则。",
            size: 10, color: .wdText3)
        hint.lineBreakMode = .byWordWrapping
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.widthAnchor.constraint(lessThanOrEqualToConstant: 420).isActive = true

        let testBtn = textButton(wdLang == "en" ? "Test" : "测试连接", size: 11) { [weak self] in
            self?.runTest()
        }
        saveBtn.bezelStyle = .rounded; saveBtn.controlSize = .regular
        saveBtn.font = .systemFont(ofSize: 12, weight: .semibold)
        saveBtn.keyEquivalent = "\r"
        let testBtn2 = testBtn
        testBtn2.bezelStyle = .rounded
        testBtn2.controlSize = .regular
        testBtn2.font = .systemFont(ofSize: 12)
        saveBtn.onAction { [weak self] in self?.save() }

        let btnRow = NSStackView(views: [saveBtn, testBtn, resultL])
        btnRow.orientation = .horizontal; btnRow.alignment = .centerY; btnRow.spacing = 10

        func section(_ zh: String, _ en2: String) -> NSStackView {
            let l = label(wdLang == "en" ? en2 : zh, size: 11, bold: true, color: .wdText3)
            let line = NSBox(); line.boxType = .separator
            let row = NSStackView(views: [l, line])
            row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
            line.translatesAutoresizingMaskIntoConstraints = false
            line.widthAnchor.constraint(greaterThanOrEqualToConstant: 120).isActive = true
            return row
        }

        let title = label(wdLang == "en" ? "Settings" : "设置",
                          size: 14, bold: true, color: .wdText)

        // ---- 飞书推送范围:一级下拉(全部/股票和ETF/期货)+二级勾选列表 ----
        scopePop.addItem(withTitle: wdLang == "en" ? "全部标的" : "全部标的")
        scopePop.addItem(withTitle: wdLang == "en" ? "股票和ETF" : "股票和ETF")
        scopePop.addItem(withTitle: wdLang == "en" ? "期货" : "期货")
        scopePop.onAction { [weak self] in self?.reloadScopeList() }
        scopeLabel.stringValue = wdLang == "en" ? "推送范围" : "推送范围"
        scopeLabel.translatesAutoresizingMaskIntoConstraints = false
        scopeLabel.widthAnchor.constraint(equalToConstant: 66).isActive = true
        scopePop.translatesAutoresizingMaskIntoConstraints = false
        scopePop.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let scopeRow = NSStackView(views: [scopeLabel, scopePop])
        scopeRow.orientation = .horizontal; scopeRow.alignment = .centerY; scopeRow.spacing = 10
        scopeList.orientation = .vertical; scopeList.alignment = .leading; scopeList.spacing = 5
        scopeList.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 6)
        let scopeScroll = NSScrollView()
        scopeScroll.documentView = scopeList
        scopeScroll.hasVerticalScroller = true
        scopeScroll.scrollerStyle = .overlay
        scopeScroll.drawsBackground = true
        scopeScroll.backgroundColor = .wdCard
        scopeScroll.borderType = .lineBorder
        scopeScroll.translatesAutoresizingMaskIntoConstraints = false
        scopeScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true
        scopeList.widthAnchor.constraint(greaterThanOrEqualTo: scopeScroll.contentView.widthAnchor).isActive = true
        scopeScroll.wantsLayer = true
        scopeScroll.layer?.cornerRadius = 8

        let col = NSStackView(views: [title, statusL,
                                      section("大模型", "LLM"),
                                      prow,
                                      row("接口地址", "Base URL", baseField),
                                      row("API Key", "API Key", keyField),
                                      row("模型", "Model", modelField),
                                      hint, btnRow,
                                      section("飞书推送范围", "Push Scope"),
                                      scopeRow, scopeHint, scopeScroll])
        col.orientation = .vertical; col.alignment = .leading; col.spacing = 9
        col.edgeInsets = NSEdgeInsets(top: 18, left: 16, bottom: 16, right: 16)
        col.translatesAutoresizingMaskIntoConstraints = false
        addSubview(col)
        NSLayoutConstraint.activate([
            col.topAnchor.constraint(equalTo: topAnchor),
            col.leadingAnchor.constraint(equalTo: leadingAnchor),
            col.trailingAnchor.constraint(equalTo: trailingAnchor),
            col.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }
    public required init?(coder: NSCoder) { fatalError() }

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

    /// 字段内容变化:状态行显示各框已输入字符数(粘贴/输入是否生效一眼可见)
    public func controlTextDidChange(_ obj: Notification) {
        let b = baseField.stringValue, k = keyField.stringValue, m = modelField.stringValue
        statusL.stringValue = wdLang == "en"
            ? "chars — base \(b.count) · key \(k.count) · model \(m.count)"
            : "字符数 — 接口 \(b.count) · Key \(k.count) · 模型 \(m.count)"
    }

    /// 选服务商 → 接口地址+推荐模型跟随;自定义不动输入框
    private func applyPreset() {
        guard let p = Self.presets.first(where: { $0.name == providerPop.titleOfSelectedItem }),
              !p.base.isEmpty else { return }
        baseField.stringValue = p.base
        modelField.stringValue = p.model
    }

    /// 拉推送范围配置并渲染二级列表
    public func loadScope() {
        Task {
            struct ScopeResp: Codable {
                let mode: String?
                let stocks: [String]?
                let futures: [String]?
                let allStocks: [[String: String]]?
                let allFutures: [[String: String]]?
            }
            let r = try? await API.get("/api/push/scope", as: ScopeResp.self)
            await MainActor.run {
                guard let r else { scopeHint.stringValue = "(后端未就绪)"; return }
                scopeStocks = r.allStocks ?? []
                scopeFutures = r.allFutures ?? []
                scopeSel = Set((r.stocks ?? []) + (r.futures ?? []))
                scopePop.selectItem(at: r.mode == "custom" ? 1 : 0)
                scopeHint.stringValue = r.mode == "custom"
                    ? (wdLang == "en" ? "custom · \(scopeSel.count) selected" : "自定义 · 已选 \(scopeSel.count) 只(勾选后点保存)")
                    : (wdLang == "en" ? "all signals pushed" : "全部标的的信号都推")
                reloadScopeList()
            }
        }
    }

    private func reloadScopeList() {
        let cat = scopePop.indexOfSelectedItem   // 0=全部 1=股票和ETF 2=期货
        scopeList.views.forEach { $0.removeFromSuperview() }
        scopeHint.stringValue = cat == 0
            ? (wdLang == "en" ? "all signals pushed" : "全部标的的信号都推")
            : (wdLang == "en" ? "check the ones to push" : "勾选要推送的标的(保存后生效)")
        guard cat > 0 else { scopeList.fitTo(minHeight: 8); return }
        let items = cat == 1 ? scopeStocks : scopeFutures
        for it in items {
            let code = it["code"] ?? ""
            let btn = NSButton(checkboxWithTitle: "\(it["name"] ?? code)  \(code)",
                               target: nil, action: nil)
            btn.state = scopeSel.contains(code) ? .on : .off
            btn.font = .systemFont(ofSize: 11)
            btn.onAction { [weak self] in
                if btn.state == .on { self?.scopeSel.insert(code) }
                else { self?.scopeSel.remove(code) }
            }
            scopeList.addView(btn, in: .leading)
        }
        scopeList.fitTo(minHeight: 8)
    }

    private func saveScope() {
        let custom = scopePop.indexOfSelectedItem > 0
        let stocks = custom ? scopeSel.filter { !$0.isEmpty && $0.allSatisfy { $0.isNumber } } : []
        let futures = custom ? scopeSel.filter { !$0.allSatisfy { $0.isNumber } } : []
        Task {
            let ok = (try? await API.request("PUT", "/api/push/scope", [
                "mode": custom ? "custom" : "all", "stocks": stocks, "futures": futures])) ?? false
            await MainActor.run {
                scopeHint.stringValue = ok
                    ? (custom ? "✓ 已保存:\(stocks.count)只股票 + \(futures.count)个期货" : "✓ 已保存:全部标的")
                    : "✗ 保存失败"
            }
        }
    }

    /// 打开窗口时拉当前生效配置预填
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
                    ?? Self.presets.count - 1   // 匹配不到=自定义
                providerPop.selectItem(at: idx)
                switch cfg.source {
                case "db": statusL.stringValue = "✓ " + (wdLang == "en" ? "Configured (saved in app) · " : "已配置(存于应用)· ") + (cfg.model ?? "")
                case "env": statusL.stringValue = "✓ " + (wdLang == "en" ? "Configured (env vars) · " : "已配置(环境变量)· ") + (cfg.model ?? "")
                default: statusL.stringValue = wdLang == "en" ? "Not configured · top-bar input uses local rules" : "未配置 · 顶栏输入走本地规则(无大模型)"
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
            saveScope()
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
    var pasteCheck: (() -> Int)?   // 返回检查时刻三字段总字符数
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
                    self.manualPaste()   // 系统粘贴没落进:应用代读剪贴板完成这次粘贴
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    /// 兜底粘贴:直接读 NSPasteboard 插入当前焦点的字段编辑器(与系统粘贴同落点)
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

private func _diag(_ w: NSWindow, _ tag: String) {
    let fr = w.firstResponder is NSView ? String(describing: type(of: w.firstResponder!)) : "nil"
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
    let line = "\(f.string(from: Date())) [\(tag)] appActive=\(NSApp.isActive) keyWindow=\(w.isKeyWindow) firstResponder=\(fr)\n"
    let url = URL(fileURLWithPath: "/tmp/wd-focus.log")
    let prev = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    try? (prev + line).write(to: url, atomically: true, encoding: .utf8)
}

public func openSettingsWindow() {
    if let w = settingsWindowRef {
        w.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true); return
    }
    let pane = SettingsPane()
    let win = WdSettingsWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 302),
                               styleMask: [.titled, .closable], backing: .buffered, defer: false)
    win.isReleasedWhenClosed = false   // 关窗不释放:默认 true 会让全局 ref 悬挂→再开闪退
    win.title = t("看门狗") + " · " + (wdLang == "en" ? "Settings · LLM" : "设置 · 大模型")
    win.appearance = NSAppearance(named: wdThemeID == "mist" ? .aqua : .darkAqua)
    win.backgroundColor = .wdWin
    win.contentView = pane
    win.center()
    // 键盘焦点三步走(缺一步 Cmd+V 就会粘到别的 App):
    // ① App 升前台(托盘菜单打开时 App 不是 active,键盘事件仍路由给前一个应用)
    NSApp.activate(ignoringOtherApps: true)
    // ② 窗口升 key window(键盘事件的接收者)
    win.makeKeyAndOrderFront(nil)
    settingsWindowRef = win
    pane.bindPasteFeedback()
    pane.loadNow()
    pane.loadScope()
    // ③ 布局稳定后把光标放进 Key 输入框
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        win.makeKeyAndOrderFront(nil)
        win.makeFirstResponder(pane.keyField)
        _diag(win, "focused")
    }
    _diag(win, "opened")
}
