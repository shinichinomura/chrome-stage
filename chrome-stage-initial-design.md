# Chrome Stage: Chromeプロファイル別ウィンドウを外側からラップするアプリ設計メモ

作成日: 2026-07-03  
対象環境: macOS / Google Chrome  
目的: 複数契約先ごとに分けたChromeプロファイルのウィンドウを、Chrome本来の使い勝手を壊さず、1つの作業ステージ内で切り替えて扱えるようにする。

---

## 1. 背景

複数の契約先案件をAIや各種SaaSを使いながら並行して進める場合、契約先ごとにChromeプロファイルを分ける運用は有効である。

Chromeプロファイルを分けることで、次の情報を契約先単位で分離できる。

- Cookie / ログイン状態
- ブックマーク
- 履歴
- 拡張機能の状態
- Googleアカウント
- 各種SaaSのセッション
- AIツールへのログイン状態

一方で、契約先ごとにChromeプロファイルを開くと、Chromeウィンドウが大量に増え、Mission Control、Dock、ウィンドウ切り替え、画面配置が煩雑になる。

当初の改善案としては、次のようなものがあった。

- Chromeタブグループで作業単位を整理する
- RaycastでChromeプロファイルを素早く開く
- Veljaで外部リンクを正しいChromeプロファイルへ振り分ける
- macOS Spacesで契約先ごとに作業面を分ける
- Arc / Wavebox / Stack Browserなどの代替ブラウザを使う
- Stackerで複数ブラウザウィンドウを1つの束として扱う

このうち、今回の要件に最も近かったのは **Stacker** である。

---

## 2. Stackerが満たしていた要件

Stackerの良かった点は、Chromeを置き換えないこと。

つまり、

- Chromeのプロファイルはそのまま
- DockのChromeアイコンを右クリックしてプロファイルを選べる
- Chrome標準のプロファイル管理を維持できる
- DevToolsやChrome拡張機能の挙動を壊さない
- 既存のChromeウィンドウを外側から束ねるだけ
- ブラウザのセッション管理や起動管理を自作アプリが奪わない

という思想が今回の用途に合っている。

この方向性は維持する。

---

## 3. Stackerで問題になった点

実際に使ってみた結果、以下の問題があった。

### 3.1 致命的な問題

#### プロファイル名が切り替えUIに表示されない

契約先ごとのChromeプロファイルを並行利用する場合、切り替えUIには必ず次のようなラベルが必要。

- `Client A`
- `Client B`
- `自社`
- `研究`
- `経理`
- `採用`
- `契約先名`

ChromeウィンドウタイトルやmacOSのAccessibility情報だけでは、対象ウィンドウがどのChromeプロファイルに属するかを安定的に取得できない可能性が高い。

### 3.2 軽微だが気になる問題

#### ドロップシャドウが濃くなる

Stackerは複数のChromeウィンドウを同じ位置に物理的に重ねていると見られる。

その場合、非アクティブウィンドウの影も合成されるため、見た目としてウィンドウ外周のドロップシャドウが濃く感じられる。

#### ウィンドウ移動がもたつく

複数のChromeウィンドウを同一座標に保つ場合、表示中のウィンドウ移動に合わせて、非表示のウィンドウもAccessibility API経由で追従させる必要がある。

Accessibility API経由のウィンドウ操作はプロセス間通信を伴うため、対象ウィンドウ数が増えるほど移動・リサイズの体感が悪くなる。

---

## 4. 自作アプリの基本方針

自作アプリは、Stackerの「外側からラップするだけ」という思想を維持しつつ、物理的にウィンドウを重ねる方式は採用しない。

推奨方針は **Chrome Stage方式**。

> Chromeウィンドウは本物のChromeウィンドウのまま保持する。  
> ただし画面上には、原則としてアクティブなChromeウィンドウを1つだけ表示する。  
> 非アクティブな契約先プロファイルのウィンドウは画面外へ退避させる。  
> 自作アプリは、切り替えUI、プロファイル名表示、ウィンドウ制御だけを担当する。

---

## 5. 目標

### 5.1 プロダクト上の目標

- 複数のChromeプロファイルウィンドウを1つの作業単位として扱う
- 契約先名 / プロファイル名を明示した切り替えUIを提供する
- Chrome本体の操作感を壊さない
- DockのChromeアイコンやChrome標準プロファイル操作を維持する
- DevTools、Chrome拡張機能、認証フローを壊さない
- Stackerよりも影が自然で、移動が軽い体験にする

### 5.2 技術上の目標

- Chromeウィンドウを自作アプリに埋め込まない
- 他プロセスのChromeウィンドウを外部制御する
- 表示中のChromeウィンドウのみをステージ上に配置する
- 非アクティブウィンドウはoffscreen parkingする
- 切り替えUIはNSPanel / SwiftUIなどでChromeウィンドウに追従させる
- プロファイル名は手動マッピングから始め、最終的にはChrome拡張 + Native Messagingで自動化する

