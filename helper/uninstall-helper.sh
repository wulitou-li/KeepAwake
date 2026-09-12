#!/bin/zsh
# KeepAwake 特权助手卸载脚本（需要 sudo 运行）
# sudo ./uninstall-helper.sh
set -euo pipefail

launchctl bootout system/com.local.keepawake.helper 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.local.keepawake.helper.plist
rm -rf "/Library/Application Support/KeepAwake"
echo "✅ KeepAwake 特权助手已卸载"
