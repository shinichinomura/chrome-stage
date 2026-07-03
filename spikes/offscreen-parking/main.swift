// offscreen parking 成立検証スパイク
//
// 目的: Accessibility API で Chrome ウィンドウを画面外座標へ移動できるか、
//       macOS による位置補正(クランプ)が発生するかを確認する。
//
// 実行方法: swift main.swift
// 前提: 実行元プロセス(ターミナル等)に Accessibility 権限が必要。
//       Chrome の通常ウィンドウが 1 つ以上開いていること。
//
// 検証内容:
//   1. Chrome の最前面ウィンドウの現在位置・サイズを記録
//   2. 複数の退避座標パターンへ移動し、直後に実座標を読み直して比較
//   3. 最後に元の位置へ復帰させる

import Cocoa
import ApplicationServices

// MARK: - AX ヘルパー

func axValue(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
    var ref: CFTypeRef?
    let err = AXUIElementCopyAttributeValue(element, attribute as CFString, &ref)
    return err == .success ? ref : nil
}

func axPoint(_ element: AXUIElement, _ attribute: String) -> CGPoint? {
    guard let ref = axValue(element, attribute) else { return nil }
    var point = CGPoint.zero
    guard AXValueGetValue(ref as! AXValue, .cgPoint, &point) else { return nil }
    return point
}

func axSize(_ element: AXUIElement, _ attribute: String) -> CGSize? {
    guard let ref = axValue(element, attribute) else { return nil }
    var size = CGSize.zero
    guard AXValueGetValue(ref as! AXValue, .cgSize, &size) else { return nil }
    return size
}

func axSetPoint(_ element: AXUIElement, _ attribute: String, _ point: CGPoint) -> AXError {
    var p = point
    let value = AXValueCreate(.cgPoint, &p)!
    return AXUIElementSetAttributeValue(element, attribute as CFString, value)
}

// MARK: - 前提チェック

guard AXIsProcessTrusted() else {
    print("NG: このプロセスに Accessibility 権限がありません。")
    print("システム設定 > プライバシーとセキュリティ > アクセシビリティ で、")
    print("このスクリプトを実行しているアプリ(ターミナル / VS Code など)を許可してください。")
    exit(1)
}

guard let chrome = NSWorkspace.shared.runningApplications.first(where: {
    $0.bundleIdentifier == "com.google.Chrome"
}) else {
    print("NG: Google Chrome が起動していません。")
    exit(1)
}

let appElement = AXUIElementCreateApplication(chrome.processIdentifier)

guard let windowRefs = axValue(appElement, kAXWindowsAttribute) as? [AXUIElement] else {
    print("NG: Chrome のウィンドウ一覧を取得できませんでした。")
    exit(1)
}

// 通常ウィンドウ(AXStandardWindow)のみ対象にする
let standardWindows = windowRefs.filter { win in
    (axValue(win, kAXSubroleAttribute) as? String) == "AXStandardWindow"
}

guard let target = standardWindows.first else {
    print("NG: Chrome の通常ウィンドウが見つかりません。")
    exit(1)
}

let title = (axValue(target, kAXTitleAttribute) as? String) ?? "(no title)"
guard let originalPos = axPoint(target, kAXPositionAttribute),
      let windowSize = axSize(target, kAXSizeAttribute) else {
    print("NG: 対象ウィンドウの位置・サイズを取得できませんでした。")
    exit(1)
}

print("対象ウィンドウ: \(title.prefix(40))")
print("元の位置: \(originalPos), サイズ: \(windowSize)")
print("ディスプレイ構成:")
for screen in NSScreen.screens {
    print("  frame=\(screen.frame)")
}
print("")

// MARK: - 退避座標パターンの検証

struct Pattern {
    let name: String
    let point: CGPoint
}

// AX 座標系は左上原点(グローバル座標)
let mainFrame = NSScreen.screens[0].frame
let patterns: [Pattern] = [
    Pattern(name: "設計メモ案: 左に大きく飛ばす (-20000, 100)",
            point: CGPoint(x: -20000, y: 100)),
    Pattern(name: "右に大きく飛ばす (+20000, 100)",
            point: CGPoint(x: 20000, y: 100)),
    Pattern(name: "下に大きく飛ばす (100, +20000)",
            point: CGPoint(x: 100, y: 20000)),
    Pattern(name: "左にウィンドウ幅ちょうど+1px",
            point: CGPoint(x: -(windowSize.width + 1), y: originalPos.y)),
    Pattern(name: "1px だけ画面内に残す(左端)",
            point: CGPoint(x: -(windowSize.width - 1), y: originalPos.y)),
    Pattern(name: "下端ギリギリ(メニューバー分残し)",
            point: CGPoint(x: originalPos.x, y: mainFrame.height - 1)),
    Pattern(name: "1px だけ画面内に残す(右端)",
            point: CGPoint(x: mainFrame.width - 1, y: originalPos.y)),
    Pattern(name: "右端 1px 残し + 下方向にも最大限寄せる",
            point: CGPoint(x: mainFrame.width - 1, y: mainFrame.height - 1)),
]

var results: [(name: String, requested: CGPoint, actual: CGPoint?, err: AXError)] = []

for pattern in patterns {
    let err = axSetPoint(target, kAXPositionAttribute, pattern.point)
    // AX 操作は非同期に反映されることがあるため少し待ってから読み直す
    usleep(200_000)
    let actual = axPoint(target, kAXPositionAttribute)
    results.append((pattern.name, pattern.point, actual, err))

    let actualStr = actual.map { "(\($0.x), \($0.y))" } ?? "読取失敗"
    let clamped: String
    if let a = actual {
        clamped = (abs(a.x - pattern.point.x) < 1 && abs(a.y - pattern.point.y) < 1)
            ? "OK: 要求どおり" : "CLAMPED: 補正あり"
    } else {
        clamped = "?: 実座標を読めず"
    }
    print("[\(clamped)] \(pattern.name)")
    print("    要求: (\(pattern.point.x), \(pattern.point.y)) → 実際: \(actualStr), AXError=\(err.rawValue)")
}

// MARK: - 復帰

let restoreErr = axSetPoint(target, kAXPositionAttribute, originalPos)
usleep(200_000)
let restored = axPoint(target, kAXPositionAttribute)
print("")
print("復帰: 要求 \(originalPos) → 実際 \(restored.map { "\($0)" } ?? "読取失敗"), AXError=\(restoreErr.rawValue)")

// MARK: - サマリ

print("")
print("=== サマリ ===")
let succeeded = results.filter { r in
    guard let a = r.actual else { return false }
    return abs(a.x - r.requested.x) < 1 && abs(a.y - r.requested.y) < 1
}
print("要求どおり移動できたパターン: \(succeeded.count) / \(results.count)")
for s in succeeded {
    print("  - \(s.name)")
}