---

## 6. 非目標

このアプリでは、以下はやらない。

- 独自ブラウザを作る
- ChromeをWebViewで再実装する
- Chromeプロファイル管理そのものを置き換える
- Chromeセッション復元を自作する
- ChromeのDockメニューを再実装する
- 契約先ごとの独自Chromeアプリを複製する
- 他プロセスのChromeウィンドウを自作アプリのNSViewに本当に埋め込む
- すべてのChromeウィンドウを常に同期移動する

---

## 7. なぜChromeを本当に埋め込まないのか

macOSの公開APIだけで、他プロセスであるChromeの既存ウィンドウを、自作アプリの `NSWindow` / `NSView` の子として安定的に埋め込む設計は現実的ではない。

AppKitには子ウィンドウAPIがあるが、これは基本的に自プロセスの `NSWindow` 同士を扱うためのもの。Chromeの既存ウィンドウは、こちらからはCoreGraphicsやAccessibility経由で観測・操作できるだけで、ビュー階層として取り込めるわけではない。

ScreenCaptureKitを使えばChromeウィンドウの映像を自作アプリ内にライブプレビュー表示することは可能。ただし、これはあくまで映像であり、クリック、キーボード入力、ドラッグ、IME、DevTools、コンテキストメニュー、ファイルドロップなどを自然に透過させるには入力イベントの転送が必要になる。

その結果、以下の問題が起きやすい。

- フォーカス管理が壊れる
- キーボードショートカットが壊れる
- IME入力が不安定になる
- ドラッグ&ドロップが壊れる
- コンテキストメニューが不自然になる
- DevToolsやOAuthポップアップへの対応が複雑化する
- セキュリティ権限が過剰になる

したがって、本物の埋め込みではなく、**埋め込まれているように見える外部制御** を狙う。

---

## 8. 推奨アーキテクチャ概要

```text
┌────────────────────────────────────────────┐
│ Chrome Stage.app                            │
│                                            │
│  ┌──────────────────────────────────────┐  │
│  │ Overlay / Switcher UI                │  │
│  │ - 契約先名 / プロファイル名           │  │
│  │ - ショートカット                     │  │
│  │ - 状態表示                           │  │
│  │ - optional: サムネイル                │  │
│  └──────────────────────────────────────┘  │
│                                            │
│  Window Discovery                         │
│  - CGWindowListCopyWindowInfo             │
│  - NSWorkspace notifications              │
│  - AXUIElement                            │
│                                            │
│  Window Controller                        │
│  - focus                                  │
│  - move                                   │
│  - resize                                 │
│  - park                                   │
│  - restore                                │
│                                            │
│  Profile Registry                         │
│  - manual mapping                         │
│  - Chrome Local State                     │
│  - optional companion extension           │
│                                            │
│  Stage Session Store                      │
│  - slots                                  │
│  - active slot                            │
│  - last visible rect                      │
│  - parking rects                          │
│  - recovery state                         │
└────────────────────────────────────────────┘
                │
                ▼
┌────────────────────────────────────────────┐
│ 本物の Google Chrome                       │
│                                            │
│  Window A: 契約先A Profile                 │
│  Window B: 契約先B Profile                 │
│  Window C: 契約先C Profile                 │
│                                            │
│  ※画面上には原則1つだけ表示                │
└────────────────────────────────────────────┘
```

---

## 9. Stacker方式とChrome Stage方式の違い

### 9.1 Stacker的な物理スタック

```text
[Chrome: 契約先A]  ← 表示
[Chrome: 契約先B]  ← 同じ位置に重なっている
[Chrome: 契約先C]  ← 同じ位置に重なっている
```

問題:

- ドロップシャドウが重なる
- ウィンドウ移動時に複数ウィンドウを同期する必要がある
- ウィンドウ数が増えるほどもたつく
- プロファイル名は別途取得・表示が必要

### 9.2 推奨するStage方式

```text
画面上のステージ:
[Chrome: 契約先A]  ← 表示中

退避領域:
[Chrome: 契約先B]  ← offscreen parking
[Chrome: 契約先C]  ← offscreen parking
```

利点:

- 画面上のChromeウィンドウは1枚だけ
- ドロップシャドウが重ならない
- 移動中に複数ウィンドウを同期しなくてよい
- 非アクティブウィンドウは次に表示する瞬間だけ復帰すればよい
- Overlay UIにプロファイル名を自由に表示できる

---

## 10. 中核コンセプト: Stage / Slot

### Stage

現在の作業領域。

- 位置
- サイズ
- 対象ディスプレイ
- 対象Space
- 表示中slot
- Overlay UIの位置

を持つ。

### Slot

