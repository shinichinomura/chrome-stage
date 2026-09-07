import AppKit

// メニューバー常駐アプリのエントリポイント。
// LSUIElement = YES のため Dock アイコンは出さず、NSStatusItem のみを表示する。
@main
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var permissionPollTimer: Timer?
    private var stage: StageController!
    private var overlay: OverlayPanelController!
    private var hotKeys: HotKeyController!
    private var sigtermSource: DispatchSourceSignal?

    static func main() {
        // ヘッドレス動作確認モード(UI を起動しない)
        if CommandLine.arguments.contains("--selftest") {
            exit(Selftest.run())
        }
        // バージョン表示(どのビルドかを確認する用)
        if CommandLine.arguments.contains("--version") {
            print(AppVersion.current.details)
            exit(0)
        }

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.app.info("ChromeStage 起動: \(AppVersion.current.summary, privacy: .public)")
        stage = StageController()
        stage.recoverFromCrashIfNeeded()
        setUpStatusItem()
        checkAccessibilityPermission()

        overlay = OverlayPanelController(stage: stage)
        overlay.show()

        hotKeys = HotKeyController { [weak self] action in
            guard let stage = self?.stage else { return }
            switch action {
            case .next: stage.switchNext()
            case .previous: stage.switchPrevious()
            case .direct(let index): stage.switchToIndex(index)
            case .unparkAll: stage.unparkAll()
            }
        }

        // ディスプレイ構成変更(抜き差し・解像度変更)で退避座標を再計算する
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.stage.handleDisplayChange()
        }

        // SIGTERM(pkill 等)でも applicationWillTerminate の復帰処理を通す。
        // これを入れないと、SIGTERM 終了時にウィンドウが画面外に残る
        signal(SIGTERM, SIG_IGN)
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        sigtermSource?.setEventHandler {
            NSApp.terminate(nil)
        }
        sigtermSource?.resume()

        // Chrome 終了検出。
        // 注意: 他アプリが Chrome バイナリを直接 exec して URL を渡すと、同じ bundle ID の
        // 短命プロセス(既存 Chrome へ引き渡して数秒で終了)が生まれ、その終了でも
        // この通知が届く。bundle ID だけで判定すると本体が生きているのに全 slot を
        // 外してしまうため、pid を渡して StageController 側で slot と照合する
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == WindowDiscoveryService.chromeBundleID else { return }
            self?.stage.handleChromeTerminated(pid: app.processIdentifier)
        }

        // Chrome 起動検出: アップデート等で Chrome が再起動すると session restore がウィンドウを
        // 復元する。見失った slot をその座標で再照合し、Stage を組み直す
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == WindowDiscoveryService.chromeBundleID else { return }
            self?.stage.handleChromeLaunched(pid: app.processIdentifier)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 安全機能: 退避中のウィンドウを画面外に取り残さない
        stage?.unparkAll()
        Log.app.info("ChromeStage 終了")
    }

    // MARK: - Status item / メニュー

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(
            systemSymbolName: "square.on.square.dashed",
            accessibilityDescription: "Chrome Stage"
        )
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    // メニューは開くたびに最新の slot 一覧で組み直す
    fileprivate func rebuildMenu(_ menu: NSMenu) {
        menu.removeAllItems()

        if !AccessibilityPermission.isGranted {
            let item = NSMenuItem(
                title: "Accessibility 権限: 未許可(クリックして設定を開く)",
                action: #selector(openAccessibilitySettings),
                keyEquivalent: ""
            )
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // Slot 一覧
        if stage.slots.isEmpty {
            menu.addItem(NSMenuItem(title: "Slot が未登録", action: nil, keyEquivalent: ""))
        } else {
            for (index, slot) in stage.slots.enumerated() {
                let suffix: String
                switch slot.record.state {
                case .visible: suffix = ""
                case .parked: suffix = "(退避中)"
                case .missing: suffix = "(ウィンドウなし)"
                }
                let item = NSMenuItem(
                    title: "\(index + 1). \(slot.record.displayName)\(suffix)",
                    action: slot.record.state == .missing ? nil : #selector(switchToSlot(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = slot.record.id
                item.state = (slot.record.id == stage.activeSlotID && slot.record.state == .visible) ? .on : .off
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let addItem = NSMenuItem(
            title: "最前面の Chrome ウィンドウを Slot に追加…",
            action: #selector(addSlot),
            keyEquivalent: "a"
        )
        addItem.target = self
        menu.addItem(addItem)

        if !stage.slots.isEmpty {
            let removeMenu = NSMenu()
            for (index, slot) in stage.slots.enumerated() {
                let item = NSMenuItem(
                    title: "\(index + 1). \(slot.record.displayName)",
                    action: #selector(removeSlot(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = slot.record.id
                removeMenu.addItem(item)
            }
            let removeParent = NSMenuItem(title: "Slot を削除", action: nil, keyEquivalent: "")
            removeParent.submenu = removeMenu
            menu.addItem(removeParent)
        }

        menu.addItem(.separator())

        let overlayItem = NSMenuItem(
            title: overlay.isVisible ? "Overlay パレットを隠す" : "Overlay パレットを表示",
            action: #selector(toggleOverlay),
            keyEquivalent: "o"
        )
        overlayItem.target = self
        menu.addItem(overlayItem)

        let unparkItem = NSMenuItem(
            title: "Unpark All Chrome Windows",
            action: #selector(unparkAll),
            keyEquivalent: "u"
        )
        unparkItem.target = self
        menu.addItem(unparkItem)

        menu.addItem(.separator())

        // 動作中のビルドを確認できるようにする(差し替え後に古いプロセスが残っていないか等)
        let versionItem = NSMenuItem(
            title: "Chrome Stage \(AppVersion.current.summary)",
            action: #selector(showVersion),
            keyEquivalent: ""
        )
        versionItem.target = self
        menu.addItem(versionItem)

        menu.addItem(
            NSMenuItem(title: "Chrome Stage を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        )
    }

    // バージョン詳細(ビルド日時・起動元パス・プロセスの起動時刻)
    @objc private func showVersion() {
        let app = NSRunningApplication.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "ja_JP")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        let launched = app.launchDate.map { formatter.string(from: $0) } ?? "不明"
        showAlert(
            "Chrome Stage \(AppVersion.current.summary)",
            AppVersion.current.details + "\nプロセス: PID \(app.processIdentifier)(\(launched) 起動)"
        )
    }

    // MARK: - Accessibility 権限

    private func checkAccessibilityPermission() {
        if AccessibilityPermission.isGranted {
            Log.app.info("Accessibility 権限: 許可済み")
            return
        }

        Log.app.info("Accessibility 権限: 未許可。システムダイアログを表示して許可を待つ")
        AccessibilityPermission.requestWithSystemPrompt()

        // 許可はシステム設定側で行われるため、許可されるまでポーリングで検知する
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard AccessibilityPermission.isGranted else { return }
            timer.invalidate()
            self?.permissionPollTimer = nil
            Log.app.info("Accessibility 権限が許可された")
        }
    }

    @objc private func openAccessibilitySettings() {
        AccessibilityPermission.openSystemSettings()
    }

    // MARK: - Slot 操作

    @objc private func addSlot() {
        // ステータスメニューのクリックでは Chrome の Z 順は変わらないため、
        // この時点の最前面 Chrome ウィンドウが「ユーザーが追加したいウィンドウ」
        guard let info = WindowDiscoveryService.frontmostChromeWindow() else {
            showAlert("Chrome のウィンドウが見つかりません", "Google Chrome の通常ウィンドウを開いてから実行してください。")
            return
        }
        if stage.isRegistered(windowID: info.windowID) {
            showAlert("登録済みです", "最前面の Chrome ウィンドウは既に Slot に登録されています。")
            return
        }

        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Slot 名を入力"
        alert.informativeText = "このウィンドウに表示する名前(契約先名など)を入力してください。"
        alert.addButton(withTitle: "追加")
        alert.addButton(withTitle: "キャンセル")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.placeholderString = "例: 契約先A"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        if stage.addSlot(info: info, named: name.isEmpty ? "Slot \(stage.slots.count + 1)" : name) == nil {
            showAlert("Slot 追加に失敗しました", "ウィンドウの照合に失敗しました。もう一度お試しください。")
        }
    }

    @objc private func switchToSlot(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        stage.switchTo(id: id)
    }

    @objc private func removeSlot(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        stage.removeSlot(id: id)
    }

    // 安全機能の要。アプリが異常終了しても手動で全ウィンドウを画面内へ戻せるようにする。
    @objc private func unparkAll() {
        stage.unparkAll()
    }

    @objc private func toggleOverlay() {
        overlay.toggle()
    }

    private func showAlert(_ message: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildMenu(menu)
    }
}
