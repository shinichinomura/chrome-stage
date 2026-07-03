import AppKit

// Stage の中核。Slot の管理、切り替え、offscreen parking、Unpark All を担当する。
//
// parking はスパイク(spikes/offscreen-parking)の結果に基づき
// 「右端に 1px だけ画面内に残す」方式で行う。完全な画面外は WindowServer に
// クランプされるため使えない。
final class StageController {
    private let store: StageSessionStore

    private(set) var slots: [Slot] = []
    private(set) var activeSlotID: UUID?
    private var stageRect: CGRect?

    init(store: StageSessionStore = StageSessionStore()) {
        self.store = store
        restoreSession()
    }

    // MARK: - セッション復元

    private func restoreSession() {
        guard let session = store.load() else { return }
        activeSlotID = session.activeSlotID
        stageRect = session.stageRect?.rect

        let infos = WindowDiscoveryService.listChromeWindows()
        // AX ウィンドウの割り当ては必ず 1 対 1 にする。退避中のウィンドウは全 slot が
        // 同一座標・同一サイズになるため、単純なジオメトリ照合では複数 slot が同じ
        // ウィンドウを掴み、残りが画面外に取り残される(実際に起きた事故)
        var pool = infos.first.map { AXWindow.standardWindows(pid: $0.pid) } ?? []
        slots = session.slots.map { record in
            let slot = Slot(record: record)
            // macWindowID は Chrome 起動中のみ有効。一致するウィンドウがあれば AX を再照合する
            if let windowID = record.macWindowID,
               let info = infos.first(where: { $0.windowID == windowID }),
               let index = pool.firstIndex(where: { $0.matches(info) }) {
                slot.axWindow = pool.remove(at: index)
            } else {
                slot.record.state = .missing
            }
            return slot
        }
        let missing = slots.filter { $0.record.state == .missing }.count
        Log.stage.info("セッション復元: slot \(self.slots.count) 件(うち missing \(missing) 件)")
    }

    private func save() {
        store.save(StageSessionRecord(
            activeSlotID: activeSlotID,
            stageRect: stageRect.map(CodableRect.init),
            slots: slots.map(\.record)
        ))
        NotificationCenter.default.post(name: .stageDidChange, object: nil)
    }

    // MARK: - Slot 管理

    func isRegistered(windowID: CGWindowID) -> Bool {
        slots.contains { $0.record.macWindowID == windowID && $0.record.state != .missing }
    }

    @discardableResult
    func addSlot(info: ChromeWindowInfo, named name: String) -> Slot? {
        guard let ax = AXWindow.match(info: info) else {
            Log.stage.error("Slot 追加失敗: AX 照合できない(windowID \(info.windowID))")
            return nil
        }
        let record = ChromeSlotRecord(
            id: UUID(),
            displayName: name,
            macWindowID: info.windowID,
            pid: Int32(info.pid),
            lastVisibleRect: CodableRect(info.bounds),
            state: .visible,
            createdAt: Date(),
            updatedAt: Date()
        )
        let slot = Slot(record: record, axWindow: ax)
        slots.append(slot)

        // 最初の slot はそのまま active とし、その位置を stage rect の初期値にする
        if activeSlotID == nil {
            activeSlotID = record.id
            stageRect = info.bounds
        }
        save()
        Log.stage.info("Slot 追加: \(record.id, privacy: .public) (windowID \(info.windowID))")
        return slot
    }

    func removeSlot(id: UUID) {
        guard let index = slots.firstIndex(where: { $0.record.id == id }) else { return }
        let slot = slots[index]
        // 退避中のまま削除すると迷子になるため、先に画面内へ戻す
        if slot.record.state == .parked {
            unpark(slot)
        }
        slots.remove(at: index)
        if activeSlotID == id { activeSlotID = nil }
        save()
        Log.stage.info("Slot 削除: \(id, privacy: .public)")
    }

    // MARK: - 切り替え

