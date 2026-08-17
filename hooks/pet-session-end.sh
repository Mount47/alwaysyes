#!/bin/bash
# Claude Code SessionEnd hook: 会话结束 -> 删掉它的状态文件, 菜单里立刻消失。
#
# 不看 enabled 开关: 清理垃圾在任何情况下都是对的, 关掉宠物也不该留下陈旧状态。
COMMON="$HOME/.claude/hooks/_common.sh"
[ -f "$COMMON" ] || exit 0
. "$COMMON"

pet_remove_state
exit 0
