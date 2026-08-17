#!/bin/bash
# _common.sh — 各 hook 脚本共用的取值与写状态逻辑。
#
# 用法(在 hook 里):
#   COMMON="$HOME/.claude/hooks/_common.sh"
#   [ -f "$COMMON" ] || exit 0      # 缺失就静默跳过, 绝不让 hook 报错影响 Claude Code
#   . "$COMMON"
#   pet_enabled || exit 0
#   pet_write_state running
#
# 注意: source 它时会把 stdin 的 hook 载荷整个读走, 放进 $payload —— 调用方要取别的
# 字段(如 .message)直接从 $payload 里解, 不要再读 stdin。

CONFIG="$HOME/.claude/pet-config.json"
STATE_DIR="$HOME/.claude/pet-state"

# 总开关。注意不能用 jq 的 `// true`,因为 false 会被它当空值替换成 true。
# 只有显式为 false 才算关闭;缺失/读不到都默认开启。
pet_enabled() {
  local v
  v=$(jq -r 'if .enabled == false then "false" else "true" end' "$CONFIG" 2>/dev/null)
  [ -z "$v" ] && v=true
  [ "$v" = "true" ]
}

# ---- 读载荷, 解公共字段 ----
payload="$(cat)"
session_id="$(printf '%s' "$payload" | jq -r '.session_id // "unknown"')"
cwd="$(printf '%s' "$payload" | jq -r '.cwd // ""')"
[ -z "$cwd" ] && cwd="$CLAUDE_PROJECT_DIR"
[ -z "$cwd" ] && cwd="$PWD"
project="$(basename "$cwd")"

# 会话所在终端。ps -o tty= 取的是控制终端(形如 s003); 没有控制终端时输出 ??,
# 当作取不到(VS Code 插件会话就是这种, 它跑在 stdio 上不占终端)。
tty_id="$(ps -o tty= -p $$ 2>/dev/null | tr -d ' ')"
if [ -z "$tty_id" ] || [ "$tty_id" = "??" ]; then
  tty_id="$(ps -o tty= -p $PPID 2>/dev/null | tr -d ' ')"
fi
[ "$tty_id" = "??" ] && tty_id=""

# 会话所属的 claude 进程 pid: 从父进程往上找, 第一个命令名含 claude 的就是。
# app 拿它做 kill(pid,0) 判活 —— 进程没了立刻清状态, 不必等超时瞎猜。
# 找不到就留空, app 自动退回按时间超时的老办法。
claude_pid=""
_p="$PPID"
for _ in 1 2 3 4 5; do
  case "$_p" in ""|0|1) break ;; esac
  case "$(ps -o comm= -p "$_p" 2>/dev/null)" in
    *claude*) claude_pid="$_p"; break ;;
  esac
  _p="$(ps -o ppid= -p "$_p" 2>/dev/null | tr -d ' ')"
done

# ---- 写/删状态文件 ----
# pet_write_state <status>   status: waiting / running / review / idle / failed
#   waiting  等你点 yes            (Notification)
#   running  在干活                (UserPromptSubmit)
#   review   活干完了, 等你看 diff  (Stop)
#   idle     没事干                (会话刚开 / review 放久了自动降级)
#   failed   出错
pet_write_state() {
  mkdir -p "$STATE_DIR"
  jq -n --arg p "$project" --arg c "$cwd" --arg s "$1" \
        --arg sid "$session_id" --argjson t "$(date +%s)" \
        --arg tty "$tty_id" --arg term "${TERM_PROGRAM:-}" \
        --arg pid "$claude_pid" \
        '{project:$p, cwd:$c, status:$s, session_id:$sid, updated_at:$t,
          tty:$tty, term_program:$term,
          pid:($pid | if . == "" then null else tonumber end)}' \
        > "$STATE_DIR/${session_id}.json"
}

pet_remove_state() {
  rm -f "$STATE_DIR/${session_id}.json"
}