1つのChromeプロファイルウィンドウに対応する論理単位。

例:

```text
Slot 1: 契約先A
Slot 2: 契約先B
Slot 3: 自社
Slot 4: 研究
```

Slotは以下の情報を持つ。

```swift
struct ChromeSlot {
    let id: UUID

    var displayName: String        // "契約先A"
    var profileKey: String?        // "client-a"
    var chromeProfileDir: String?  // "Profile 1"
    var color: NSColor?
    var shortcutIndex: Int?

    var window: ChromeWindowRef
    var state: SlotState

    var lastVisibleRect: CGRect?
    var parkingRect: CGRect?
    var createdAt: Date
    var updatedAt: Date
}
```

SlotState例:

```swift
enum SlotState {
    case visible
    case parked
    case minimized
    case missing
    case closed
    case unknown
}
```

---

## 11. 非アクティブウィンドウの退避方式

候補は3つ。

| 方式 | 内容 | メリット | デメリット |
|---|---|---|---|
| Offscreen parking | 非アクティブウィンドウを画面外座標へ移動 | 復帰が速い。Dockに最小化サムネイルが増えない。影が消える | Mission ControlやCmd+`で迷子感が出る可能性 |
| Minimize parking | 非アクティブウィンドウを最小化 | macOS的に自然。画面外ウィンドウを作らない | Dockが散らかる。復帰がやや遅い |
| Behind-stage parking | 非アクティブウィンドウを背面に置く | 画面外に飛ばさない | 影や重なり問題が残りやすい |

### 推奨

初期実装は **Offscreen parking**。

理由:

- Stackerで不満だったドロップシャドウ問題を根本的に解消できる
- 非アクティブウィンドウを同期移動しなくてよい
- 切り替え時の復帰が速い
- 最小化によるDockの散らかりを避けられる

必須の安全機能:

- メニューバーまたはホットキーで `Unpark All Chrome Windows`
- アプリ終了時に可能な限り全ウィンドウを復帰
- クラッシュ後の復旧メニュー
- ディスプレイ構成変更時の退避座標再計算

---

## 12. 切り替え処理

基本処理は以下。

```swift
func switchTo(slot target: ChromeSlot) {
    let stageRect = currentStageRect()

    // 1. 現在の表示ウィンドウを保存して退避
    if let current = activeSlot {
        current.lastVisibleRect = readWindowRect(current.window)
        park(current.window)
        current.state = .parked
    }

    // 2. ターゲットをステージへ復帰
    restore(target.window, to: stageRect)

    // 3. Chromeウィンドウを前面化
    focus(target.window)

    // 4. UI状態を更新
    activeSlot = target
    overlay.update(
        activeProfileName: target.displayName,
        activeColor: target.color,
        slots: allSlots
    )
}
```

Offscreen parking例:

```swift
func park(_ window: ChromeWindowRef) {
    let parkingRect = CGRect(
        x: -20000,
        y: 100,
        width: 1200,
        height: 800
    )

    axSetPosition(window, parkingRect.origin)
    axSetSize(window, parkingRect.size)
}
```

復帰例:

```swift
func restore(_ window: ChromeWindowRef, to rect: CGRect) {
    axSetPosition(window, rect.origin)
    axSetSize(window, rect.size)
    axRaise(window)
}
```

---

## 13. ウィンドウ移動・リサイズ時の考え方

Stacker的な同期方式では、表示中ウィンドウの移動に合わせて他のウィンドウも追従させる必要がある。

Chrome Stage方式では、移動中に追従させる対象を最小化する。

方針:

- 表示中のChromeウィンドウだけをユーザーが移動・リサイズする
- Overlay UIだけが追従する
- 退避中のウィンドウは移動しない
- 移動・リサイズ完了後に `stageRect` を保存する
- 非アクティブウィンドウは、次に表示される瞬間だけ `stageRect` に復帰する

これにより、ウィンドウ数が増えても操作の重さが増えにくい。

---

## 14. Overlay UI設計

UIは、Chromeウィンドウに薄いサイドバーや上部バーが付いているように見せる。

例:

```text
┌──────────────────────────────────────────────┐
│ Chrome Stage                                 │
├───────┬──────────────────────────────────────┤
│ A     │                                      │
│ B     │        本物のChromeウィンドウ         │
│ C     │                                      │
│ +     │                                      │
└───────┴──────────────────────────────────────┘
```

実体は以下。

```text
[Overlay NSPanel]  ← 自作アプリ
[Chrome Window]   ← 本物のChrome
```

Overlayに表示するもの:

- 現在のプロファイル名
- Slot一覧
- 契約先ごとの色
- ショートカット番号
- アクティブ状態
- 任意: サムネイル
- 任意: 未読/注意状態

操作例:

- `Ctrl+1`〜`Ctrl+9`: 直接切り替え
- `Ctrl+Tab`: 次のslot
- `Ctrl+Shift+Tab`: 前のslot
- クリック: slot切り替え
- 右クリック: rename / remove / unpark / reveal / assign profile

Overlay実装上の注意:

- Chromeの操作を邪魔しない
- クリック時のみ自作アプリが受け取り、切り替え後すぐChromeへfocusを戻す
- non-activating panelに近い挙動を目指す
- サムネイルを使う場合はScreen Recording権限が必要になるため、MVPではなしでよい

---

## 15. プロファイル名取得の設計

プロファイル名表示はこのアプリの重要機能。

ChromeウィンドウタイトルやmacOS Accessibility情報だけでは、どのChromeプロファイルのウィンドウかを安定的に判別しづらい。

したがって、段階的に実装する。

---

### 15.1 Level 1: 手動マッピング

MVPでは手動マッピングでよい。

流れ:

1. Google Chromeの通常ウィンドウを一覧表示
2. 各ウィンドウのタイトル、位置、サイズなどを表示
3. ユーザーが「これは契約先A」「これは契約先B」と割り当てる
4. 以後、ウィンドウが生きている間はそのラベルを表示する

メリット:

- 実装が簡単
- Chrome拡張不要
- 権限が少ない
- 最短で使える

デメリット:

- Chrome再起動後の復元に弱い
- 新規ウィンドウの自動認識が弱い
- ユーザー操作が必要

---

### 15.2 Level 2: Chrome Local Stateを読む

Chromeのユーザーデータ配下の `Local State` には、プロファイル一覧や表示名に相当する情報が含まれる。

macOSでの典型的なパス:

```text
~/Library/Application Support/Google/Chrome/Local State
```

概念例:

```json
{
  "profile": {
    "info_cache": {
      "Default": {
        "name": "Default"
      },
      "Profile 1": {
        "name": "Client A"
      },
      "Profile 2": {
        "name": "Client B"
      }
    }
  }
}
```

この情報から、UI上の候補名を作れる。

ただし、`Local State` は「プロファイル一覧」を得るためのものであり、**このmacOSウィンドウがどのプロファイルか** を直接教えてくれるものではない。

使い方:

- Slotに割り当てるラベル候補として使う
- Chrome Profile directoryと表示名の辞書を作る
- 手動マッピングUIの候補に出す
- 将来のCompanion Extensionと組み合わせる

---

### 15.3 Level 3: Chrome Companion Extension + Native Messaging

最終的には、各Chromeプロファイルに小さな拡張機能を入れるのが最も安定する。

構成:

```text
Chrome Profile A
  └─ Companion Extension
       ├─ chrome.windows events
       ├─ profile label: "契約先A"
       └─ Native Messaging

