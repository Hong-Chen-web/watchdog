import AppKit
import WebKit

// MARK: - 主窗口(Web 版):WKWebView 装载 sidecar 的 /ui(看门狗 Web 工作台)
//
// 2026-10-16 UI 换版:主窗口由原生卡片栅格换成 Web 工作台(数据/动作全走本地 sidecar)。
// 原生能力经 window.webkit.messageHandlers.wd 桥回 App:K 线窗 / 设置窗。
// 旧原生主界面保留在 MainWindow.swift(测试与回退用,App 壳不再调用)。

final class WDBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        guard message.name == "wd", let s = message.body as? String,
              let d = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any] else { return }
        let cmd = d["cmd"] as? String ?? ""
        MainActor.assumeIsolated {
            switch cmd {
            case "kline":
                if let code = d["code"] as? String, !code.isEmpty {
                    let name = d["name"] as? String
                    print("[watchdog] bridge: kline \(code)")
                    openChartWindow(code: code, name: name ?? code)
                }
            case "settings":
                print("[watchdog] bridge: settings")
                openSettingsWindow()
            default:
                print("[watchdog] bridge: unknown cmd \(cmd)")
            }
        }
    }
}

public private(set) weak var webMainWebView: WKWebView?

public func buildWebMainWindow() -> NSWindow {
    let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1360, height: 900),
                       styleMask: [.titled, .closable, .miniaturizable, .resizable],
                       backing: .buffered, defer: false)
    win.title = t("看门狗") + " Watchdog"
    // 标题栏透明 + 隐藏标题文字:顶栏只留红绿灯,不占视觉
    win.titlebarAppearsTransparent = true
    win.titleVisibility = .hidden
    win.appearance = NSAppearance(named: wdThemeID == "mist" ? .aqua : .darkAqua)
    win.backgroundColor = NSColor(red: wdThemeID == "mist" ? 0.886 : 0.059,
                                  green: wdThemeID == "mist" ? 0.902 : 0.075,
                                  blue: wdThemeID == "mist" ? 0.918 : 0.102, alpha: 1)  // 浅#E2E6EA / 深#0F131A
    win.center()

    let cfg = WKWebViewConfiguration()
    cfg.userContentController.add(WDBridge(), name: "wd")
    let wv = WKWebView(frame: NSRect(x: 0, y: 0, width: 1360, height: 900), configuration: cfg)
    wv.autoresizingMask = [.width, .height]
    wv.uiDelegate = WDBrowserUIDelegate.shared
    // 设置窗切换主题/语言 → wd.themeChanged/wd.langChanged → 整窗重建 → 带参数重载 /ui
    let themeQ = wdThemeID == "sky" ? "sky" : "mist"
    let langQ = wdLang == "en" ? "en" : "zh"
    wv.load(URLRequest(url: URL(string: API.base + "/ui?theme=\(themeQ)&lang=\(langQ)")!))
    win.contentView = wv
    webMainWebView = wv
    win.setContentSize(NSSize(width: 1360, height: 900))
    win.center()
    return win
}

// MARK: JS confirm/alert 兜底(工作台当前不用,防未来脚本弹窗静默吞掉)

final class WDBrowserUIDelegate: NSObject, WKUIDelegate {
    static let shared = WDBrowserUIDelegate()
    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        let a = NSAlert()
        a.messageText = "看门狗"
        a.informativeText = message
        a.runModal()
        completionHandler()
    }
    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String,
                 initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let a = NSAlert()
        a.messageText = "看门狗"
        a.informativeText = message
        a.addButton(withTitle: "确定")
        a.addButton(withTitle: "取消")
        completionHandler(a.runModal() == .alertFirstButtonReturn)
    }
}
