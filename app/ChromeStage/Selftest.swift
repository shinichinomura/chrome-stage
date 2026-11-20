import AppKit

// ヘッドレス動作確認: `ChromeStage.app/Contents/MacOS/ChromeStage --selftest`
// UI を起動せずに、ウィンドウ検出 → AX 照合 → park → 復帰 → 永続化を一通り検証する。
// 実行後は対象ウィンドウを必ず元の位置へ戻す。
enum Selftest {
    static func run() -> Int32 {
        print("== ChromeStage selftest \(AppVersion.current.summary) ==")
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

        // 6. Slot 解除(detachWindow): 登録済み → missing に戻り、ウィンドウ参照が外れる。
        //    visible な slot の解除はウィンドウを動かさないため、実ウィンドウを乱さず検証できる。
        let detachURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("chromestage-selftest-detach.json")
        defer { try? FileManager.default.removeItem(at: detachURL) }
        let detachStore = StageSessionStore(fileURL: detachURL)
        let detachSlotID = UUID()
        detachStore.save(StageSessionRecord(
            activeSlotID: detachSlotID,
            stageRect: CodableRect(original),
            slots: [ChromeSlotRecord(
                id: detachSlotID, displayName: "detach",
                macWindowID: info.windowID, pid: Int32(info.pid),
                lastVisibleRect: CodableRect(original),
                state: .visible, createdAt: Date(), updatedAt: Date()
            )]
        ))
        let controller = StageController(store: detachStore)
        // 復元時に実ウィンドウと照合できて visible になっていることが前提
        if controller.slots.first?.record.state == .visible {
            controller.detachWindow(fromSlotID: detachSlotID)
            let after = controller.slots.first
            check("Slot 解除で missing に戻る",
                  after?.record.state == .missing
                  && after?.record.macWindowID == nil
                  && after?.axWindow == nil
                  && controller.activeSlotID == nil)
        } else {
            // 復元照合に失敗(別管理・タイミング等)した場合はこの検証をスキップする
            print("SKIP: Slot 解除(復元時に visible にならなかった)")
        }

        // 7. Chrome 再起動後の再照合(ジオメトリ)。実ウィンドウは使わず、Chrome が session restore で
        //    退避座標を作業領域内へ引き込む挙動(x = 右端 − 幅、y は据え置き)を模した合成データで検証する
        let workArea = CGRect(x: 1710, y: 30, width: 2560, height: 1410)
        let stageRect = CGRect(x: 1724, y: 76, width: 1974, height: 1242)
        let parked1 = CGRect(x: 4269, y: 116, width: 1974, height: 1242)
        let parked2 = CGRect(x: 4269, y: 156, width: 1974, height: 1242)
        check("AdjustToFit 移植(退避座標が右端 − 幅へ引き込まれる)",
              StageController.adjustToFit(parked1, in: workArea)
              == CGRect(x: 2296, y: 116, width: 1974, height: 1242))

        let (visibleID, parked1ID, parked2ID) = (UUID(), UUID(), UUID())
        let expected = [(visibleID, stageRect), (parked1ID, parked1), (parked2ID, parked2)].map {
            (id: $0.0, rects: StageController.restoredRectCandidates(for: $0.1, workArea: workArea))
        }
        let restored = [
            ChromeWindowInfo(windowID: 1, pid: 1, bounds: stageRect),
            ChromeWindowInfo(windowID: 2, pid: 1, bounds: CGRect(x: 2296, y: 116, width: 1974, height: 1242)),
            ChromeWindowInfo(windowID: 3, pid: 1, bounds: CGRect(x: 2296, y: 156, width: 1974, height: 1242)),
            ChromeWindowInfo(windowID: 4, pid: 1, bounds: CGRect(x: 100, y: 100, width: 800, height: 600)),
        ]
        check("再照合: 復元位置から slot を 1 対 1 で特定",
              StageController.matchByGeometry(expected: expected, windows: restored)
              == [visibleID: 1, parked1ID: 2, parked2ID: 3])

        // 曖昧なケースは採用しない: 同じ期待座標を持つ slot が複数
        let duplicated = [(id: parked1ID, rects: [parked1]), (id: parked2ID, rects: [parked1])]
        check("再照合: 期待座標が重複する slot は採用しない",
              StageController.matchByGeometry(expected: duplicated, windows: restored).isEmpty)
        // 曖昧なケースは採用しない: 1 つの期待座標に複数のウィンドウ
        let twin = restored + [ChromeWindowInfo(windowID: 5, pid: 1, bounds: stageRect)]
        let partial = StageController.matchByGeometry(expected: expected, windows: twin)
        check("再照合: 同じ位置に複数ウィンドウがある slot だけ見送る",
              partial[visibleID] == nil && partial[parked1ID] == 2 && partial[parked2ID] == 3)

        // 8. ディスプレイ構成変更: 外したディスプレイ上の座標を画面内へ収める
        if let primary = NSScreen.screens.first {
            let height = primary.frame.height
            let onScreen = CGRect(x: primary.frame.minX + 50, y: 60, width: 600, height: 400)
            check("表示範囲内の rect は補正しない", StageController.fitToScreens(onScreen) == onScreen)
            let gone = CGRect(x: primary.frame.maxX + 5000, y: -height, width: 1974, height: 1242)
            let fitted = StageController.fitToScreens(gone)
            check("外したディスプレイ上の rect が画面内へ収まる",
                  fitted != gone && StageController.fitToScreens(fitted) == fitted)
            check("構成の識別子を取得できる", !StageController.currentDisplaySignature().isEmpty)
        }

        print(failures == 0 ? "== ALL PASS ==" : "== \(failures) FAILURE(S) ==")
        return failures == 0 ? 0 : 1
    }
}