Chrome Profile B
  └─ Companion Extension
       ├─ chrome.windows events
       ├─ profile label: "契約先B"
       └─ Native Messaging

Native Messaging Host
  └─ Main Appへイベント転送

Chrome Stage.app
  ├─ window registry
  ├─ profile labels
  └─ stage switching
```

拡張機能側で各プロファイルに自分のラベルを持たせる。

初回設定:

- 各プロファイルで拡張機能のOptionsを開く
- `profileLabel = "契約先A"` のように設定
- `chrome.storage.local` に保存
- 以後、拡張機能が送るイベントに常に `profileLabel` を付ける

送信するイベント例:

```json
{
  "type": "windowSnapshot",
  "profileLabel": "契約先A",
  "profileKey": "client-a",
  "windows": [
    {
      "chromeWindowId": 123,
      "focused": true,
      "state": "normal",
      "left": 100,
      "top": 80,
      "width": 1440,
      "height": 900
    }
  ]
}
```

---

## 16. macOSウィンドウとChrome windowIdの対応付け

Chrome拡張側の `chrome.windows.Window.id` と、macOS側の `CGWindowID` / `AXUIElement` は別物。

対応付けが必要。

突き合わせに使える情報:

| Chrome拡張側 | macOS側 |
|---|---|
| `chrome.windows.Window.id` | `CGWindowID` |
| `left/top/width/height` | `kCGWindowBounds` / AX position / AX size |
| `focused` | frontmost AX window |
| active tab title | Chrome window title |
| window state | minimized / normal / fullscreen |
| profile label | Slot label |

方針:

- MVPでは対応付けを手動で済ませる
- Phase 3で拡張機能から座標・フォーカス状態を受け取り、自動照合する
- 照合に失敗した場合はユーザーへ確認UIを出す
- `chromeWindowId` は永続IDとして扱わず、Chrome起動中の一時IDとして扱う

機密性を重視する場合:

- `tabs` permissionは最初は付けない
- URLやタイトルを送らない
- 位置・サイズ・フォーカス状態だけで対応付ける
- 不足する場合のみ、オプションでタイトル取得を許可する

---

## 17. Companion Extensionの最小設計

Manifest V3の最小例。

```json
{
  "manifest_version": 3,
  "name": "Chrome Stage Companion",
  "version": "0.1.0",
  "permissions": ["windows", "nativeMessaging", "storage"],
  "background": {
    "service_worker": "background.js"
  },
  "options_page": "options.html"
}
```

URLやタブタイトルまで使う場合のみ、`tabs` permissionを追加する。

ただし、契約先の機密情報を扱う可能性があるため、初期版では `tabs` permissionなしを推奨。

背景Service Workerの概念例:

```javascript
async function getProfileLabel() {
  const result = await chrome.storage.local.get(["profileLabel", "profileKey"]);
  return {
    profileLabel: result.profileLabel || "Unnamed Profile",
    profileKey: result.profileKey || null
  };
}

