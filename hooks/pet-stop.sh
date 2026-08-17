#!/bin/bash
# Claude Code Stop hook: 一轮回应结束 -> 该会话标记为 review(等你审阅)。
#
# 对应 Codex 桌宠的 "ready for review": 活干完了、diff 摆在那儿等你看, 这和"没事干"
# (idle)不是一回事。app 侧 review 超过一段时间没新动静会自动降级成 idle。
COMMON="$HOME/.claude/hooks/_common.sh"
[ -f "$COMMON" ] || exit 0
. "$COMMON"

pet_enabled || exit 0
pet_write_state review
exit 0
