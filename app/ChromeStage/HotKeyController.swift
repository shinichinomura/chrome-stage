import Carbon.HIToolbox
import Foundation

// グローバルホットキー。Carbon RegisterEventHotKey の薄いラッパー(外部依存なしの方針)。
//
// 割り当て(BACKLOG の決定事項):
//   Ctrl+Option+Tab       : 次の slot
//   Ctrl+Option+Shift+Tab : 前の slot
//   Ctrl+Option+1〜9      : 直接切り替え
//   Ctrl+Option+U         : Unpark All
// Chrome 自身の Ctrl+Tab(タブ切り替え)と衝突しないよう Option を併用する。
final class HotKeyController {
    enum Action {
        case next
        case previous
        case direct(Int) // 1〜9
        case unparkAll
    }

    private let onAction: (Action) -> Void
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var eventHandler: EventHandlerRef?

    // EventHotKeyID.id → Action の対応
    private static let nextID: UInt32 = 1
    private static let previousID: UInt32 = 2
    private static let directIDBase: UInt32 = 10 // 10〜18 が slot 1〜9
    private static let unparkAllID: UInt32 = 30

    private static let signature: OSType = 0x43535447 // "CSTG"

    init(onAction: @escaping (Action) -> Void) {
        self.onAction = onAction
        installHandler()
        registerAll()
    }

    deinit {
        for ref in hotKeyRefs { UnregisterEventHotKey(ref) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    private func installHandler() {
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                Unmanaged<HotKeyController>.fromOpaque(userData)
                    .takeUnretainedValue()
                    .handle(id: hotKeyID.id)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        if status != noErr {
            Log.app.error("ホットキーのイベントハンドラ登録に失敗: \(status)")
        }
    }

    private func registerAll() {
        let ctrlOpt = UInt32(controlKey | optionKey)

        register(keyCode: UInt32(kVK_Tab), modifiers: ctrlOpt, id: Self.nextID)
        register(keyCode: UInt32(kVK_Tab), modifiers: ctrlOpt | UInt32(shiftKey), id: Self.previousID)
        register(keyCode: UInt32(kVK_ANSI_U), modifiers: ctrlOpt, id: Self.unparkAllID)

        let digitKeyCodes: [UInt32] = [
            UInt32(kVK_ANSI_1), UInt32(kVK_ANSI_2), UInt32(kVK_ANSI_3),
            UInt32(kVK_ANSI_4), UInt32(kVK_ANSI_5), UInt32(kVK_ANSI_6),
            UInt32(kVK_ANSI_7), UInt32(kVK_ANSI_8), UInt32(kVK_ANSI_9),
        ]
        for (offset, keyCode) in digitKeyCodes.enumerated() {
            register(keyCode: keyCode, modifiers: ctrlOpt, id: Self.directIDBase + UInt32(offset))
        }
        Log.app.info("ホットキー登録完了: \(self.hotKeyRefs.count) 件")
    }

    private func register(keyCode: UInt32, modifiers: UInt32, id: UInt32) {
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: Self.signature, id: id),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            hotKeyRefs.append(ref)
        } else {
            // 他アプリが同じキーを登録済みの場合など
            Log.app.error("ホットキー登録失敗 (id \(id)): status \(status)")
        }
    }

    private func handle(id: UInt32) {
        switch id {
        case Self.nextID:
            onAction(.next)
        case Self.previousID:
            onAction(.previous)
        case Self.unparkAllID:
            onAction(.unparkAll)
        case Self.directIDBase...(Self.directIDBase + 8):
            onAction(.direct(Int(id - Self.directIDBase) + 1))
        default:
            break
        }
    }
}
