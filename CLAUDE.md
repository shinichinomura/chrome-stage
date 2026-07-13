# CLAUDE.md

Chrome Stage の開発ガイド。ここには README に載せていない、開発・実装上の指針だけを置く。

- **プロジェクト概要・設計思想・中核コンセプト・非目標・権限・安全機能・段階的実装計画（ロードマップ）**: [README.md](README.md) を参照
- **詳細な設計(背景・代替案・アーキテクチャ・エッジケース・データモデル)**: [chrome-stage-initial-design.md](chrome-stage-initial-design.md) を参照

設計思想(Chrome を置き換えず既存ウィンドウを外側からラップするだけ / Stage 方式 / offscreen parking)は最重要かつ不変。実装判断で迷ったら README の "Design philosophy" と "Non-goals" を最優先する。

## セキュリティ・機密情報の方針(実装制約)

README の Privacy を厳守する。加えて実装時は以下も守る。

- Chrome 拡張の `tabs` permission は必要になるまで付けない(最小権限: `windows`, `nativeMessaging`, `storage`)

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

- 特に指示がない限り、ひとまとまりの作業が終了する度に変更したファイルをコミットしてください
- 前回のファイル編集に関する軽微な修正、記載漏れの追記などについては対象のコミットを amend する形でコミットしてください
