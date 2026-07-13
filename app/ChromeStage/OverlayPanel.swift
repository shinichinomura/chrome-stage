import AppKit
import SwiftUI

// フローティングパレット型の Overlay UI(設計メモ 27.3)。
// パネル背景は完全透明で、slot チップ 1 つ 1 つを独立した Liquid Glass
// (NSGlassEffectView)のカプセルとして横に並べる。
//
// SwiftUI の glassEffect は non-activating パネルでは非アクティブ扱いになり
// フラットに描画されるため、ガラスは AppKit 側で描く。

// MARK: - チップの表示内容

struct SlotChipItem: Identifiable {
    let id: UUID
    let index: Int
    let name: String
    let state: SlotState
    let isActive: Bool
}

struct SlotChipView: View {
    let item: SlotChipItem
    let onSelect: () -> Void
    // 空(missing)チップの右クリックから、最前面ウィンドウをこの Slot に割り当てる
    let onAssignFrontmost: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    // アクティブチップの文字色。ライトモードはアクセントティントが薄く見えるため
    // 白では視認性が足りず、黒にする(ダークモードは白)
    private var activeTextColor: Color {
        colorScheme == .dark ? .white : .black
    }

    var body: some View {
        // missing チップは右クリックで割り当てできるようにするため、
        // hit test を潰す .disabled は付けず、左クリックのみ無効化する(onSelect 側で判定)
        if item.state == .missing {
            chipButton.contextMenu {
                Button(action: onAssignFrontmost) {
                    Label("最前面の Chrome ウィンドウをこの Slot に割り当てる",
                          systemImage: "plus.rectangle.on.rectangle")
                }
            }
        } else {
            chipButton
        }
    }

    private var chipButton: some View {
        Button(action: onSelect) {
            // アクティブ: 濃いアクセントカラーのガラスと文字色で区別する
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
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

// MARK: - Panel controller

final class OverlayPanelController {
    private let panel: NSPanel
    private let stage: StageController
    private let stack = NSStackView()
    private var observer: NSObjectProtocol?

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
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }

        let items = currentItems()
        if items.isEmpty {
            addChip(content: Text("Slot 未登録").foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 5))
        } else {
            for item in items {
                let chip = addChip(content: SlotChipView(
                    item: item,
                    onSelect: { [weak self] in
                        // missing チップの左クリックは無効(右クリックで割り当てのみ受け付ける)
                        guard item.state != .missing else { return }
                        self?.stage.switchTo(id: item.id)
                    },
                    onAssignFrontmost: { [weak self] in
                        self?.assignFrontmost(toSlotID: item.id)
                    }
                ))
                if item.isActive {
                    // 完全不透明のアクセントカラー + 白文字。
                    // 半透明だとライトテーマで背景が透けてコントラストが不足する
                    chip.tintColor = .controlAccentColor
                }
            }
        }
        resizeToFit()
    }

    @discardableResult
    private func addChip(content: some View) -> NSGlassEffectView {
        let hosting = NSHostingView(rootView: AnyView(content))
        let size = hosting.fittingSize

        let chip = NSGlassEffectView()
        chip.contentView = hosting
        chip.cornerRadius = size.height / 2 // カプセル形
        chip.translatesAutoresizingMaskIntoConstraints = false
        chip.widthAnchor.constraint(equalToConstant: size.width).isActive = true
        chip.heightAnchor.constraint(equalToConstant: size.height).isActive = true

        stack.addArrangedSubview(chip)
        return chip
    }

    private func resizeToFit() {
        panel.setContentSize(stack.fittingSize)
    }

    // MARK: - 空スロットへの割り当て

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