async function reportAll() {
  const profile = await getProfileLabel();
  const windows = await chrome.windows.getAll();

  sendNative({
    type: "windowSnapshot",
    ...profile,
    windows: windows.map(w => ({
      chromeWindowId: w.id,
      focused: w.focused,
      state: w.state,
      left: w.left,
      top: w.top,
      width: w.width,
      height: w.height,
      type: w.type
    }))
  });
}

chrome.windows.onCreated.addListener(reportAll);
chrome.windows.onRemoved.addListener(windowId => {
  sendNative({ type: "windowRemoved", chromeWindowId: windowId });
});
chrome.windows.onFocusChanged.addListener(reportAll);
chrome.windows.onBoundsChanged.addListener(reportAll);
```

---

## 18. Native Messaging Host

Chrome拡張とmacOSアプリの橋渡し。

Chrome拡張はNative Messaging Hostを標準入出力で起動する。

想定構成:

```text
Chrome Extension
  ↓ Native Messaging
Native Messaging Host
  ↓ local socket / XPC / distributed notification / stdio relay
Chrome Stage.app
```

開発初期は、Native Messaging Host自体をメインアプリの補助バイナリとして作るとよい。

注意点:

- Native Messaging Host manifestの配置が必要
- Chrome拡張IDとの紐付けが必要
- 配布時は署名・notarization・インストール手順が必要
- 拡張機能をWeb Store以外で配布する場合の制約を確認する必要がある

---

## 19. macOS側モジュール構成案

Swift / AppKitを想定。

```text
ChromeStage.app
├─ AppCoordinator
│  └─ 起動、権限確認、全体状態管理
│
├─ WindowDiscoveryService
│  ├─ CGWindowListCopyWindowInfo
│  ├─ NSWorkspace notifications
│  ├─ Chrome PID / bundle id filtering
│  └─ Window list diffing
│
├─ AXWindowController
│  ├─ read position / size
│  ├─ set position / size
│  ├─ focus / raise
│  ├─ minimize / restore
│  ├─ AXObserver
│  └─ permission check
│
├─ ChromeBridge
│  ├─ Native Messaging host receiver
│  ├─ extension event receiver
│  ├─ chromeWindowId ↔ CGWindowID matcher
│  └─ profile label receiver
│
├─ ProfileRegistry
│  ├─ parse Chrome Local State
│  ├─ profile directory → display name
│  ├─ manual aliases
│  ├─ profile colors
│  └─ persisted mapping
│
├─ StageSessionStore
│  ├─ slots
│  ├─ active slot
│  ├─ last visible rect
│  ├─ parking rects
│  ├─ display identifier
│  ├─ space-awareness optional
│  └─ crash recovery state
│
├─ OverlayRuntime
│  ├─ NSPanel / SwiftUI view
│  ├─ slot switcher
│  ├─ labels
│  ├─ context menus
│  └─ optional thumbnails
│
├─ HotKeyController
│  ├─ next / previous profile
│  ├─ direct jump 1-9
│  ├─ show switcher
│  └─ unpark all
│
└─ RecoveryController
   ├─ restore parked windows
   ├─ handle display changes
   ├─ handle Chrome quit
   └─ handle app termination
