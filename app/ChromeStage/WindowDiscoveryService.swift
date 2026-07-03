import AppKit
import CoreGraphics

// CGWindowList から取得した Chrome ウィンドウの情報。
// 注意: kCGWindowName は Screen Recording 権限がないと取得できないため、
// タイトルには依存せず windowID と座標(bounds)で扱う。
struct ChromeWindowInfo {
    let windowID: CGWindowID
    let pid: pid_t
    let bounds: CGRect // グローバル座標(左上原点)
}

// Chrome の通常ウィンドウを列挙する。
enum WindowDiscoveryService {
    static let chromeBundleID = "com.google.Chrome"

    static var chromeApp: NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == chromeBundleID }
    }

    // 画面上にある Chrome のウィンドウを前面から順に返す。
    // layer == 0 で通常ウィンドウ以外(メニュー・ツールチップ等)を除外する。
    // popup / DevTools の判別は AX 側(subrole)で行う。
    static func listChromeWindows() -> [ChromeWindowInfo] {
        guard let chromePid = chromeApp?.processIdentifier else { return [] }
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return [] }

        return windowList.compactMap { info in
            guard
                let ownerPid = info[kCGWindowOwnerPID as String] as? pid_t,
                ownerPid == chromePid,
                let layer = info[kCGWindowLayer as String] as? Int,
                layer == 0,
                let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            else { return nil }

            let bounds = CGRect(
                x: boundsDict["X"] ?? 0,
                y: boundsDict["Y"] ?? 0,
                width: boundsDict["Width"] ?? 0,
                height: boundsDict["Height"] ?? 0
            )
            // 小さすぎるウィンドウ(ステータスバブル等)は除外
            guard bounds.width >= 200, bounds.height >= 100 else { return nil }

            return ChromeWindowInfo(windowID: windowID, pid: ownerPid, bounds: bounds)
        }
    }

    // 最前面の Chrome 通常ウィンドウ(リストは前面から順)
    static func frontmostChromeWindow() -> ChromeWindowInfo? {
        listChromeWindows().first
    }
}
