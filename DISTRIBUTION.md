# 公開準備

確認日: 2026-11-15。調査対象: `d3794aa` / version `0.1.0` / build `20`。

**決定: 現行機能を維持し、Developer ID 署名・Apple 公証付きで GitHub Releases から配布する。** 以下の実機確認表は準備前の調査記録。現在の公開手順は [Developer ID 配布の手順](release/README.md) を参照。

2026-11-15: [0.1.0 を一般公開](https://github.com/shinichinomura/chrome-stage/releases/tag/v0.1.0)。公開バイナリは `b4b8e40` / build `22`。Universal archive、Developer ID 署名、公証、staple、Gatekeeper、ZIP 展開後の署名とバージョンを確認した。新規 Mac での初回 Accessibility 許可や Intel 実機での動作は今回未検証。

## 現状の判断

**現在の Accessibility API（AX）によるウィンドウ操作を維持したまま、Mac App Store に新規公開するための対応経路は確認できない。** 署名やストア情報の整備より先に、配布経路または操作方式を決める必要がある。

- Mac App Store では App Sandbox が必須。[App Review Guidelines 2.4.5(i)](https://developer.apple.com/app-store/review/guidelines/#hardware-compatibility)
- Apple は、他アプリを操作する Accessibility API の使用を Sandbox と非互換としている。[App Sandbox の非互換機能](https://developer.apple.com/documentation/security/protecting-user-data-with-app-sandbox)
- 同種のウィンドウ管理アプリに対する Apple DTS の回答も、Sandbox 内からの AX 操作はできず、Developer ID による直接配布を案内している。既存のストア掲載アプリには Sandbox 必須化前のものがあり、新規提出が可能な根拠にはならない。DTS の技術回答と App Review の個別判断は区別する。[Apple DTS の回答](https://developer.apple.com/forums/thread/805556)

Chrome Stage は `app/ChromeStage/AXWindow.swift` で、Chrome のウィンドウ列挙に `AXUIElementCopyAttributeValue`、移動・リサイズに `AXUIElementSetAttributeValue`、前面化に `AXUIElementPerformAction` を使っている。これは切り替え・画面外退避・復帰という中核機能そのものなので、Sandbox を有効にするだけでは対応できない。

## 実機で確認した状態

| 項目 | 結果 |
| --- | --- |
| Release ビルド | 成功（Xcode 27.2、generic macOS destination） |
| アーキテクチャ | `arm64` / `x86_64` |
| 最小 OS | macOS 26.0 |
| Bundle ID | `com.shinichinomura.ChromeStage` |
| Team ID | `2B4YHY8VXE` |
| 生成アプリの署名検証 | `codesign --verify --strict` 成功 |
| 現在の署名 | Apple Development（配布用に書き出した成果物ではない） |
| Hardened Runtime | 有効 |
| App Sandbox | 生成アプリの entitlement に存在しない |
| デバッグ用 entitlement | `com.apple.security.get-task-allow = true`。配布時は除去が必要 |
| ローカルで利用可能な署名 identity | Apple Development のみ。Developer ID Application は見つからない |
| バージョン表示 | `--version` で `0.1.0 (build 20)` / `d3794aa` を確認 |
| アプリアイコン | 専用アセット・ビルド設定なし（メニューバーの SF Symbol とは別に必要） |

ビルド時には App Intents 未使用によるメタデータ抽出スキップの警告が出た。ビルドと署名検証の成功は App Store の提出検証や公証の成功を意味しない。Apple Developer Program の契約状態、App Store Connect 上の登録状況は未確認。

今回の確認では通常のアプリ起動や `--selftest` による実際の Chrome ウィンドウ移動は行っていない。Sandbox 内での動作可否の判断は、現行コードと Apple の公式資料に基づく。

再確認用コマンド（開発署名のビルド。公開用パッケージではない）:

```sh
xcodebuild -project app/ChromeStage.xcodeproj -scheme ChromeStage \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath /tmp/chrome-stage-app-store-audit build

codesign --verify --strict --verbose=2 \
  /tmp/chrome-stage-app-store-audit/Build/Products/Release/ChromeStage.app
codesign -d --entitlements - \
  /tmp/chrome-stage-app-store-audit/Build/Products/Release/ChromeStage.app
/tmp/chrome-stage-app-store-audit/Build/Products/Release/ChromeStage.app/Contents/MacOS/ChromeStage --version
```

## 配布方針の選択

### 現行機能を維持する場合

Developer ID 署名と Apple の公証を行い、GitHub Releases から配布する。公証は App Store 審査とは異なる。[Apple の公証手順](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)

1. Apple Developer Program の有効な契約と Developer ID Application 証明書を確認・用意する。
2. Release archive と配布用の export 手順を用意する。Hardened Runtime、secure timestamp、`get-task-allow` がないことを確認する。
3. アプリアイコン、公開バージョン、著作権表示、インストール手順を整える。
4. 配布パッケージを公証し、ticket を staple して署名・Gatekeeper の検証を行う。
5. クリーンな環境で初回起動、Accessibility 許可、切り替え、全復帰、終了時復帰、Chrome 再起動時の復元を確認する。
6. プライバシー説明、問い合わせ先、ダウンロード先、更新手順を整えて公開する。

### Mac App Store を優先する場合

先に AX への依存をなくせるか調査する。代替方式が Sandbox 内で Chrome の列挙・移動・リサイズ・前面化・安全な復帰を実現できることを、小さな検証用実装で確認する。現時点では代替方式の実現性や審査通過は確認していない。設計上の中核を変えるため、配布方針を決めてから着手する。

技術的な成立を確認できた場合の準備項目:

- Sandbox と必要最小限の entitlement、保存先移行を設計する。
- App Store Connect のアプリ登録、配布署名、提出用 archive を整える。
- 公開名、アイコン、説明、スクリーンショット、価格、配信地域、年齢制限、サポート情報を用意する。[掲載素材の管理](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-your-app-store-assets)
- 公開プライバシーポリシー URL と App Privacy の回答を用意する。収集しない場合もポリシー URL は必須。[App Privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- Git コミット数を `CFBundleVersion` に上書きする現在のスクリプトを見直し、提出済みビルドと重複しない番号を管理できるようにする。
- Chrome が必要なこと、初回の権限設定、メニューバーからの操作、復帰手順を審査担当者に説明し、実機で検証する。

この調査後、Xcode の登録済みアカウントによる自動署名と公証が利用できることを確認した。ローカルの証明書一覧に Developer ID がないことだけで配布不可と判断しない。以降の作業は [Developer ID 配布の手順](release/README.md) に従う。App Store への審査提出は行わない。