    func switchTo(id: UUID) {
        guard let target = slots.first(where: { $0.record.id == id }) else { return }
        guard let targetAX = target.axWindow, targetAX.isAlive else {
            target.record.state = .missing
            save()
            Log.stage.warning("切り替え失敗: 対象ウィンドウが存在しない(slot \(id, privacy: .public))")
            return
        }

        // stage rect の更新: 現在表示中の active slot の実 frame を最優先で採用する
        // (ユーザーが移動・リサイズした結果を引き継ぐため)
        if let active = slots.first(where: { $0.record.id == activeSlotID }),
           active.record.state == .visible,
           let frame = active.axWindow?.frame() {
            stageRect = frame
        }
        if stageRect == nil {
            // target が退避中の場合、現 frame は退避座標のため lastVisibleRect を優先する
            stageRect = target.record.lastVisibleRect?.rect ?? targetAX.frame()
        }

        // ターゲット以外の登録済みウィンドウをすべて退避。
        // y を slot ごとにずらし、退避中もジオメトリが一意になるようにする
        // (同一座標に重ねると、再起動時のジオメトリ照合で slot を区別できなくなる)
        for (index, slot) in slots.enumerated() where slot.record.id != id {
            park(slot, yOffset: CGFloat(index) * 40)
        }

        // ターゲットをステージへ復帰して前面化
        if let rect = stageRect {
            targetAX.setPosition(rect.origin)
            targetAX.setSize(rect.size)
        }
        targetAX.focus()
        target.record.state = .visible
        target.record.updatedAt = Date()
        activeSlotID = id
        save()
        Log.stage.info("切り替え完了: slot \(id, privacy: .public)")
    }

    // MARK: - Parking

    // 退避座標: 右端のディスプレイの外へ、左端 1px だけ画面内に残す
    private static func parkingX() -> CGFloat {
        let globalMaxX = NSScreen.screens.map(\.frame.maxX).max() ?? 1440
        return globalMaxX - 1
    }

    private func park(_ slot: Slot, yOffset: CGFloat = 0) {
        guard slot.record.state == .visible,
              let ax = slot.axWindow, ax.isAlive,
              let frame = ax.frame() else { return }

        slot.record.lastVisibleRect = CodableRect(frame)
        if ax.setPosition(CGPoint(x: Self.parkingX(), y: frame.origin.y + yOffset)) {
            slot.record.state = .parked
            slot.record.updatedAt = Date()
        } else {
            Log.stage.error("park 失敗: slot \(slot.record.id, privacy: .public)")
        }
    }

    private func unpark(_ slot: Slot, fallbackOffset: CGFloat = 0) {
        guard slot.record.state == .parked else { return }
        guard let ax = slot.axWindow, ax.isAlive else {
            slot.record.state = .missing
            return
        }
        var rect = slot.record.lastVisibleRect?.rect
            ?? stageRect
            ?? CGRect(x: 100, y: 100, width: 1200, height: 800)
        if slot.record.lastVisibleRect == nil {
            // 同じ位置に積み重ならないよう少しずらす
            rect.origin.x += fallbackOffset
            rect.origin.y += fallbackOffset
        }
        ax.setPosition(rect.origin)
        ax.setSize(rect.size)
        slot.record.state = .visible
        slot.record.updatedAt = Date()
    }

    // 安全機能: 退避中の全ウィンドウを画面内へ戻す(メニュー・アプリ終了時・復旧用)
    func unparkAll() {
        var offset: CGFloat = 0
        for slot in slots where slot.record.state == .parked {
            unpark(slot, fallbackOffset: offset)
            offset += 30
        }
        rescueStrandedWindows()
        save()
        Log.stage.info("Unpark All 実行")
    }

