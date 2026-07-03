import AppKit
import ApplicationServices

// 他プロセスのウィンドウ 1 枚に対する Accessibility API 操作の薄いラッパー。
// 方針(CLAUDE.md): 操作後に実際の値を読み直して検証し、失敗時はリトライする。
final class AXWindow {
    let pid: pid_t
    let element: AXUIElement

    private static let retryCount = 3
    private static let settleInterval: useconds_t = 100_000 // AX 反映待ち

    init(pid: pid_t, element: AXUIElement) {
        self.pid = pid
        self.element = element
    }

    // MARK: - 取得

    static func standardWindows(pid: pid_t) -> [AXWindow] {
        let app = AXUIElementCreateApplication(pid)
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }

        return windows.compactMap { element in
            var subroleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)
            guard (subroleRef as? String) == kAXStandardWindowSubrole as String else { return nil }
            return AXWindow(pid: pid, element: element)
        }
    }

    // CGWindowList の情報(座標・サイズ)と AX ウィンドウを照合する。
    // kCGWindowName は Screen Recording 権限が必要なため、ジオメトリのみで照合する。
    static func match(info: ChromeWindowInfo, tolerance: CGFloat = 2.0) -> AXWindow? {
        standardWindows(pid: info.pid).first { $0.matches(info, tolerance: tolerance) }
    }

    // 注意: ジオメトリ照合のため、同一座標・同一サイズのウィンドウ同士は区別できない。
    // 複数 slot を一括で照合する場合は、割り当て済みウィンドウを候補から外して
    // 1 対 1 になるようにすること(StageController.restoreSession 参照)
    func matches(_ info: ChromeWindowInfo, tolerance: CGFloat = 2.0) -> Bool {
        guard let frame = frame() else { return false }
        return abs(frame.origin.x - info.bounds.origin.x) <= tolerance
            && abs(frame.origin.y - info.bounds.origin.y) <= tolerance
            && abs(frame.width - info.bounds.width) <= tolerance
            && abs(frame.height - info.bounds.height) <= tolerance
    }

    // MARK: - 読み取り

    func position() -> CGPoint? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &ref) == .success
        else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    func size() -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &ref) == .success
        else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    func frame() -> CGRect? {
        guard let position = position(), let size = size() else { return nil }
        return CGRect(origin: position, size: size)
    }

    // ウィンドウがまだ存在するか(閉じられた AXUIElement は属性が読めなくなる)
    var isAlive: Bool {
        position() != nil
    }

    // MARK: - 書き込み(検証・リトライ付き)

    @discardableResult
    func setPosition(_ target: CGPoint, tolerance: CGFloat = 2.0) -> Bool {
        for attempt in 1...Self.retryCount {
            var point = target
            guard let value = AXValueCreate(.cgPoint, &point) else { return false }
            AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
            usleep(Self.settleInterval)

            guard let actual = position() else { return false }
            if abs(actual.x - target.x) <= tolerance && abs(actual.y - target.y) <= tolerance {
                return true
            }
            Log.ax.warning("位置設定が要求とずれた(試行 \(attempt)): 要求 (\(target.x), \(target.y)) 実際 (\(actual.x), \(actual.y))")
        }
        return false
    }

    @discardableResult
    func setSize(_ target: CGSize, tolerance: CGFloat = 2.0) -> Bool {
        for attempt in 1...Self.retryCount {
            var size = target
            guard let value = AXValueCreate(.cgSize, &size) else { return false }
            AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
            usleep(Self.settleInterval)

            guard let actual = self.size() else { return false }
            if abs(actual.width - target.width) <= tolerance && abs(actual.height - target.height) <= tolerance {
                return true
            }
            Log.ax.warning("サイズ設定が要求とずれた(試行 \(attempt))")
        }
        return false
    }

    // MARK: - 前面化

    func raise() {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func focus() {
        raise()
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
}
