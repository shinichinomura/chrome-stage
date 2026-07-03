import AppKit
import ApplicationServices

// Accessibility 権限(TCC)の確認と案内。
// 権限は ChromeStage.app の署名に紐づくため、署名が変わると再許可が必要になる。
enum AccessibilityPermission {
    static var isGranted: Bool {
        AXIsProcessTrusted()
    }

    // システム標準の許可ダイアログを表示する(既に拒否済みの場合は表示されない)
    static func requestWithSystemPrompt() {
        let options = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    // システム設定のアクセシビリティ画面を直接開く
    static func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
