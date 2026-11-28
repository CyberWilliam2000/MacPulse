#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="$PWD/MacPulse.app"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$app/Contents/Info.plist")
codesign --verify --strict "$app"
mkdir -p .build dist
stage=$(mktemp -d "$PWD/.build/release.XXXXXX")
trap 'rm -rf "$stage"' EXIT
folder="$stage/MacPulse-$version-AppleSilicon"
mkdir -p "$folder"
ditto "$app" "$folder/MacPulse.app"
cp LICENSE "$folder/LICENSE"
cat > "$folder/使用说明.txt" <<'INFO'
Mac 脉搏 / MacPulse

支持 Apple Silicon M 系列 Mac，macOS 14 或更高版本。
把 MacPulse.app 拖到「应用程序」后双击运行。点击小球展开看板，菜单栏有设备查询和退出入口。

本版本为本地临时签名，尚无 Developer ID 签名和 Apple 公证，首次运行可能被 macOS 拦截。
请核对 GitHub 来源和 SHA-256。Apple 官方说明：https://support.apple.com/102445
公司设备请遵循 IT 政策；本说明不要求关闭系统安全保护。

应用列表可直接查看任务和强制关闭。强制关闭立即执行，可能丢失未保存内容；每行也有正常退出按钮，点击应用图标可打开应用。
设备查询不录音、不拍摄；历史从运行后开始。摄像头调用应用目前无法可靠识别。

源码、许可和反馈：https://github.com/CyberWilliam2000/MacPulse
发现新版时，菜单栏会显示「有更新」。点「查看更新」进入 GitHub 下载页。
更新前退出旧版，再替换应用包。
INFO
zip="$PWD/dist/MacPulse-$version-AppleSilicon.zip"
ditto -c -k --sequesterRsrc --keepParent "$folder" "$zip"
mkdir -p "$stage/verify"
ditto -x -k "$zip" "$stage/verify"
codesign --verify --strict "$stage/verify/MacPulse-$version-AppleSilicon/MacPulse.app"
(cd dist && shasum -a 256 "MacPulse-$version-AppleSilicon.zip" > "MacPulse-$version-SHA256SUMS.txt")
printf 'Packaged %s\n' "$zip"
