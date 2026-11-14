#!/bin/bash
# 配布用署名を検証する。開発署名の成果物は成功扱いにしない。
set -euo pipefail

fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 ]] || fail "使い方: $0 ChromeStage.app [--notarized]"
app="$1"
[[ $# -eq 1 || "$2" == --notarized ]] || fail "不明なオプション: $2"
[[ -d "$app" ]] || fail "アプリが見つかりません: $app"

codesign --verify --deep --strict --verbose=2 "$app"
signature=$(codesign -d --verbose=4 "$app" 2>&1)
[[ "$signature" == *"Authority=Developer ID Application:"* ]] \
    || fail "Developer ID Application 署名が必要です。"
[[ "$signature" == *"TeamIdentifier=2B4YHY8VXE"* ]] || fail "Team ID が一致しません。"
[[ "$signature" == *"(runtime)"* ]] || fail "Hardened Runtime が無効です。"
[[ "$signature" == *"Timestamp="* ]] || fail "secure timestamp がありません。"

entitlements=$(mktemp "${TMPDIR:-/tmp}/chromestage-entitlements.XXXXXX")
trap 'rm -f "$entitlements"' EXIT
codesign -d --entitlements - --xml "$app" > "$entitlements"
if [[ -s "$entitlements" ]]; then
    plutil -lint "$entitlements" > /dev/null
    debug=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.get-task-allow' "$entitlements" 2>/dev/null || true)
    [[ "$debug" != true ]] || fail "get-task-allow が有効です。開発用のアプリは配布できません。"
    sandbox=$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$entitlements" 2>/dev/null || true)
    [[ "$sandbox" != true ]] || fail "現行の AX 操作には Sandbox 無効のビルドが必要です。"
fi

plist="$app/Contents/Info.plist"
bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist")
[[ "$bundle_id" == com.shinichinomura.ChromeStage ]] || fail "Bundle ID が一致しません。"
commit=$(/usr/libexec/PlistBuddy -c 'Print :ChromeStageGitCommit' "$plist")
[[ "$commit" != unknown && "$commit" != *-dirty ]] || fail "コミットが特定できないビルドです。"
icon=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$plist")
[[ -n "$icon" ]] || fail "アプリアイコンがありません。"
[[ -f "$app/Contents/Resources/${icon%.icns}.icns" ]] || fail "アイコンの実体がありません。"

if [[ "${2:-}" == --notarized ]]; then
    xcrun stapler validate "$app"
    spctl --assess --type execute --verbose=2 "$app"
fi
printf '検証成功: %s\n' "$app"
