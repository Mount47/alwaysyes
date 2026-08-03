#!/bin/bash
# Claude Code Stop hook: 一轮回应结束 -> 该会话标记为 idle(空闲)。
CONFIG=~/.claude/pet-config.json
STATE_DIR=~/.claude/pet-state

enabled=$(jq -r 'if .enabled == false then "false" else "true" end' "$CONFIG" 2>/dev/null); [ -z "$enabled" ] && enabled=true
[ "$enabled" = "true" ] || exit 0

payload="$(cat)"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // "unknown"')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"
[ -z "$cwd" ] && cwd="$CLAUDE_PROJECT_DIR"
[ -z "$cwd" ] && cwd="$PWD"
project="$(basename "$cwd")"

mkdir -p "$STATE_DIR"
now="$(date +%s)"
# 记录会话所在终端, 供 app 的"一键跳回终端"用(取不到时留空)。
tty_id="$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')"
if [ -z "$tty_id" ] || [ "$tty_id" = "??" ]; then
  tty_id="$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')"
fi
[ "$tty_id" = "??" ] && tty_id=""
jq -n --arg p "$project" --arg c "$cwd" --arg s "idle" \
      --arg sid "$session_id" --argjson t "$now" \
      --arg tty "$tty_id" --arg term "${TERM_PROGRAM:-}" \
      '{project:$p, cwd:$c, status:$s, session_id:$sid, updated_at:$t, tty:$tty, term_program:$term}' \
      > "$STATE_DIR/${session_id}.json"

exit 0
