# CLAUDE.md

## プロジェクト概要

**Chrome Stage** は、契約先ごとに分けた Chrome プロファイルのウィンドウを、Chrome 本来の使い勝手を壊さずに 1 つの作業ステージ内で切り替えられるようにする macOS アプリ。

- 対象環境: macOS / Google Chrome
- 技術スタック: Swift / AppKit(Overlay UI は NSPanel / SwiftUI)
- 詳細な設計は [chrome-stage-initial-design.md](chrome-stage-initial-design.md) を参照

## 設計思想(最重要・不変)

Chrome を置き換えず、**既存の Chrome ウィンドウを外側からラップするだけ**にとどめる。

- Chrome ウィンドウは本物の Chrome ウィンドウのまま保持する
- 画面上には原則アクティブな Chrome ウィンドウを 1 つだけ表示する(**Stage 方式**)
- 非アクティブなウィンドウは画面外へ退避する(**offscreen parking**)
- 自作アプリは「切り替え UI」「プロファイル名表示」「ウィンドウ制御」だけを担当する
- 他プロセスの Chrome ウィンドウは Accessibility API / CoreGraphics 経由で外部制御する(埋め込まない)

## 非目標(やらないこと)

- 独自ブラウザを作る / Chrome を WebView で再実装する
- Chrome のプロファイル管理・セッション復元・Dock メニューを置き換える/再実装する
- 他プロセスの Chrome ウィンドウを自作アプリの NSView に本当に埋め込む
- すべての Chrome ウィンドウを常に同期移動する(Stacker 方式の轍を踏まない)

## 中核コンセプト

- **Stage**: 現在の作業領域。位置・サイズ・対象ディスプレイ・表示中 slot・Overlay UI の位置を持つ
- **Slot**: 1 つの Chrome プロファイルウィンドウに対応する論理単位。表示名(契約先名)、Chrome プロファイル、ウィンドウ参照、状態(visible / parked / minimized / missing / closed)を持つ
- **切り替え処理**: 現在の slot を park → ターゲットを stage rect へ復帰 → focus → Overlay 更新

## セキュリティ・機密情報の方針

契約先の機密情報を扱う前提のため、以下を厳守する。

- URL やページタイトルを保存・送信・ログ出力しない
- Chrome 拡張の `tabs` permission は必要になるまで付けない(最小権限: `windows`, `nativeMessaging`, `storage`)
- サムネイル(Screen Recording 権限)はデフォルト無効
- 設定ファイルに保存するのはプロファイル名とウィンドウ ID 程度にとどめる

## 権限

- **Accessibility**: 必須。ウィンドウの位置取得・移動・リサイズ・前面化に使用
- **Screen Recording**: オプション。サムネイル表示にのみ必要(MVP では使わない)

## 安全機能(必須)

offscreen parking によりウィンドウが画面外に取り残されるリスクがあるため、以下は必ず維持する。

- `Unpark All`(メニューバーまたはホットキーから全ウィンドウ復帰)
- アプリ終了時に全ウィンドウを復帰
- クラッシュ後の復旧(parking rect の永続化と起動時復帰)
- ディスプレイ構成変更の検出と退避座標の再計算

## 段階的実装計画

| Phase | 内容 |
|---|---|
| Phase 1 | AX-only Stage(手動 slot 名 + offscreen parking + Overlay switcher + Unpark All) |
| Phase 2 | Profile Registry(Chrome の `Local State` からプロファイル名候補を取得) |
| Phase 3 | Companion Extension + Native Messaging(プロファイル自動認識) |
| Phase 4 | Polish(サムネイル、Raycast 連携、メニューバーアプリ化など) |

プロファイル名の取得は「手動マッピング → Local State 読み取り → Chrome 拡張 + Native Messaging」の順に段階的に自動化する。

## エッジケースの基本方針

- **Fullscreen の Chrome ウィンドウ**: Stage 対象外
- **DevTools**: Stage 対象外(Chrome 本体ウィンドウだけ slot 化)
- **OAuth / popup ウィンドウ**: Stage に自動吸収しない
- **同一プロファイルの複数ウィンドウ**: MVP では 1 slot = 1 primary window
- **Spaces**: 同一 Space 内での利用を前提とし、横断制御はしない
- **`chromeWindowId`**: 永続 ID として扱わず、Chrome 起動中の一時 ID として扱う

## 実装上の注意

- AX(Accessibility)操作は薄くラップし、失敗時はリトライ、操作後に実際の位置・サイズを読み直して検証する
- Chrome UI の内部構造(タイトルバーの AX 階層など)に依存しない
- ドキュメントやコードコメントは日本語で記述する

## リポジトリ運用ルール

- 特に指示がない限り、ひとまとまりの作業が終了する度に変更したファイルをコミットしてください（ただし app 以下の変更を除きます）
- 前回のファイル編集に関する軽微な修正、記載漏れの追記などについては対象のコミットを amend する形でコミットしてください