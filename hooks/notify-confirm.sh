#!/bin/bash
# Claude Code Notification hook: 需要点 yes / 空闲等待时触发。
# 干两件事: ① 弹 macOS 桌面通知(原有功能保留) ② 写状态文件给宠物 app(waiting)。
# 三层开关见 ~/.claude/pet-config.json 的 enabled / notification / pet 字段。
COMMON="$HOME/.claude/hooks/_common.sh"
[ -f "$COMMON" ] || exit 0
. "$COMMON"      # 读走 stdin 载荷($payload), 解出 project/cwd/session_id/tty_id/claude_pid

# 状态写入只受 enabled 门控(菜单栏和宠物都靠状态)；pet 字段由 app 侧控制宠物窗口显隐。
pet_enabled || exit 0

# ① 桌面通知。同样只有显式 false 才算关闭。
notify_on=$(jq -r 'if .notification == false then "false" else "true" end' "$CONFIG" 2>/dev/null)
[ -z "$notify_on" ] && notify_on=true

if [ "$notify_on" = "true" ]; then
  message="$(printf '%s' "$payload" | jq -r '.message // "需要你的确认"')"
  esc_msg="$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  esc_proj="$(printf '%s' "$project" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  osascript -e "display notification \"${esc_msg}\" with title \"Claude Code · ${esc_proj}\" subtitle \"需要你确认\""
fi

# ② 该会话进入 waiting(需要你处理)
pet_write_state waiting
exit 0
