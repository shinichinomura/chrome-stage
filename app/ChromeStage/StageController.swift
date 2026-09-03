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

    // Chrome 再起動後、session restore でウィンドウが順次現れるのを待つポーリング
    private var relaunchPollTimer: Timer?
    private var relaunchPollRemaining = 0
    // 今回の再照合で、退避中だった slot が 1 件でも照合できたか(表示中だった slot を採用する条件)
    private var rematchedParkedSlot = false

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
            } else if record.state != .missing {
                // ID で見つからない。Chrome が再起動して ID が変わった可能性があるので、
                // 見失う直前の座標を控えて後段のジオメトリ再照合に回す
                slot.record.lastKnownRect = Self.lastKnownRect(of: record)
                slot.record.state = .missing
            }
            return slot
        }
        // ID で照合できなかった slot を、Chrome が復元したウィンドウの座標で再照合する。
        // 起動時は退避し直さない(起動直後に parked が残っているとクラッシュ復旧が unpark するため)
        rematchedParkedSlot = false
        rematchLostSlots(repark: false)
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

    // Overlay のドラッグ並び替え結果を反映する。表示順(slots 配列の順序)は
    // チップ番号とホットキー(switchToIndex)に直結するため、順序を差し替えるだけで
    // 番号・ホットキーの割り当ても連動する。activeSlotID は id 基準なので影響しない。
    func reorderSlots(orderedIDs: [UUID]) {
        // 与えられた ID 集合が現在の slot と完全一致しない場合は、描画レース等で
        // 不整合が起きているとみなし、破壊的な並べ替えを避けて無視する
        guard orderedIDs.count == slots.count else { return }
        let byID = Dictionary(slots.map { ($0.record.id, $0) }, uniquingKeysWith: { first, _ in first })
        let reordered = orderedIDs.compactMap { byID[$0] }
        guard reordered.count == slots.count else { return }
        // 順序に変化がなければ、不要な保存・再描画を避ける
        guard zip(reordered, slots).contains(where: { $0.record.id != $1.record.id }) else { return }
        slots = reordered
        save()
        Log.stage.info("Slot 並び替え")
    }

    // MARK: - 既存 Slot へのウィンドウ再割り当て

    // assignFrontmostWindow の結果。UI 側でメッセージ表示に使う
    enum AssignResult {
        case success
        case slotNotFound
        case noChromeWindow
        case alreadyRegistered
        case axMatchFailed
    }

    // 原因不明でウィンドウが外れて missing になった Slot に、最前面の Chrome
    // ウィンドウを手動で割り当て直す(空スロットの右クリックから呼ばれる)。
    // Overlay は non-activating パネルのため、この呼び出し時点でも Chrome の
    // 最前面ウィンドウはユーザーが割り当てたいウィンドウのまま変わらない。
    @discardableResult
    func assignFrontmostWindow(toSlotID id: UUID) -> AssignResult {
        guard let slot = slots.first(where: { $0.record.id == id }) else { return .slotNotFound }
        guard let info = WindowDiscoveryService.frontmostChromeWindow() else { return .noChromeWindow }

        // 既に別の(生きている)Slot が掴んでいるウィンドウは奪わない。
        // 奪うと元の Slot のウィンドウが管理外になり、画面外へ取り残される恐れがある
        if slots.contains(where: {
            $0.record.id != id && $0.record.macWindowID == info.windowID && $0.record.state != .missing
        }) {
            return .alreadyRegistered
        }

        guard let ax = AXWindow.match(info: info) else {
            Log.stage.error("Slot 割り当て失敗: AX 照合できない(windowID \(info.windowID))")
            return .axMatchFailed
        }

        slot.axWindow = ax
        slot.record.macWindowID = info.windowID
        slot.record.pid = Int32(info.pid)
        slot.record.lastVisibleRect = CodableRect(info.bounds)
        slot.record.parkedRect = nil
        slot.record.lastKnownRect = nil
        slot.record.state = .visible
        slot.record.updatedAt = Date()
        save()
        Log.stage.info("Slot 割り当て: \(id, privacy: .public) ← windowID \(info.windowID)")

        // 割り当てたウィンドウをそのままステージのアクティブにする(他は退避)
        switchTo(id: id)
        return .success
    }

    // 誤って割り当てたウィンドウを slot から外し、再割り当て可能な missing 状態へ戻す。
    // slot の名前・並び順は保持する(assignFrontmostWindow の逆操作)。
    func detachWindow(fromSlotID id: UUID) {
        guard let slot = slots.first(where: { $0.record.id == id }) else { return }
        // 既に空(missing)なら外す対象がない
        guard slot.record.state != .missing else { return }
        // 退避中のまま外すとウィンドウが画面外へ取り残されるため、先に画面内へ戻す
        if slot.record.state == .parked {
            unpark(slot)
        }
        // ウィンドウ参照を解除して空きスロットへ戻す
        slot.axWindow = nil
        slot.record.macWindowID = nil
        slot.record.pid = nil
        slot.record.parkedRect = nil
        slot.record.lastKnownRect = nil
        slot.record.state = .missing
        slot.record.updatedAt = Date()
        if activeSlotID == id { activeSlotID = nil }
        save()
        Log.stage.info("Slot 解除: \(id, privacy: .public)")
    }

    // MARK: - 切り替え

    func switchTo(id: UUID) {
        guard let target = slots.first(where: { $0.record.id == id }) else { return }
        guard let targetAX = target.axWindow, targetAX.isAlive else {
            target.record.state = .missing
            target.record.parkedRect = nil
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
        // 表示位置を控える(Chrome 終了時の最終既知フレームとして再照合に使う)
        if let frame = targetAX.frame() {
            target.record.lastVisibleRect = CodableRect(frame)
        }
        target.record.parkedRect = nil
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
        let point = CGPoint(x: Self.parkingX(), y: frame.origin.y + yOffset)
        if ax.setPosition(point) {
            slot.record.state = .parked
            // 実際に置かれた座標を記録する(Chrome 再起動後の再照合の手がかり)
            slot.record.parkedRect = CodableRect(ax.frame() ?? CGRect(origin: point, size: frame.size))
            slot.record.updatedAt = Date()
        } else {
            Log.stage.error("park 失敗: slot \(slot.record.id, privacy: .public)")
        }
    }

    private func unpark(_ slot: Slot, fallbackOffset: CGFloat = 0) {
        guard slot.record.state == .parked else { return }
        slot.record.parkedRect = nil
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
            if ax.setPosition(CGPoint(x: Self.parkingX(), y: frame.origin.y)) {
                slot.record.parkedRect = ax.frame().map(CodableRect.init) ?? slot.record.parkedRect
            } else {
                unpark(slot)
            }
        }
        save()
    }

    // Chrome 終了: 終了したプロセスのウィンドウを掴んでいる slot の参照が無効になる。
    // 終了通知は bundle ID が同じ短命な二重起動プロセス(URL を本体へ引き渡して
    // すぐ終了する)でも届くため、slot が掴んでいる pid と一致するものだけを対象にする。
    // 一致しない終了は本体 Chrome とは無関係なので無視する
    func handleChromeTerminated(pid: pid_t) {
        let affected = slots.filter { $0.record.state != .missing && $0.record.pid == pid }
        guard !affected.isEmpty else {
            Log.recovery.info("slot と無関係な Chrome プロセスの終了を無視(pid \(pid))")
            return
        }
        Log.recovery.info("Chrome の終了を検出(pid \(pid))。slot \(affected.count) 件を missing にする")
        for slot in affected {
            // 見失う直前の座標を控える。Chrome が再起動(アップデート等)すると各ウィンドウは
            // この座標を作業領域に収めた位置へ復元されるので、再照合の手がかりになる
            slot.record.lastKnownRect = Self.lastKnownRect(of: slot.record)
            slot.axWindow = nil
            slot.record.state = .missing
            slot.record.updatedAt = Date()
        }
        save()
    }

    // MARK: - Chrome 再起動後の slot 復元

    // Chrome のアップデート等による再起動では、session restore が各プロファイルのウィンドウを
    // 保存済み座標へ復元する。ただし座標はそのままではなく、Chromium の
    // WindowSizer::DetermineWindowBoundsAndShowState が gfx::Rect::AdjustToFit で作業領域に
    // 収めるため、退避中だった窓は x = 作業領域右端 − 幅 に引き込まれ、y はそのまま残る
    // (実機で確認済み)。退避時に slot ごとに y をずらしているので、この y と
    // 「表示中だった窓は stage rect に戻る」ことを手がかりに slot を 1 対 1 で特定できる。
    //
    // 誤った名前を付ける方が missing のままより有害(別の契約先のウィンドウで作業しかねない)
    // なので、照合はジオメトリが一意に定まる場合にだけ採用し、曖昧なら missing のままにする。

    // 見失う直前の座標。退避中なら退避座標、表示中なら表示位置
    private static func lastKnownRect(of record: ChromeSlotRecord) -> CodableRect? {
        switch record.state {
        case .parked: return record.parkedRect
        case .visible: return record.lastVisibleRect
        case .missing: return record.lastKnownRect
        }
    }

    // 見失った(lastKnownRect を持つ missing の)slot
    private var lostSlots: [Slot] {
        slots.filter { $0.record.state == .missing && $0.record.lastKnownRect != nil }
    }

    // Chrome 起動検出(AppDelegate から)。session restore は各プロファイルのウィンドウを
    // 数秒かけて順次復元するため、一定時間ポーリングして再照合する
    func handleChromeLaunched(pid: pid_t) {
        guard !lostSlots.isEmpty else { return }
        Log.recovery.info("Chrome の起動を検出(pid \(pid))。見失った slot \(self.lostSlots.count) 件の再照合を開始する")
        rematchedParkedSlot = false
        relaunchPollRemaining = 60
        relaunchPollTimer?.invalidate()
        relaunchPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            self.relaunchPollRemaining -= 1
            self.rematchLostSlots(repark: true)
            let remaining = self.lostSlots.count
            if remaining == 0 || self.relaunchPollRemaining <= 0 || WindowDiscoveryService.chromeApp == nil {
                timer.invalidate()
                self.relaunchPollTimer = nil
                Log.recovery.info("再照合を終了(未復元の slot \(remaining) 件)")
            }
        }
    }

    // 見失った slot を、現在の Chrome ウィンドウとジオメトリで再照合する。
    // repark: 退避中だった slot を退避座標へ戻すか(実行中の Chrome 再起動では true、
    // アプリ起動時はクラッシュ復旧の unpark と衝突するため false)
    @discardableResult
    func rematchLostSlots(repark: Bool) -> Int {
        let lost = lostSlots
        guard !lost.isEmpty else { return 0 }
        let candidates = availableCandidates()
        guard !candidates.isEmpty else { return 0 }

        let expected = lost.map { slot -> (id: UUID, rects: [CGRect]) in
            let rect = slot.record.lastKnownRect!.rect
            return (slot.record.id, Self.restoredRectCandidates(for: rect, workArea: Self.workArea(containing: rect)))
        }
        let assignment = Self.matchByGeometry(expected: expected, windows: candidates.map(\.info))
        guard !assignment.isEmpty else { return 0 }

        var adopted = 0
        // 退避中だった slot を先に処理し、表示中だった slot の採用条件(下記)に反映する
        let ordered = lost.sorted { $0.record.parkedRect != nil && $1.record.parkedRect == nil }
        for slot in ordered {
            guard let windowID = assignment[slot.record.id],
                  let candidate = candidates.first(where: { $0.info.windowID == windowID }) else { continue }
            let wasParked = slot.record.parkedRect != nil

            // 表示中だった slot の期待座標は stage rect そのもの。Chrome を通常終了 → 通常起動した
            // 場合、各プロファイルは最後の表示位置を覚えているため、別プロファイルの新規ウィンドウが
            // 同じ座標に開くことがあり得る。退避中だった slot が 1 件も照合できていない間は
            // session restore とは判断できないので、誤った名前を付けないよう見送る
            if !wasParked, !rematchedParkedSlot, lost.contains(where: { $0.record.parkedRect != nil }) {
                continue
            }

            slot.axWindow = candidate.ax
            slot.record.macWindowID = candidate.info.windowID
            slot.record.pid = Int32(candidate.info.pid)
            slot.record.lastKnownRect = nil
            slot.record.parkedRect = nil
            slot.record.state = .visible
            slot.record.updatedAt = Date()
            if wasParked {
                rematchedParkedSlot = true
                if repark { self.repark(slot) }
            } else {
                // 表示中だったウィンドウは、復元された位置をそのまま表示位置とする
                slot.record.lastVisibleRect = CodableRect(candidate.info.bounds)
            }
            adopted += 1
            Log.recovery.info("再照合: slot \(slot.record.id, privacy: .public) ← windowID \(candidate.info.windowID)")
        }
        if adopted > 0 { save() }
        return adopted
    }

    // Chrome が復元した(退避中だった)ウィンドウを、表示位置の記録を保ったまま退避座標へ戻す。
    // park() は現在の frame を表示位置として記録してしまうため、ここでは使えない
    private func repark(_ slot: Slot) {
        guard let ax = slot.axWindow, ax.isAlive, let frame = ax.frame() else { return }
        let point = CGPoint(x: Self.parkingX(), y: frame.origin.y)
        if ax.setPosition(point) {
            slot.record.state = .parked
            slot.record.parkedRect = CodableRect(ax.frame() ?? CGRect(origin: point, size: frame.size))
        } else {
            Log.stage.error("再退避に失敗: slot \(slot.record.id, privacy: .public)")
        }
    }

    // どの slot も掴んでいない Chrome ウィンドウ(CGWindow 情報と AX 要素の 1 対 1 の組)。
    // 生きている slot が掴んでいる windowID と AX 要素は候補から外す
    private func availableCandidates() -> [(info: ChromeWindowInfo, ax: AXWindow)] {
        let infos = WindowDiscoveryService.listChromeWindows()
        guard let pid = infos.first?.pid else { return [] }
        let live = slots.filter { $0.record.state != .missing }
        let liveWindowIDs = Set(live.compactMap { $0.record.macWindowID })
        let liveElements = live.compactMap { $0.axWindow?.element }
        var pool = AXWindow.standardWindows(pid: pid).filter { ax in
            !liveElements.contains { CFEqual($0, ax.element) }
        }
        var candidates: [(info: ChromeWindowInfo, ax: AXWindow)] = []
        for info in infos where !liveWindowIDs.contains(info.windowID) {
            guard let index = pool.firstIndex(where: { $0.matches(info) }) else { continue }
            candidates.append((info, pool.remove(at: index)))
        }
        return candidates
    }

    // rect と最も重なるディスプレイの作業領域(AX 座標)。重なるものがなければメインディスプレイ。
    // Chromium の display::Screen::GetDisplayMatching(bounds).work_area() に相当する
    private static func workArea(containing rect: CGRect) -> CGRect {
        func overlap(_ screen: NSScreen) -> CGFloat {
            let i = axRect(fromCocoaRect: screen.frame).intersection(rect)
            return i.isNull ? 0 : i.width * i.height
        }
        let screen = NSScreen.screens.filter { overlap($0) > 0 }.max { overlap($0) < overlap($1) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return rect }
        return axRect(fromCocoaRect: screen.visibleFrame)
    }

    // Chrome が session restore で置き直す座標の候補: 保存座標そのものと、
    // それを作業領域に収めた座標(gfx::Rect::AdjustToFit 相当)の両方
    static func restoredRectCandidates(for rect: CGRect, workArea: CGRect) -> [CGRect] {
        let fitted = adjustToFit(rect, in: workArea)
        return fitted.equalTo(rect) ? [rect] : [rect, fitted]
    }

    // gfx::Rect::AdjustToFit の移植: サイズを領域以下に縮め、はみ出した分だけ内側へ寄せる
    static func adjustToFit(_ rect: CGRect, in area: CGRect) -> CGRect {
        func axis(_ origin: CGFloat, _ size: CGFloat, areaOrigin: CGFloat, areaSize: CGFloat) -> (CGFloat, CGFloat) {
            let newSize = min(areaSize, size)
            let newOrigin = origin < areaOrigin
                ? areaOrigin
                : min(areaOrigin + areaSize, origin + newSize) - newSize
            return (newOrigin, newSize)
        }
        let (x, width) = axis(rect.origin.x, rect.width, areaOrigin: area.origin.x, areaSize: area.width)
        let (y, height) = axis(rect.origin.y, rect.height, areaOrigin: area.origin.y, areaSize: area.height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    // 見失った slot の期待座標と、現在の Chrome ウィンドウを 1 対 1 で照合する。
    // 期待座標に合うウィンドウがちょうど 1 枚で、かつそのウィンドウに合う期待座標も
    // ちょうど 1 つの場合だけ採用する(どちらかが複数なら曖昧とみなして見送る)
    static func matchByGeometry(
        expected: [(id: UUID, rects: [CGRect])],
        windows: [ChromeWindowInfo],
        tolerance: CGFloat = 8
    ) -> [UUID: CGWindowID] {
        func fits(_ a: CGRect, _ b: CGRect) -> Bool {
            abs(a.origin.x - b.origin.x) <= tolerance
                && abs(a.origin.y - b.origin.y) <= tolerance
                && abs(a.width - b.width) <= tolerance
                && abs(a.height - b.height) <= tolerance
        }
        var result: [UUID: CGWindowID] = [:]
        for slot in expected {
            let hits = windows.filter { window in slot.rects.contains { fits($0, window.bounds) } }
            guard hits.count == 1, let window = hits.first else { continue }
            let rivals = expected.filter { other in other.rects.contains { fits($0, window.bounds) } }
            guard rivals.count == 1 else { continue }
            result[slot.id] = window.windowID
        }
        return result
    }

    // Cocoa 座標(左下原点)から AX 座標(左上原点)への変換。
    // 式は cocoaRect(fromAXRect:) と同一(この変換は自己逆写像)
    private static func axRect(fromCocoaRect rect: CGRect) -> CGRect {
        cocoaRect(fromAXRect: rect)
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
