#!/bin/bash
# Claude Code UserPromptSubmit hook: 你提交了指令 -> 该会话标记为 running(干活中)。
COMMON="$HOME/.claude/hooks/_common.sh"
[ -f "$COMMON" ] || exit 0
. "$COMMON"

pet_enabled || exit 0
pet_write_state running
exit 0
