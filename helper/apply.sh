#!/bin/zsh
# KeepAwake 特权助手（root 运行）：轮询状态文件，把合盖睡眠策略同步给 pmset
STATE="/Library/Application Support/KeepAwake/lid.state"
LOG="/Library/Application Support/KeepAwake/helper.log"

while true; do
  want=0
  if [ -f "$STATE" ]; then
    want=$(<"$STATE")
  fi
  if [[ "$want" != "0" && "$want" != "1" ]]; then
    want=0
  fi

  cur=$(pmset -g | awk '/SleepDisabled/{print $2}')

  if [ "$cur" != "$want" ]; then
    {
      echo "[$(date '+%F %T')] pmset -a disablesleep $want"
      pmset -a disablesleep "$want"
    } >>"$LOG" 2>&1
  fi

  sleep 2
done
