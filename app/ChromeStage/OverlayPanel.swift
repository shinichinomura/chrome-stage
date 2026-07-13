import AppKit
import SwiftUI

// フローティングパレット型の Overlay UI(設計メモ 27.3)。
// パネル背景は完全透明で、slot チップ 1 つ 1 つを独立した Liquid Glass
// (NSGlassEffectView)のカプセルとして横に並べる。
//
// SwiftUI の glassEffect は non-activating パネルでは非アクティブ扱いになり
// フラットに描画されるため、ガラスは AppKit 側で描く。
//
// チップの操作(クリック切り替え・ドラッグ並び替え・右クリック割り当て)は
// すべて AppKit 側(ChipView + ジェスチャ)で処理する。SwiftUI は表示専用にし、
// isMovableByWindowBackground によるパネル移動や SwiftUI/AppKit のイベント
// 競合と切り離すことで、クリックとドラッグの判別を確定的にする。

// MARK: - チップの表示内容

struct SlotChipItem: Identifiable {
    let id: UUID
    let index: Int
    let name: String
    let state: SlotState
    let isActive: Bool
}

// チップの見た目のみを担う表示専用ビュー(操作は ChipView が受け持つ)
struct SlotChipContent: View {
    let item: SlotChipItem

    @Environment(\.colorScheme) private var colorScheme

    // アクティブチップの文字色。ライトモードはアクセントティントが薄く見えるため
    // 白では視認性が足りず、黒にする(ダークモードは白)
    private var activeTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        HStack(spacing: 5) {
            Text("\(item.index)")
                .monospacedDigit()
                .foregroundStyle(item.isActive ? activeTextColor.opacity(0.85) : Color.secondary)
            Text(item.name)
                .foregroundStyle(
                    item.isActive ? activeTextColor
                    : item.state == .missing ? Color.secondary
                    : Color.primary
                )
                .lineLimit(1)
            if item.state == .missing {
                Image(systemName: "questionmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        // イベントは AppKit 側(ChipView.hitTest)で受け取るため無効化する
        .allowsHitTesting(false)
    }
}

// MARK: - チップの操作を受け持つガラスビュー

// カプセル内のクリック/ドラッグ/右クリックをすべて自身で受け取る。
// 内部の SwiftUI ホストビューにはイベントを渡さないよう hitTest を固定し、
// パネル背景移動(isMovableByWindowBackground)にも奪われないようにする。
final class ChipView: NSGlassEffectView {
    var slotID: UUID?
    var isMissing = false

    // このカプセル上でのドラッグはパネル移動ではなく並び替えに使う
    override var mouseDownCanMoveWindow: Bool { false }

    // カプセル全体でイベントを受けるため、内部ビューには hit を渡さない
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }
}

// MARK: - Panel controller

final class OverlayPanelController {
    private let panel: NSPanel
    private let stage: StageController
    private let stack = NSStackView()
    private var observer: NSObjectProtocol?

    // ドラッグ並び替え中のチップ
    private var draggingChip: ChipView?

    init(stage: StageController) {
        self.stage = stage

        stack.orientation = .horizontal
        stack.spacing = 6
        // チップの外周に掴んでドラッグできる透明な余白を残す
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 5, bottom: 5, right: 5)

        // borderless + 完全透明。見えるのはチップ(ガラス)だけ
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 36),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        panel.isMovableByWindowBackground = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // ウィンドウ影は輪郭の縁取り線(枠線に見える)も描くためオフにする。
        // 立体感はガラス自体の質感に任せる
        panel.hasShadow = false
        panel.contentView = stack

