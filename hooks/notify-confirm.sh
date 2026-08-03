#!/bin/bash
# Claude Code Notification hook: 需要点 yes / 空闲等待时触发。
# 干两件事: ① 弹 macOS 桌面通知(原有功能保留) ② 写状态文件给宠物 app。
# 三层开关见 ~/.claude/pet-config.json 的 enabled / notification / pet 字段。

CONFIG=~/.claude/pet-config.json
STATE_DIR=~/.claude/pet-state

# 读配置开关。注意不能用 jq 的 `// true`,因为 false 会被它当空值替换成 true。
# 只有显式为 false 才算关闭;缺失/读不到都默认开启。
# 状态写入只受 enabled 门控(菜单栏和宠物都靠状态)；pet 字段由 app 侧控制宠物窗口显隐。
enabled=$(jq -r 'if .enabled == false then "false" else "true" end'      "$CONFIG" 2>/dev/null); [ -z "$enabled" ] && enabled=true
notify_on=$(jq -r 'if .notification == false then "false" else "true" end' "$CONFIG" 2>/dev/null); [ -z "$notify_on" ] && notify_on=true

# 总开关关闭 -> 什么都不做
[ "$enabled" = "true" ] || exit 0

# 读取 hook 从 stdin 传入的 JSON
payload="$(cat)"
message="$(printf '%s' "$payload" | jq -r '.message // "需要你的确认"')"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // "unknown"')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"
[ -z "$cwd" ] && cwd="$CLAUDE_PROJECT_DIR"
[ -z "$cwd" ] && cwd="$PWD"
project="$(basename "$cwd")"

# ① 桌面通知
if [ "$notify_on" = "true" ]; then
  esc_msg="$(printf '%s' "$message" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  esc_proj="$(printf '%s' "$project" | sed 's/\\/\\\\/g; s/"/\\"/g')"
  osascript -e "display notification \"${esc_msg}\" with title \"Claude Code · ${esc_proj}\" subtitle \"需要你确认\""
fi

# ② 写状态文件: 该会话进入 waiting(需要你处理)
mkdir -p "$STATE_DIR"
now="$(date +%s)"
# 记录会话所在终端, 供 app 的"一键跳回终端"用。
# ps -o tty= 取的是控制终端(形如 s003); 没有控制终端时输出 ??, 当作取不到。
tty_id="$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')"
if [ -z "$tty_id" ] || [ "$tty_id" = "??" ]; then
  tty_id="$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')"
fi
[ "$tty_id" = "??" ] && tty_id=""
jq -n --arg p "$project" --arg c "$cwd" --arg s "waiting" \
      --arg sid "$session_id" --argjson t "$now" \
      --arg tty "$tty_id" --arg term "${TERM_PROGRAM:-}" \
      '{project:$p, cwd:$c, status:$s, session_id:$sid, updated_at:$t, tty:$tty, term_program:$term}' \
      > "$STATE_DIR/${session_id}.json"

exit 0
