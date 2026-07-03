import AppKit

// ヘッドレス動作確認: `ChromeStage.app/Contents/MacOS/ChromeStage --selftest`
// UI を起動せずに、ウィンドウ検出 → AX 照合 → park → 復帰 → 永続化を一通り検証する。
// 実行後は対象ウィンドウを必ず元の位置へ戻す。
enum Selftest {
    static func run() -> Int32 {
        print("== ChromeStage selftest ==")
        var failures = 0

        func check(_ name: String, _ ok: Bool) {
            print("\(ok ? "PASS" : "FAIL"): \(name)")
            if !ok { failures += 1 }
        }

        // 1. Accessibility 権限
        check("Accessibility 権限", AccessibilityPermission.isGranted)
        guard AccessibilityPermission.isGranted else { return 1 }

        // 2. Chrome ウィンドウ検出
        let windows = WindowDiscoveryService.listChromeWindows()
        check("Chrome ウィンドウ検出(\(windows.count) 件)", !windows.isEmpty)
        guard let info = windows.first else { return 1 }

        // 3. CGWindow と AX ウィンドウの照合
        guard let ax = AXWindow.match(info: info) else {
            check("AX 照合", false)
            return 1
        }
        check("AX 照合", true)

        guard let original = ax.frame() else {
            check("frame 取得", false)
            return 1
        }
        check("frame 取得", true)

        // 4. park(右端 1px 残し)と復帰
        let parkingX = (NSScreen.screens.map(\.frame.maxX).max() ?? 0) - 1
        check("park(右端 1px 残し)", ax.setPosition(CGPoint(x: parkingX, y: original.origin.y)))
        check("restore(元の位置へ復帰)",
              ax.setPosition(original.origin) && ax.setSize(original.size))

        // 5. セッション永続化の round-trip(実セッションを汚さないよう一時ファイルで行う)
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromestage-selftest-session.json")
        defer { try? FileManager.default.removeItem(at: tempURL) }
        let store = StageSessionStore(fileURL: tempURL)
        let record = ChromeSlotRecord(
            id: UUID(), displayName: "selftest",
            macWindowID: info.windowID, pid: Int32(info.pid),
            lastVisibleRect: CodableRect(original),
            state: .visible, createdAt: Date(), updatedAt: Date()
        )
        store.save(StageSessionRecord(
            activeSlotID: record.id,
            stageRect: CodableRect(original),
            slots: [record]
        ))
        let loaded = store.load()
        check("セッション永続化 round-trip",
              loaded?.slots.count == 1
              && loaded?.slots.first?.id == record.id
              && loaded?.slots.first?.state == .visible)

        print(failures == 0 ? "== ALL PASS ==" : "== \(failures) FAILURE(S) ==")
        return failures == 0 ? 0 : 1
    }
}