        // 位置はユーザーが動かした場所を記憶する。初回はメイン画面の右上に出す
        if !panel.setFrameUsingName("OverlayPanel"), let screen = NSScreen.main {
            let visible = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: visible.maxX - 280, y: visible.maxY - 60))
        }
        panel.setFrameAutosaveName("OverlayPanel")

        observer = NotificationCenter.default.addObserver(
            forName: .stageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuildChips()
        }
        rebuildChips()
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
    }

    func hide() {
        panel.orderOut(nil)
    }

    func toggle() {
        isVisible ? hide() : show()
    }

    // MARK: - チップの構築

    private func currentItems() -> [SlotChipItem] {
        stage.slots.enumerated().map { index, slot in
            SlotChipItem(
                id: slot.record.id,
                index: index + 1,
                name: slot.record.displayName,
                state: slot.record.state,
                isActive: slot.record.id == stage.activeSlotID && slot.record.state == .visible
            )
        }
    }

    private func rebuildChips() {
        // ドラッグ中の再構築は状態(draggingChip)を壊すため中断する。
        // ドロップ確定時の再描画は draggingChip が nil に戻ってから届く
        guard draggingChip == nil else { return }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let items = currentItems()
        if items.isEmpty {
            addPlaceholder()
        } else {
            for item in items {
                stack.addArrangedSubview(makeChip(item: item))
            }
        }
        resizeToFit()
    }

    // slot チップ(操作可能)を生成する
    private func makeChip(item: SlotChipItem) -> ChipView {
        let hosting = NSHostingView(rootView: SlotChipContent(item: item))
        let size = hosting.fittingSize

        let chip = ChipView()
        chip.wantsLayer = true
        chip.slotID = item.id
        chip.isMissing = item.state == .missing
        chip.contentView = hosting
        chip.cornerRadius = size.height / 2 // カプセル形
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        chip.heightAnchor.constraint(equalToConstant: size.height).isActive = true

        if item.isActive {
            // 完全不透明のアクセントカラー + 白/黒文字。
            // 半透明だとライトテーマで背景が透けてコントラストが不足する
            chip.tintColor = .controlAccentColor
        }

        // 左クリック: 切り替え(missing は無効)
        let click = NSClickGestureRecognizer(target: self, action: #selector(handleClick(_:)))
        chip.addGestureRecognizer(click)
        // ドラッグ: 並び替え。クリックとはジェスチャ側で自動的に判別される
        // (静止クリックでは pan は発火せず、移動すると click がキャンセルされる)
        let pan = NSPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        chip.addGestureRecognizer(pan)

        // 右クリック: 空(missing)チップにだけ、最前面ウィンドウの割り当てメニューを出す
        if item.state == .missing {
            let menu = NSMenu()
            let assign = NSMenuItem(
                title: "最前面の Chrome ウィンドウをこの Slot に割り当てる",
                action: #selector(assignFrontmostMenu(_:)),
                keyEquivalent: ""
            )
            assign.target = self
            assign.representedObject = item.id
            assign.image = NSImage(
                systemSymbolName: "plus.rectangle.on.rectangle",
                accessibilityDescription: nil
            )
            menu.addItem(assign)
            chip.menu = menu
        }
        return chip
    }

    // 空状態のプレースホルダ(操作なし)
    private func addPlaceholder() {
        let hosting = NSHostingView(rootView: Text("Slot 未登録")
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 5))
        let size = hosting.fittingSize

        let chip = NSGlassEffectView()
        chip.contentView = hosting
        chip.cornerRadius = size.height / 2
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        chip.heightAnchor.constraint(equalToConstant: size.height).isActive = true
        stack.addArrangedSubview(chip)
    }

    private func resizeToFit() {
        panel.setContentSize(stack.fittingSize)
    }

    // MARK: - クリックによる切り替え

    @objc private func handleClick(_ gr: NSClickGestureRecognizer) {
        guard let chip = gr.view as? ChipView, let id = chip.slotID else { return }
        // missing チップの左クリックは無効(右クリックの割り当てのみ受け付ける)
        guard !chip.isMissing else { return }
        stage.switchTo(id: id)
    }

    // MARK: - ドラッグによる並び替え

    @objc private func handlePan(_ gr: NSPanGestureRecognizer) {
        guard let chip = gr.view as? ChipView else { return }
        switch gr.state {
        case .began:
            draggingChip = chip
            chip.layer?.zPosition = 100 // ドラッグ中は隣接チップより前面に描く

        case .changed:
            guard draggingChip === chip else { return }
            let x = gr.location(in: stack).x

            // カーソル位置に応じた挿入先を、他チップの中心 X との前後関係で決める
            let others = stack.arrangedSubviews.filter { $0 !== chip }
            let target = others.filter { $0.frame.midX < x }.count
            let current = stack.arrangedSubviews.firstIndex(of: chip) ?? target
            if target != current {
                // 隣接チップを滑らかに押しのける
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.16
                    ctx.allowsImplicitAnimation = true
                    stack.removeArrangedSubview(chip)
                    stack.insertArrangedSubview(chip, at: target)
                    stack.layoutSubtreeIfNeeded()
                }
            }
            // 現在のスロット位置からの差分だけ平行移動してカーソルに追従させる
            chip.layer?.setAffineTransform(CGAffineTransform(translationX: x - chip.frame.midX, y: 0))

        case .ended, .cancelled:
            guard draggingChip === chip else { return }
            draggingChip = nil
            // スロット位置へスナップして並び順を確定する
            chip.layer?.setAffineTransform(.identity)
            chip.layer?.zPosition = 0
            commitOrder()

        default:
            break
        }
    }

    // 現在のチップの並びを model へ確定する(番号更新のため再描画も走る)
    private func commitOrder() {
        let ids = stack.arrangedSubviews.compactMap { ($0 as? ChipView)?.slotID }
        stage.reorderSlots(orderedIDs: ids)
    }

    // MARK: - 空スロットへの割り当て

    @objc private func assignFrontmostMenu(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        assignFrontmost(toSlotID: id)
    }

    private func assignFrontmost(toSlotID id: UUID) {
        switch stage.assignFrontmostWindow(toSlotID: id) {
        case .success, .slotNotFound:
            // 成功時は stageDidChange で再描画される。slotNotFound は再描画レースのみ
            break
        case .noChromeWindow:
            showAlert("Chrome のウィンドウが見つかりません",
                      "割り当てたい Chrome の通常ウィンドウを最前面にしてから、もう一度お試しください。")
        case .alreadyRegistered:
            showAlert("既に別の Slot に登録されています",
                      "最前面の Chrome ウィンドウは別の Slot が使用中です。割り当てたいウィンドウを最前面にしてからお試しください。")
        case .axMatchFailed:
            showAlert("割り当てに失敗しました",
                      "ウィンドウの照合に失敗しました。もう一度お試しください。")
        }
    }

    private func showAlert(_ message: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}
