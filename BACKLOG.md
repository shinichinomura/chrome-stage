# Phase 1 バックログ

Phase 1(AX-only Stage)を着手順に並べたバックログ。上から順に進める。
完了条件は [chrome-stage-initial-design.md](chrome-stage-initial-design.md) の「31. MVP受け入れ条件」を正とする。

**ステータス: 全タスク完了(2026-07-03)。受け入れ条件はユーザー確認済み。しばらく日常利用して問題がなければ Phase 2(Profile Registry)へ進む。**

## 決定事項

| 項目 | 決定 |
|---|---|
| アプリ形態 | メニューバー常駐(LSUIElement)。Unpark All を常にメニューバーから実行できるようにするため |
| 配置 | Xcode プロジェクトは `app/` 配下。検証スクリプトは `spikes/` 配下 |
| プロジェクト管理 | `.xcodeproj` を直接コミット(生成ツールは使わない) |
| 最小対応 OS | 開発マシンの現行 macOS に決め打ち |
| 保存先 | `~/Library/Application Support/ChromeStage/` に JSON |
| ログ | OSLog。URL・タイトルは出さない(CLAUDE.md 参照) |
| 外部依存 | ゼロ依存。グローバルホットキーは Carbon `RegisterEventHotKey` を薄くラップ |
| ホットキー(仮) | 次/前の slot: `Ctrl+Option+Tab` / `Ctrl+Option+Shift+Tab`、直接切替: `Ctrl+Option+1〜9`、Unpark All: `Ctrl+Option+U`。Chrome の `Ctrl+Tab` と衝突しないこと。実装時(タスク 10)に最終確認 |

## タスク

### 1. スパイク: offscreen parking の成立検証 ✅

- [x] `spikes/offscreen-parking/` に検証スクリプトを作成
- [x] AX API で Chrome ウィンドウを画面外座標へ移動 → 座標を読み直し → 元に戻す
- [x] macOS によるクランプ(位置補正)の有無と、成立する退避座標のパターンを記録
- [x] 結果を `spikes/offscreen-parking/RESULT.md` に記録
- 結論: **「1px だけ画面内に残す」方式で成立**(完全画面外はクランプされる)。退避座標はウィンドウ幅とディスプレイ frame から動的に算出する

### 2. リポジトリ準備 ✅

- [x] `.gitignore`(Xcode / Swift / macOS)
- [x] Accessibility 権限を安定させる署名設定の確認(Apple Development 証明書で一貫署名。Team ID: 2B4YHY8VXE、自動署名でビルド確認済み)

### 3. Xcode プロジェクト作成(`app/`)✅

- [x] メニューバー常駐アプリの骨組み(LSUIElement)
- [x] メニューバーに最低限のメニュー(Quit / Unpark All のプレースホルダ)
- [x] OSLog によるログ基盤
- 備考: `xcodebuild -project app/ChromeStage.xcodeproj -scheme ChromeStage build` でビルド。起動・OSLog 出力を実機確認済み

### 4. Accessibility 権限チェック ✅

- [x] 権限状態の確認(`AXIsProcessTrusted`)
- [x] 未許可時の案内 UI(システムダイアログ + メニューからシステム設定を開く)
- [x] 許可後の再チェック(許可されるまで 2 秒間隔でポーリングし、メニュー表示を更新)
- 備考: ChromeStage.app への権限付与(システム設定での手動操作)が済んでからタスク 5 以降の動作確認が可能になる

### 5. Chrome ウィンドウ検出(WindowDiscoveryService)✅

- [x] `CGWindowListCopyWindowInfo` + bundle id フィルタで Chrome の通常ウィンドウを列挙
- [x] 位置・サイズ・windowId・pid の取得(タイトルは Screen Recording 権限が必要なため使わない方針に変更)
- [x] popup / DevTools の除外(AX subrole = AXStandardWindow で判定。fullscreen は Stage 対象外の運用)

### 6. AX ウィンドウ操作(AXWindow)✅

- [x] pid → `AXUIElementCreateApplication` → ウィンドウ一覧取得
- [x] CGWindow 情報と AX ウィンドウの照合(ジオメトリ照合。タイトル非依存)
- [x] 位置・サイズの読み書き、raise、focus
- [x] 失敗時リトライと、操作後の読み直し検証

### 7. Slot 管理と永続化(StageSessionStore)✅

- [x] Slot の手動追加(最前面の Chrome ウィンドウを slot 化)・名前設定・削除
- [x] StageSession / ChromeSlotRecord の JSON 永続化(`~/Library/Application Support/ChromeStage/session.json`)
- [x] 起動時のセッション読み込みとウィンドウ再照合(照合失敗は missing 扱い)

### 8. 切り替え処理と offscreen parking ✅

- [x] switchTo: ターゲット以外を park → ターゲットを stage rect へ復帰 → focus
- [x] スパイク結果に基づく退避座標の算出(右端ディスプレイの `maxX - 1`、1px 残し)
- [x] `Unpark All`(メニューバーから実行。アプリ終了時にも自動実行)
- 備考: `--selftest` モード(検出 → AX 照合 → park → 復帰 → 永続化)で全項目 PASS を確認。メニュー操作での切り替え体験の確認はタスク 12 で行う

### 9. Overlay UI(フローティングパレット)✅

- [x] NSPanel(non-activating, floating)+ SwiftUI で slot 一覧表示
- [x] active slot の強調(ハイライト + 緑ドット)、クリックで切り替え
- [x] 切り替え後に Chrome へ focus を戻す(switchTo 内で前面化)
- 備考: 位置はドラッグ可能で記憶される。メニューから表示/非表示を切り替え可能

### 10. ホットキー(HotKeyController)✅

- [x] 決定事項のホットキーで実装(Ctrl+Option+Tab / Shift+Tab / 1〜9 / U)。12 件の登録成功をログで確認
- [x] next / previous / direct 1〜9 / unpark all
- [x] Chrome・macOS 標準との衝突の実機確認(問題なし)

### 11. 終了処理・復旧(RecoveryController 相当)✅

- [x] アプリ終了時に全 parked ウィンドウを復帰(applicationWillTerminate)
- [x] 起動時に前回 parking したウィンドウを検出して復帰(クラッシュ復旧。SIGTERM 終了後の再起動で parked 2 件の自動復帰を実地確認済み)
- [x] ディスプレイ構成変更の検出 → 退避座標の再計算、stage rect が画面外ならリセット
- [x] Chrome 終了検出 → 全 slot を missing へ

### 12. 受け入れ条件の検証 ✅

- [x] 設計メモ「31. MVP受け入れ条件」を実機確認(2026-07-03、ユーザー確認で全項目 OK)
- 補足: Overlay パレットは macOS 26 の Liquid Glass テーマ(NSGlassEffectView)に変更済み
