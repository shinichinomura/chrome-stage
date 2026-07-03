# Phase 1 バックログ

Phase 1(AX-only Stage)を着手順に並べたバックログ。上から順に進める。
完了条件は [chrome-stage-initial-design.md](chrome-stage-initial-design.md) の「31. MVP受け入れ条件」を正とする。

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

### 1. スパイク: offscreen parking の成立検証

- [ ] `spikes/offscreen-parking/` に検証スクリプトを作成
- [ ] AX API で Chrome ウィンドウを画面外座標へ移動 → 座標を読み直し → 元に戻す
- [ ] macOS によるクランプ(位置補正)の有無と、成立する退避座標のパターンを記録
- [ ] 結果を `spikes/offscreen-parking/RESULT.md` に記録
- 不成立の場合: 退避座標の工夫 or Minimize parking への方針転換を判断してから次へ進む

### 2. リポジトリ準備

- [ ] `.gitignore`(Xcode / Swift / macOS)
- [ ] Accessibility 権限を安定させる署名設定の確認(Apple Development 証明書で一貫署名)

### 3. Xcode プロジェクト作成(`app/`)

- [ ] メニューバー常駐アプリの骨組み(LSUIElement)
- [ ] メニューバーに最低限のメニュー(Quit / Unpark All のプレースホルダ)
- [ ] OSLog によるログ基盤

### 4. Accessibility 権限チェック

- [ ] 権限状態の確認(`AXIsProcessTrusted`)
- [ ] 未許可時の案内 UI(システム設定へ誘導)
- [ ] 許可後の再チェック

### 5. Chrome ウィンドウ検出(WindowDiscoveryService)

- [ ] `CGWindowListCopyWindowInfo` + bundle id フィルタで Chrome の通常ウィンドウを列挙
- [ ] タイトル・位置・サイズ・windowId・pid の取得
- [ ] popup / DevTools / fullscreen の除外

### 6. AX ウィンドウ操作(AXWindowController)

- [ ] pid → `AXUIElementCreateApplication` → ウィンドウ一覧取得
- [ ] CGWindow 情報と AX ウィンドウの照合
- [ ] 位置・サイズの読み書き、raise、focus
- [ ] 失敗時リトライと、操作後の読み直し検証

### 7. Slot 管理と永続化(StageSessionStore)

- [ ] Slot の手動追加(現在の Chrome ウィンドウを slot 化)・名前設定・削除
- [ ] StageSession / ChromeSlotRecord の JSON 永続化(parking rect 含む)
- [ ] 起動時のセッション読み込みとウィンドウ再照合

### 8. 切り替え処理と offscreen parking

- [ ] switchTo: 現 slot を park → ターゲットを stage rect へ復帰 → focus
- [ ] スパイク結果に基づく退避座標の算出
- [ ] `Unpark All`(メニューバーから実行)

### 9. Overlay UI(フローティングパレット)

- [ ] NSPanel(non-activating)+ SwiftUI で slot 一覧表示
- [ ] active slot の強調、クリックで切り替え
- [ ] 切り替え後に Chrome へ focus を戻す

### 10. ホットキー(HotKeyController)

- [ ] 決定事項のホットキー(仮)で実装し、Chrome・macOS 標準との衝突を実機確認
- [ ] next / previous / direct 1〜9 / unpark all

### 11. 終了処理・復旧(RecoveryController)

- [ ] アプリ終了時に全 parked ウィンドウを復帰
- [ ] 起動時に前回 parking したウィンドウを検出して復帰(クラッシュ復旧)
- [ ] ディスプレイ構成変更の検出 → parking rect 再計算 or 自動 Unpark
- [ ] Chrome 終了検出 → slot を missing/closed へ

### 12. 受け入れ条件の検証

- [ ] 設計メモ「31. MVP受け入れ条件」を 1 項目ずつ実機確認し、結果を記録
