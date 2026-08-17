#!/bin/bash
# Claude Code Stop hook: 一轮回应结束 -> 该会话标记为 idle(空闲)。
COMMON="$HOME/.claude/hooks/_common.sh"
[ -f "$COMMON" ] || exit 0
. "$COMMON"

pet_enabled || exit 0
pet_write_state idle
exit 0
