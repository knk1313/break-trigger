#!/usr/bin/env bash
# リリースビルドを作り、build/Break Trigger.app にまとめる。
# 通知を使うにはアプリのバンドルが必要なため、swift run ではなくこのスクリプトで作る。
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release
bin_dir="$(swift build -c release --show-bin-path)"

app="build/Break Trigger.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/BreakTrigger" "$app/Contents/MacOS/BreakTrigger"
cp Resources/Info.plist "$app/Contents/Info.plist"

# 手元で動かすためのアドホック署名
codesign --force --sign - "$app"

echo "作成しました：$app"
