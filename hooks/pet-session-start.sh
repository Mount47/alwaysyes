#!/bin/bash
# Claude Code SessionStart hook: 会话一开就登记为 idle。
#
# 解决的问题: 之前只有你发消息(UserPromptSubmit)才登记, 所以"开着但还没说话"的会话
# 在菜单栏里完全看不见。SessionStart 在 startup/resume/clear/compact 时都会触发。
COMMON="$HOME/.claude/hooks/_common.sh"
[ -f "$COMMON" ] || exit 0
. "$COMMON"

pet_enabled || exit 0
pet_write_state idle
exit 0