```

---

## 20. 権限設計

### 必須になりそうな権限

#### Accessibility

用途:

- Chromeウィンドウの位置取得
- Chromeウィンドウの移動
- Chromeウィンドウのリサイズ
- Chromeウィンドウの前面化
- ウィンドウの最小化/復帰
- ウィンドウイベント監視

このアプリの中核機能にはほぼ必須。

### オプション権限

#### Screen Recording

用途:

- サムネイル表示
- ライブプレビュー
- 切り替えUI内のプレビュー

ただし、契約先の機密情報を扱う前提では、MVPでは使わないほうがよい。

### Chrome拡張権限

最小:

- `windows`
- `nativeMessaging`
- `storage`

オプション:

- `tabs`

`tabs` はURLやタイトルにアクセスできるため、必要になるまで入れない。

---

## 21. エッジケース

### 21.1 Fullscreen Chrome

macOSのFullscreenは専用Spaceに入るため、Stage方式との相性が悪い。

推奨:

- FullscreenのChromeウィンドウはStage対象外
- またはStageへ追加する前にFullscreen解除を促す
- 初期版では非対応でよい

### 21.2 DevTools

DevToolsは別ウィンドウとして開くことがある。

推奨:

- MVPではDevToolsをStage対象外にする
- Chrome本体ウィンドウだけslot化する
- 将来、slot内のsecondary windowとして扱う余地を残す

### 21.3 OAuth / Popup / 認証ウィンドウ

GoogleログインやOAuthではpopupウィンドウが出る。

推奨:

- 通常のChrome browser windowだけStage対象
- popup typeはStageに自動吸収しない
- OAuth popupはユーザー操作に任せる

### 21.4 1プロファイルに複数ウィンドウ

同じChromeプロファイルで複数ウィンドウが開く可能性がある。

設計案:

```text
slot: 契約先A
  primary window
  secondary windows
```

MVPでは:

- 1 slot = 1 primary window
- 同一プロファイルの2枚目以降はStage対象外
- またはユーザーが明示的に別slotとして追加する

将来的には:

- 1 profile = 1 slot
- slot内に複数windowをぶら下げる
- 切り替えUIではprofile単位で表示する

### 21.5 Chrome終了

Chromeが終了した場合:

- slotは `missing` または `closed` にする
- Overlayから除外する
- 次回Chrome起動後、自動または手動で再割り当てする

### 21.6 ディスプレイ抜き差し

offscreen parking中にディスプレイ構成が変わると、ウィンドウ復帰位置が不正になる可能性がある。

必須対応:

- display configuration changeを検出
- `Unpark All` を自動または半自動で実行
- parking rectを再計算
- stage rectが存在しないディスプレイ上ならメインディスプレイへ移動

### 21.7 Spaces

macOS Spacesは外部アプリから完全制御しづらい。

MVP方針:

- 同一Space内での利用を前提にする
- Stageは現在のSpaceにあるChromeウィンドウを対象にする
- Spaces横断の自動制御は後回し

---

## 22. データモデル案

```swift
struct StageSession: Codable {
    var id: UUID
    var name: String

    var activeSlotId: UUID?
    var stageRect: CodableRect
    var displayId: String?

    var slots: [ChromeSlotRecord]
    var createdAt: Date
    var updatedAt: Date
}

struct ChromeSlotRecord: Codable {
    var id: UUID

    var displayName: String
    var profileKey: String?
    var chromeProfileDir: String?
    var colorHex: String?
    var shortcutIndex: Int?

    var macWindowId: UInt32?
    var chromeWindowId: Int?
    var chromePid: Int32?

    var lastVisibleRect: CodableRect?
    var parkingRect: CodableRect?

