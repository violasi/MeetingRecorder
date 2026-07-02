#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

APP="MeetingRecorder.app"

# --- 预检：Command Line Tools 16.x 的 SwiftBridging 重复定义 bug ---
# 症状：import Foundation/AppKit 时报 "redefinition of module 'SwiftBridging'"，
# 或编译长时间卡住不动。见 README 的「故障排查」。
DUP_A="/Library/Developer/CommandLineTools/usr/include/swift/module.modulemap"
DUP_B="/Library/Developer/CommandLineTools/usr/include/swift/bridging.modulemap"
if [ -f "$DUP_A" ] && [ -f "$DUP_B" ] \
   && grep -q "module SwiftBridging" "$DUP_A" 2>/dev/null \
   && grep -q "module SwiftBridging" "$DUP_B" 2>/dev/null; then
  echo "❌ 检测到 Command Line Tools 的 SwiftBridging 模块重复定义 bug，无法编译。"
  echo "   请先在终端执行下面这条命令修复（会要求输入密码，可逆）："
  echo ""
  echo "     sudo mv \"$DUP_A\" \"$DUP_A.disabled\""
  echo ""
  echo "   （撤销：把 .disabled 改回去即可。或者改用: sudo rm -rf /Library/Developer/CommandLineTools && sudo xcode-select --install 重装。）"
  exit 1
fi

# --- 直接用 swiftc 编译（不走 SPM，因该环境 SPM 清单链接也异常）---
echo "== 编译 (swiftc) =="
mkdir -p ".build"
swiftc -O \
  -o ".build/MeetingRecorder" \
  -framework AppKit \
  -framework AVFoundation \
  -framework ScreenCaptureKit \
  -framework CoreGraphics \
  -framework CoreMedia \
  -framework UserNotifications \
  Sources/MeetingRecorder/*.swift

echo "== 组装 $APP =="
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ".build/MeetingRecorder" "$APP/Contents/MacOS/MeetingRecorder"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "== ad-hoc 签名 =="
codesign --force --deep --sign - "$APP"

echo ""
echo "✅ 构建完成: $(pwd)/$APP"
echo "   首次运行:  open ./$APP"
echo "   然后到「系统设置 → 隐私与安全性」授予【屏幕录制】和【麦克风】权限，"
echo "   授权后从菜单栏「退出」并重新 open 一次即可生效。"