    // 最後の安全網: slot の状態に関係なく、画面外に取り残された Chrome ウィンドウを
    // すべて画面内へ戻す。slot 照合に失敗した場合や、Chrome 再起動で windowID が
    // 変わり missing になった場合でも、ウィンドウを迷子のままにしない
    private func rescueStrandedWindows() {
        guard let pid = WindowDiscoveryService.chromeApp?.processIdentifier else { return }
        let minX = NSScreen.screens.map(\.frame.minX).min() ?? 0
        let maxX = NSScreen.screens.map(\.frame.maxX).max() ?? 0

        var rescued = 0
        for window in AXWindow.standardWindows(pid: pid) {
            guard let frame = window.frame() else { continue }
            let visibleWidth = min(frame.maxX, maxX) - max(frame.minX, minX)
            // 画面内にほぼ見えていないウィンドウを取り残しとみなす
            guard visibleWidth < 50 else { continue }
            let target = CGPoint(x: 80 + CGFloat(rescued) * 50, y: 60 + CGFloat(rescued) * 40)
            window.setPosition(target)
            rescued += 1
        }
        if rescued > 0 {
            Log.recovery.warning("slot 管理外で画面外に取り残された Chrome ウィンドウ \(rescued) 件を救出した")
        }
    }

    // MARK: - 巡回切り替え(ホットキー用)

    // 切り替え可能な slot(missing を除く)
    var switchableSlots: [Slot] {
        slots.filter { $0.record.state != .missing }
    }

    func switchNext() { cycle(1) }
    func switchPrevious() { cycle(-1) }

    private func cycle(_ delta: Int) {
        let list = switchableSlots
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.record.id == activeSlotID } ?? -1
        let next = ((current + delta) % list.count + list.count) % list.count
        switchTo(id: list[next].record.id)
    }

    // メニュー・Overlay の表示順(1 始まり)で直接切り替える
    func switchToIndex(_ index: Int) {
        guard index >= 1, index <= slots.count else { return }
        let slot = slots[index - 1]
        guard slot.record.state != .missing else { return }
        switchTo(id: slot.record.id)
    }

    // MARK: - 復旧処理

    // 正常終了時は unparkAll してから終了するため、起動時に parked が残っていれば
    // 前回はクラッシュ等の異常終了だったとみなして復帰させる
    func recoverFromCrashIfNeeded() {
        let parked = slots.filter { $0.record.state == .parked }
        guard !parked.isEmpty else { return }
        Log.recovery.warning("前回異常終了の可能性: 退避されたまま残ったウィンドウ \(parked.count) 件を復帰する")
        unparkAll()
    }

    // ディスプレイ構成変更: 退避座標を再計算し、stage rect が画面外ならリセットする
    func handleDisplayChange() {
        Log.recovery.info("ディスプレイ構成変更を検出")

        if let rect = stageRect {
            let cocoa = Self.cocoaRect(fromAXRect: rect)
            if !NSScreen.screens.contains(where: { $0.frame.intersects(cocoa) }) {
                Log.recovery.warning("stage rect が画面外になったためリセット")
                stageRect = nil
            }
        }

        for slot in slots where slot.record.state == .parked {
            guard let ax = slot.axWindow, ax.isAlive, let frame = ax.frame() else { continue }
            // 新しい構成の退避座標へ移し直す。失敗したら迷子防止のため画面内へ戻す
            if !ax.setPosition(CGPoint(x: Self.parkingX(), y: frame.origin.y)) {
                unpark(slot)
            }
        }
        save()
    }

    // Chrome 終了: 全 slot のウィンドウ参照が無効になる
    func handleChromeTerminated() {
        Log.recovery.info("Chrome の終了を検出。全 slot を missing にする")
        for slot in slots {
            slot.axWindow = nil
            slot.record.state = .missing
        }
        save()
    }

    // AX 座標(左上原点)から Cocoa 座標(左下原点)への変換。
    // グローバル座標の基準はプライマリディスプレイ(NSScreen.screens[0])
    private static func cocoaRect(fromAXRect rect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(
            x: rect.origin.x,
            y: primaryHeight - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }
}

extension Notification.Name {
    // Stage の状態(slot 一覧・active)が変化した通知。Overlay UI の再描画に使う
    static let stageDidChange = Notification.Name("com.shinichinomura.ChromeStage.stageDidChange")
}
