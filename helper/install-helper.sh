#!/bin/zsh
# KeepAwake 特权助手安装脚本（需要 sudo 运行一次）
# sudo ./install-helper.sh
set -euo pipefail

DIR="/Library/Application Support/KeepAwake"
SRC="$(cd "$(dirname "$0")" && pwd)"
USER_NAME="${SUDO_USER:-$(whoami)}"

mkdir -p "$DIR"
chown "$USER_NAME" "$DIR"

cp "$SRC/apply.sh" "$DIR/apply.sh"
chown root:wheel "$DIR/apply.sh"
chmod 755 "$DIR/apply.sh"

# 状态文件由普通用户（KeepAwake 应用）写入
[ -f "$DIR/lid.state" ] || echo "0" > "$DIR/lid.state"
chown "$USER_NAME" "$DIR/lid.state"

cp "$SRC/com.local.keepawake.helper.plist" /Library/LaunchDaemons/com.local.keepawake.helper.plist
chown root:wheel /Library/LaunchDaemons/com.local.keepawake.helper.plist
chmod 644 /Library/LaunchDaemons/com.local.keepawake.helper.plist

launchctl bootout system/com.local.keepawake.helper 2>/dev/null || true
launchctl bootstrap system /Library/LaunchDaemons/com.local.keepawake.helper.plist

echo "✅ KeepAwake 特权助手已安装并启动（之后无需再输密码）"
