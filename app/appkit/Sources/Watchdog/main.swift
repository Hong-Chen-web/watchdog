import AppKit
import WebKit
import WatchdogCore

// MARK: - Watchdog 可执行壳:sidecar 管理 + AppDelegate + 入口

// MARK: Sidecar(复用打包好的 watchdog-server,开发期回退 Tauri binaries)

final class Sidecar {
    var proc: Process?

    func start() {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/watchdog-server")
        let exe = bundled.path == "/" || !FileManager.default.fileExists(atPath: bundled.path)
            ? "/Users/chenhong/github/personal-workbench/app/appkit/bin/watchdog-server"
            : bundled.path
        guard FileManager.default.fileExists(atPath: exe) else {
            print("[watchdog] sidecar not found: \(exe)"); return
        }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        proc = p
        print("[watchdog] sidecar: \(exe)")
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
                win = buildMainWindow()
                win?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            await refreshModulesFromServer()   // 顺序/开关与 Web 端同源(后台,不挡开窗)
        }
        // 主题切换 = 整窗重建(全新窗口+视图树;局部重建会有顽固的层内容残留)
        NotificationCenter.default.addObserver(forName: .init("wd.themeChanged"), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.win?.close()
                self?.win = buildMainWindow()
                self?.win?.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        tray = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        tray?.button?.image = dogTrayImage()
        let menu = NSMenu()
        menu.addItem(withTitle: t("看门狗"), action: #selector(showWin), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Exit", action: #selector(quit), keyEquivalent: "q")
        tray?.menu = menu
    }

    @objc func showWin() { win?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc func quit() { sidecar.stop(); NSApp.terminate(nil) }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return NSApp.windows.filter { $0.isVisible && !($0 is NSPanel) }.count <= 1   // 详情窗关闭不应退出主应用
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
