# Developer ID 配布の手順

配布先は公開リポジトリ [shinichinomura/chrome-stage](https://github.com/shinichinomura/chrome-stage) の GitHub Releases を使用する。App Sandbox は有効にしない。Hardened Runtime を有効にした Universal アプリを Developer ID Application で署名し、Apple の公証を通してから ZIP を公開する。

## 初回の設定

1. Xcode → Settings → Apple Accounts に配布チームのアカウントを登録する。このプロジェクトの Team ID は `2B4YHY8VXE`。
2. Apple Developer Program と配布署名の権限が有効であることを確認する。`export` と `submit` は `-allowProvisioningUpdates` を使い、Xcode の自動署名と登録済みアカウントで処理する。
3. 自動署名が利用できない場合は Xcode のアカウント・契約・権限を確認する。手動署名に切り替える場合のみ、Manage Certificates から Developer ID Application 証明書を用意し、ExportOptions を変更する。ZIP 配布に Developer ID Installer は不要。

この Mac ではローカルの `security find-identity` に Developer ID が表示されなくても、Xcode の自動署名で Developer ID Application 署名と公証に成功した。ローカルの証明書一覧だけで利用不可と判断しない。スクリプトは書き出されたアプリの署名を検証する。Xcode のアカウントを使うため、別途 `notarytool store-credentials` を実行する必要はない。認証情報をソース、シェル履歴、チャットに書かない。

## ビルドから公証まで

公開する `MARKETING_VERSION` と `release/notes/<version>.md` をそろえ、すべての変更をコミットする。ビルド番号は既存の Embed Git Info フェーズが Git コミット数から設定する。

```sh
scripts/release.sh archive
scripts/release.sh export
scripts/release.sh submit
scripts/release.sh finish
scripts/release.sh package
```

`submit` は `destination=upload` で Apple に公証を依頼し、Xcode がその情報を archive に保存する。`finish` は `xcodebuild -exportNotarizedApp` で公証済みアプリを取得し、staple と Gatekeeper 検証を行う。処理中の場合は、Xcode Organizer で状態を確認してから `finish` を再実行する。公証は App Store の審査提出とは異なる。

ネットワーク切断などで結果が不明な場合は、重複提出する前に Xcode Organizer で archive の状態を確認し、`finish` からの再開を試す。失敗時の詳細と警告は Xcode が出力する `.xcdistributionlogs` と Organizer の公証ログで確認する。archive 自体が再開に必要なので、公開後も保管する。

既存の archive や配布 ZIP は上書きしない。別のビルドを作る場合は、すべてのコマンドで同じ `RELEASE_DIR`（例: `$PWD/build/release-0.1.1`）を指定する。ビルド成果物、提出 ID、認証情報、証明書はコミットしない。

## 公開前の確認

- `verify-release.sh` が Developer ID / Team ID / Hardened Runtime / timestamp / entitlement を検証する。
- `package` はさらに stapler と Gatekeeper の検証に成功した `notarized/ChromeStage.app` だけを ZIP にする。`export/` の公証前アプリや archive 内の開発署名アプリを公開しない。
- ZIP を別の場所に展開し、アプリの署名・staple が維持されていることを確認する。
- 実際にダウンロードしたアプリをクリーンな環境で起動し、初回許可、Slot 登録、切り替え、全復帰、終了時復帰、Chrome 再起動時の復元を確認する。
- Intel 向けコードのコンパイル成功と Intel Mac 上での実行検証は区別する。

```sh
scripts/verify-release.sh /展開先/ChromeStage.app --notarized
```

## GitHub Releases への公開

バージョンと成果物を確認し、まず draft を作る。`--target` には `build/release/source-commit.txt` のコミットを指定する。手元の main が archive の作成後に進んでいても、タグは実際にビルドしたコミットを指すようにする。

```sh
git push origin main
gh release create v0.1.0 \
  build/release/ChromeStage-0.1.0.zip \
  build/release/ChromeStage-0.1.0.zip.sha256 \
  --repo shinichinomura/chrome-stage \
  --target "$(cat build/release/source-commit.txt)" \
  --title 'Chrome Stage 0.1.0' \
  --notes-file release/notes/0.1.0.md \
  --draft

# 内容と実機確認の結果がそろったら一般公開する。
gh release edit v0.1.0 --repo shinichinomura/chrome-stage --draft=false --latest
```

## アイコンの再生成

```sh
swift scripts/generate-icon.swift
```

AppKit で描画したウィンドウとパレットの図形を `Assets.xcassets/AppIcon.appiconset` に生成する。Google Chrome のロゴや外部の画像素材は使用していない。

公式資料: [公証の前提](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)、[公証ワークフロー](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)。
