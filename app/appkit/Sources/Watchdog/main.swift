import AppKit
import WebKit
import WatchdogCore

// MARK: - Watchdog 可执行壳:sidecar 管理 + AppDelegate + 入口

// MARK: Sidecar(复用打包好的 watchdog-server,开发期回退 Tauri binaries)

final class Sidecar {
    var proc: Process?

    func start() {
        // 清理孤儿 sidecar:上次强杀 App 会留下子进程占住 8790,新 sidecar 绑不上就静默失联
        let kill = Process()
        kill.executableURL = URL(fileURLWithPath: "/bin/zsh")
        kill.arguments = ["-c", "kill -9 $(/usr/sbin/lsof -nP -tiTCP:8790 -sTCP:LISTEN) 2>/dev/null; exit 0"]
        try? kill.run(); kill.waitUntilExit()
        sleep(1)
        // 优先 venv 源码服务(czsc native 全通);frozen 二进制做分发兜底
        let venvPy = "/Users/chenhong/github/czsc-repo/.venv/bin/python"
        let srcMain = "/Users/chenhong/github/personal-workbench/server/main.py"
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/watchdog-server")
        let frozen = bundled.path != "/" && FileManager.default.fileExists(atPath: bundled.path)
            ? bundled.path
            : "/Users/chenhong/github/personal-workbench/app/appkit/bin/watchdog-server"

        var exe: String
        var args: [String] = []
        if FileManager.default.fileExists(atPath: venvPy),
           FileManager.default.fileExists(atPath: srcMain) {
            exe = venvPy
            args = [srcMain]
        } else if FileManager.default.fileExists(atPath: frozen) {
            exe = frozen
        } else {
            print("[watchdog] no sidecar found"); return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        // 日志落盘:sidecar 的 print/异常不再是黑洞(调度静默死排查靠它)
        let logURL = FileManager.default.temporaryDirectory.appendingPathComponent("wd-sidecar.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        if let fh = FileHandle(forWritingAtPath: logURL.path) {
            fh.seekToEndOfFile()
            p.standardOutput = fh
            p.standardError = fh
        }
        try? p.run()
        proc = p
        print("[watchdog] sidecar: \(exe) \(args.joined(separator: " "))")
    }

    func stop() {
        proc?.terminate()
        try? proc?.waitUntilExit()
    }
}

// MARK: AppDelegate(等后端就绪开窗;托盘;红叉=退出)

final class AppDelegate: NSObject, NSApplicationDelegate {
    let sidecar = Sidecar()
    var win: NSWindow?
    var tray: NSStatusItem?

    func applicationDidFinishLaunching(_ n: Notification) {
        sidecar.start()
        _ = WKWebView()   // 预热:WebKit 首次初始化必须在 app run loop 内,否则后续创建 SIGSEGV
        // 等后端就绪再开窗(最长 45s);模块顺序/开关拉取不阻塞开窗,到达后经通知刷新
        Task {
            for _ in 0..<90 {
                if (try? await API.get("/api/health", as: HealthOK.self)) != nil { break }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            await MainActor.run {
                win = buildWebMainWindow()
                win?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
                // 深链:e2e 验收用 `--chart 002975 [名称]` 启动时直接开原生图窗
                if let i = CommandLine.arguments.firstIndex(of: "--chart"),
                   i + 1 < CommandLine.arguments.count {
                    let cd = CommandLine.arguments[i + 1]
                    let nm = i + 2 < CommandLine.arguments.count ? CommandLine.arguments[i + 2] : cd
                    openChartWindow(code: cd, name: nm)
                }
                if CommandLine.arguments.contains("--settings") {
                    openSettingsWindow()
                }
            }
            await refreshModulesFromServer()   // 顺序/开关与 Web 端同源(后台,不挡开窗)
        }
        // 主题切换:Web 工作台页面内即时换肤(CSS 变量),窗口不再重建
        NotificationCenter.default.addObserver(forName: .init("wd.themeChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                let js = "window.wdApplyTheme && window.wdApplyTheme('\(wdThemeID)')"
                webMainWebView?.evaluateJavaScript(js, completionHandler: nil)
                if webMainWebView == nil {   // 兜底:主窗口尚未创建(理论上不发生)
                    self?.win?.close()
                    self?.win = buildWebMainWindow()
                    self?.win?.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            }
        }
        NotificationCenter.default.addObserver(forName: .init("wd.langChanged"), object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                let js = "window.wdApplyLang && window.wdApplyLang('\(wdLang)')"
                webMainWebView?.evaluateJavaScript(js, completionHandler: nil)
            }
        }
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        tray?.button?.image = dogTrayImage()
        let menu = NSMenu()
        menu.addItem(withTitle: t("看门狗"), action: #selector(showWin), keyEquivalent: "")
        menu.addItem(withTitle: wdLang == "en" ? "Settings · LLM" : "设置 · 大模型",
                     action: #selector(openSettings), keyEquivalent: ",")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Exit", action: #selector(quit), keyEquivalent: "q")
        tray?.menu = menu
    }

    @objc func showWin() { win?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func openSettings() { openSettingsWindow() }
    @objc func quit() { sidecar.stop(); NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关任何窗后:仅当已无可见主窗口(非 Panel)才退——关详情窗绝不误退主应用
        return WdLifecycle.shouldTerminate(
            visibleNonPanelWindows: NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }.count)
    }
}

// MARK: 入口

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()



/// 托盘图标:自绘 Phosphor 线条狗(单色模板风,不依赖资源查找)
func dogTrayImage() -> NSImage {
    registerPhosphor()
    let size: CGFloat = 18
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let p = NSAttributedString(string: Ph.glyph("dog"), attributes: [
        .font: NSFont(name: "Phosphor", size: 16) ?? .systemFont(ofSize: 14),
        .foregroundColor: NSColor.labelColor,
    ])
    let sz = p.size()
    p.draw(at: NSPoint(x: (size - sz.width) / 2, y: (size - sz.height) / 2))
    img.unlockFocus()
    img.isTemplate = true   // 跟随菜单栏明暗
    return img
}
