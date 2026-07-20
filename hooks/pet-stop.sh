#!/bin/bash
# Claude Code Stop hook: 一轮回应结束 -> 该会话标记为 idle(空闲)。
CONFIG=~/.claude/pet-config.json
STATE_DIR=~/.claude/pet-state

enabled=$(jq -r 'if .enabled == false then "false" else "true" end' "$CONFIG" 2>/dev/null); [ -z "$enabled" ] && enabled=true
pet_on=$(jq -r 'if .pet == false then "false" else "true" end'      "$CONFIG" 2>/dev/null); [ -z "$pet_on" ] && pet_on=true
[ "$enabled" = "true" ] || exit 0
[ "$pet_on" = "true" ]  || exit 0

payload="$(cat)"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // "unknown"')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"
[ -z "$cwd" ] && cwd="$CLAUDE_PROJECT_DIR"
[ -z "$cwd" ] && cwd="$PWD"
project="$(basename "$cwd")"

mkdir -p "$STATE_DIR"
now="$(date +%s)"
jq -n --arg p "$project" --arg c "$cwd" --arg s "idle" \
      --arg sid "$session_id" --argjson t "$now" \
      '{project:$p, cwd:$c, status:$s, session_id:$sid, updated_at:$t}' \
      > "$STATE_DIR/${session_id}.json"

exit 0
