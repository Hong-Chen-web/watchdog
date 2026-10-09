import Foundation

/// 关窗退出判定(AppKit 在每次任意窗口关闭后都会询问,返回 true 即终止应用)
public enum WdLifecycle {
    /// 仅当已无可见主窗口(非 Panel)才允许退出——关详情窗/图表窗绝不误退主应用
    public static func shouldTerminate(visibleNonPanelWindows: Int) -> Bool {
        visibleNonPanelWindows == 0
    }
}
