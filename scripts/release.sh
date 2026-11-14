#!/bin/bash
# 公開用成果物を段階的に作る。署名・公証には Xcode 登録済みのアカウントを使う。
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
release_dir="${RELEASE_DIR:-$root/build/release}"
archive="$release_dir/ChromeStage.xcarchive"
export_dir="$release_dir/export"
app="$export_dir/ChromeStage.app"
notarized_dir="$release_dir/notarized"

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
usage() {
    cat <<'EOF'
使い方: scripts/release.sh <archive|export|submit|finish|package>

  archive  clean なコミットから Universal Release archive を作成
  export   Developer ID Application 証明書で配布用に書き出して検証
  submit   Xcode のアカウントで Apple に公証を依頼
  finish   公証済みアプリを取り出し、staple・Gatekeeper 検証
  package  公証済みアプリと利用案内を ZIP にまとめ、SHA-256 を生成

環境変数:
  RELEASE_DIR     作業先（既定: build/release、別ビルドには別の場所を指定）

証明書・認証の初期設定と公開手順は release/README.md を参照。
EOF
}

[[ $# -eq 1 ]] || { usage; exit 1; }
case "$1" in
    -h|--help) usage; exit 0 ;;
    archive)
        [[ -z "$(git -C "$root" status --porcelain)" ]] || fail "変更をコミットしてから archive してください。"
        [[ ! -e "$archive" ]] || fail "archive は既に存在します。別の RELEASE_DIR を指定してください。"
        mkdir -p "$release_dir"
        git -C "$root" rev-parse HEAD > "$release_dir/source-commit.txt"
        xcodebuild -project "$root/app/ChromeStage.xcodeproj" -scheme ChromeStage \
            -configuration Release -destination 'generic/platform=macOS' \
            -derivedDataPath "$release_dir/DerivedData" -archivePath "$archive" \
            archive
        ;;
    export)
        [[ -d "$archive" ]] || fail "先に archive を実行してください。"
        [[ ! -e "$export_dir" ]] || fail "export 先が既に存在します。内容を確認してから再実行してください。"
        xcodebuild -exportArchive -archivePath "$archive" \
            -exportOptionsPlist "$root/release/ExportOptions.plist" -exportPath "$export_dir" \
            -allowProvisioningUpdates
        "$root/scripts/verify-release.sh" "$app"
        ;;
    submit)
        "$root/scripts/verify-release.sh" "$app"
        [[ ! -e "$release_dir/submitted" ]] || fail "提出済みです。finish で処理を再開してください。"
        xcodebuild -exportArchive -archivePath "$archive" \
            -exportOptionsPlist "$root/release/NotarizeOptions.plist" \
            -exportPath "$release_dir/notary-upload" -allowProvisioningUpdates
        touch "$release_dir/submitted"
        ;;
    finish)
        [[ -d "$archive" ]] || fail "先に archive と submit を実行してください。"
        # アーカイブに記録された公証情報を Xcode に解決させる。
        # 審査中や不受理ならこのコマンドが失敗し、未公証のアプリは先へ進めない。
        xcodebuild -exportNotarizedApp -archivePath "$archive" -exportPath "$notarized_dir"
        app="$notarized_dir/ChromeStage.app"
        xcrun stapler staple "$app"
        "$root/scripts/verify-release.sh" "$app" --notarized
        ;;
    package)
        app="$notarized_dir/ChromeStage.app"
        "$root/scripts/verify-release.sh" "$app" --notarized
        version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
        [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "バージョン番号が不正です。"
        filename="ChromeStage-${version}.zip"
        [[ ! -e "$release_dir/$filename" ]] || fail "配布 ZIP が既に存在します: $filename"
        staging=$(mktemp -d "${TMPDIR:-/tmp}/chromestage-package.XXXXXX")
        trap 'rm -rf "$staging"' EXIT
        payload="$staging/ChromeStage-${version}"
        mkdir -p "$payload"
        ditto "$app" "$payload/ChromeStage.app"
        cp "$root/INSTALL.md" "$payload/はじめに.txt"
        cp "$root/PRIVACY.md" "$payload/プライバシー.txt"
        cp "$root/LICENSE" "$payload/LICENSE.txt"
        ditto -c -k --sequesterRsrc --keepParent "$payload" "$release_dir/$filename"
        (cd "$release_dir" && shasum -a 256 "$filename" > "$filename.sha256")
        printf '配布ファイル: %s\n' "$release_dir/$filename"
        ;;
    *) usage; exit 1 ;;
esac