    var state: String
    var createdAt: Date
    var updatedAt: Date
}
```

---

## 23. MVPスコープ

最初に作るべきもの。

### Phase 1: AX-only Stage

目的:

- Stackerの「影が濃い」「移動がもたつく」を解消する
- プロファイル名は手動入力でよい
- Chromeを外側からラップする体験を検証する

実装内容:

- Chrome通常ウィンドウの検出
- 手動でslotに追加
- slot名の手動設定
- 表示中slotだけstage rectに配置
- 非表示slotはoffscreen parking
- Overlayにslot名を表示
- ホットキーでslot切り替え
- `Unpark All` 実装
- アプリ終了時に全ウィンドウ復帰

この段階では以下をやらない:

- Chrome拡張
- Native Messaging
- サムネイル
- Spaces横断対応
- 複数ウィンドウ/プロファイルの完全対応
- URL/タブタイトル取得

---

## 24. Phase 2: Profile Registry

目的:

- 手動ラベル入力を楽にする
- Chromeの既存プロファイル名を候補として使う

実装内容:

- `~/Library/Application Support/Google/Chrome/Local State` を読む
- `profile.info_cache` からプロファイル名候補を抽出
- Slot割り当てUIに候補として表示
- profile color / icon / aliasを保存
- 再起動後もslot名を復元

---

## 25. Phase 3: Companion Extension

目的:

- ChromeウィンドウとChromeプロファイルの対応を自動化する
- Chrome再起動後の復元精度を上げる
- 新規プロファイルウィンドウを自動認識する

実装内容:

- Chrome Extensionを作る
- 各プロファイルでprofile labelを保存
- `chrome.windows` APIでウィンドウイベントを監視
- Native MessagingでmacOS側へ送信
- macOS側でCGWindow/AXWindowと照合
- 新規Chromeウィンドウを自動slot化

---

## 26. Phase 4: Polish

目的:

- 日常利用の品質を上げる

候補:

- ScreenCaptureKitによるslotサムネイル
- Raycast連携
- CLI連携
- メニューバーアプリ化
- ショートカットカスタマイズ
- slot並べ替え
- 検索型switcher
- 契約先ごとの色・アイコン
- 複数Stage対応
- Stage保存/復元
- アプリ署名・notarization
- 自動アップデート

---

## 27. UI案

### 27.1 サイドバー型

```text
┌───────┬──────────────────────────────────────┐
│ A     │                                      │
│ B     │              Chrome                  │
│ C     │                                      │
│ +     │                                      │
└───────┴──────────────────────────────────────┘
```

利点:

- 常時プロファイルが見える
- クリック切り替えしやすい
- 契約先色を出しやすい

欠点:

- Chromeの表示領域を少し圧迫する
- Chrome本体の左端UIと干渉する可能性

### 27.2 上部バー型

```text
┌──────────────────────────────────────────────┐
│ [A] [B] [C] [+]        Current: 契約先A       │
├──────────────────────────────────────────────┤
│                  Chrome                      │
└──────────────────────────────────────────────┘
```

利点:

- ブラウザのタブバーに近い
- 視線移動が自然

欠点:

- Chrome本体のタイトルバー/ツールバーと視覚的に競合しやすい
- 高さを取る

### 27.3 フローティングパレット型

```text
┌────────────────────────────┐
│ 1 契約先A                  │
│ 2 契約先B                  │
│ 3 自社                     │
└────────────────────────────┘
```

利点:

- Chromeの表示領域を圧迫しない
- Stackerに近い
- 実装が比較的簡単

欠点:

- 常時表示すると邪魔になる可能性
- 視認性はサイドバー型に劣る

### MVP推奨

最初は **フローティングパレット型**。

理由:

- Chromeウィンドウ本体のサイズや表示領域に干渉しにくい
- Overlay UI単体で検証しやすい
- Stackerの体験に近い
- 後でサイドバー型へ拡張できる

---

## 28. ホットキー案

| 操作 | 初期ショートカット案 |
|---|---|
| 次のslot | `Control + Tab` |
| 前のslot | `Control + Shift + Tab` |
| slot 1 | `Control + 1` |
| slot 2 | `Control + 2` |
| slot 3 | `Control + 3` |
| switcher表示 | `Control + Space` |
| 現在のChromeウィンドウをslot追加 | `Control + Option + A` |
| 全ウィンドウ復帰 | `Control + Option + U` |

注意:

- ChromeやmacOS標準ショートカットと衝突しないよう調整が必要
- ユーザー設定可能にする
- まずは最小限でよい

---

## 29. 実装リスク

### 29.1 AX操作の不安定性

Accessibility API経由の外部ウィンドウ操作は、アプリやmacOSバージョンによって挙動差がある。

対策:

- AX操作を薄くラップする
- 失敗時はリトライする
- 操作後に実際の位置・サイズを読み直して検証する
- 失敗時はUIで警告する

### 29.2 offscreen parkingの迷子化

アプリが落ちると、Chromeウィンドウが画面外に残る可能性がある。

対策:

- `Unpark All` を必ず実装
- 起動時に前回parkingしたウィンドウを復帰
- アプリ終了時に復帰
- クラッシュ対策としてparking rectを記録
- メニューバーから復旧できるようにする

### 29.3 Chromeアップデート

ChromeのUIやウィンドウ挙動は変わる可能性がある。

対策:

- 可能な限りChrome UIの内部構造に依存しない
- タイトルバーのAX階層を深追いしない
- 最終的にはCompanion Extension側で情報を得る
- MVPでは手動マッピングを主軸にする

### 29.4 セキュリティ・機密情報

契約先の情報を扱うため、URLやページタイトルの取得は慎重にする。

対策:

- MVPではURL/タイトルを保存しない
- `tabs` permissionは付けない
- サムネイルはデフォルト無効
- 設定ファイルにはプロファイル名とウィンドウID程度だけ保存
- ログにURLやタイトルを出さない

---

## 30. 実装開始タスク

### 30.1 リポジトリ初期化

- Swift / AppKitプロジェクトを作成
- メニューバー常駐または通常アプリとして起動
- 設定保存先を決める
- ログ基盤を入れる

### 30.2 Accessibility権限チェック

- 権限状態を確認
- 未許可なら案内UIを出す
- 権限許可後に再チェックできるようにする

### 30.3 Chromeウィンドウ検出

- `CGWindowListCopyWindowInfo` でウィンドウ一覧取得
- `kCGWindowOwnerName == "Google Chrome"` またはbundle idでフィルタ
- 通常の表示ウィンドウだけ抽出
- タイトル、位置、サイズ、window id、pidを取得

### 30.4 AXWindowRef取得

- pidから `AXUIElementCreateApplication`
- window listを取得
- CGWindow情報とAXWindowを照合
- 位置・サイズの読み書きを実装

### 30.5 Slot手動追加

- 現在のChromeウィンドウをslotに追加
- slot名を入力
- slot一覧を保存
- slot削除を実装

### 30.6 Offscreen parking

- active slot以外を画面外へ移動
- active slotをstage rectへ復帰
- 失敗時にリトライ
- `Unpark All` を実装

### 30.7 Overlay UI

- フローティングパレットを表示
- slot名を一覧表示
- active slotを強調
- クリックで切り替え
- Chrome focus復帰

### 30.8 HotKey

- next / previous slot
- direct slot switching
- unpark all

### 30.9 終了処理

- アプリ終了時にparked windowsを復帰
- Chrome終了検出
- 前回セッション復元

---

## 31. MVP受け入れ条件

Phase 1の完了条件:

- 3つ以上のChromeプロファイルウィンドウをslotとして登録できる
- Overlayに手動設定したプロファイル名が表示される
- ホットキーまたはクリックでslotを切り替えられる
- 非アクティブウィンドウが画面上に重ならない
- ドロップシャドウが濃くならない
- 表示中ウィンドウの移動・リサイズがStackerより軽い
- ChromeのDockメニューと標準プロファイル操作が壊れない
- DevToolsが通常通り使える
- `Unpark All` で画面外ウィンドウを復帰できる
- アプリ終了時にChromeウィンドウを復帰できる

---

## 32. 将来の拡張案

- Raycast extension
- CLI
- JSON/YAMLによるslot設定
- 契約先ごとのアイコン
- プロファイルごとの色自動取得
- Chrome以外のChromium系ブラウザ対応
  - Brave
  - Edge
  - Vivaldi
  - Arc
  - Dia
- Safari対応
- マルチStage
- Stageごとの保存/復元
- 会議モード
- 機密モード
  - サムネイル無効
  - タイトル非表示
  - ログ最小化
- 自動アップデート
- notarized build
- Homebrew配布

---

## 33. 最初の実装判断

初期実装では、以下の判断を採用する。

| 項目 | 判断 |
|---|---|
| 実装方式 | Stage方式 |
| Chrome埋め込み | しない |
| 非アクティブウィンドウ | offscreen parking |
| プロファイル名 | まず手動 |
| Chrome Local State | Phase 2 |
| Chrome拡張 | Phase 3 |
| Native Messaging | Phase 3 |
| サムネイル | MVPではなし |
| UI | フローティングパレット |
| 権限 | Accessibilityのみ |
| URL/タイトル取得 | MVPではしない |
| 対象ブラウザ | Google Chromeのみ |
| Fullscreen | MVPでは対象外 |
| DevTools | MVPでは対象外または通常通り放置 |
| Popup/OAuth | Stageに自動吸収しない |

---

## 34. 参考リンク

### Stacker

- https://github.com/rloechner/stacker

### Chrome Extensions

- Chrome `windows` API  
  https://developer.chrome.com/docs/extensions/reference/api/windows

- Chrome Native Messaging  
  https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging

- Chrome拡張の配布  
  https://developer.chrome.com/docs/extensions/how-to/distribute/install-extensions

### macOS / Apple

- ScreenCaptureKit  
  https://developer.apple.com/documentation/screencapturekit/

- AppKit `NSWindow.addChildWindow`  
  https://developer.apple.com/documentation/appkit/nswindow/addchildwindow(_:ordered:)

- CoreGraphics Window Services  
  https://developer.apple.com/documentation/coregraphics/quartz-window-services

### Chromium Local Stateの参考

- Chromium test data example: `Local State`  
  https://chromium.googlesource.com/chromium/src.git/+/39.0.2164.0/chrome/test/data/diagnostics/user/Local%20State

---

## 35. 結論

自作するなら、Stackerの「外側から既存Chromeウィンドウをラップする」というコンセプトは維持する。

ただし、物理的に複数ウィンドウを重ねるStack方式ではなく、**表示中のChromeウィンドウだけをステージ上に置き、非アクティブウィンドウを画面外へ退避するStage方式**を採用する。

この方式により、Stackerで問題になった以下を設計レベルで解決できる。

- プロファイル名が表示されない  
  → Overlay UI + 手動マッピング / Local State / Companion Extensionで解決

- ドロップシャドウが濃い  
  → 画面上に1枚しかChromeウィンドウを置かないため解消

- ウィンドウ移動がもたつく  
  → 移動中に複数ウィンドウを同期しないため軽くなる

最初のMVPは、**AX-only + 手動slot名 + offscreen parking + Overlay switcher + Unpark All** で十分。

その後、Chrome Local State、Companion Extension、Native Messagingを段階的に追加し、プロファイル自動認識と復元性を高める。
