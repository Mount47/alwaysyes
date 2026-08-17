#!/bin/bash
# ClaudePet 卸载器 —— 把 install.sh 装的东西干净摘掉。
#
# 默认只卸载"程序部分", 保留你的数据(配置/会话状态/已下载的宠物形象):
#   ./uninstall.sh
#
# 连数据一起清:
#   ./uninstall.sh --purge
#
# 幂等: 没装过也能跑, 只是什么都不做。改 settings.json 前一定先备份。
set -e
cd "$(dirname "$0")"
REPO="$(pwd)"

CLAUDE_DIR="$HOME/.claude"
HOOKS_DST="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
CONFIG="$CLAUDE_DIR/pet-config.json"
STATE_DIR="$CLAUDE_DIR/pet-state"
POS_FILE="$CLAUDE_DIR/pet-pos.json"
PETS_DIR="$CLAUDE_DIR/pets"
PLIST="$HOME/Library/LaunchAgents/com.local.claudepet.plist"

PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

echo "==> 1/5 停掉正在跑的 app"
if pkill -f "ClaudePet.app/Contents/MacOS/ClaudePet" 2>/dev/null; then
  echo "     已退出"
else
  echo "     未在运行"
fi

echo "==> 2/5 关掉开机自启"
if [ -f "$PLIST" ]; then
  launchctl bootout "gui/$(id -u)/com.local.claudepet" 2>/dev/null || true
  rm -f "$PLIST"
  echo "     已移除 $PLIST"
else
  echo "     未设置"
fi

echo "==> 3/5 从 settings.json 摘掉 hook 条目"
if [ -f "$SETTINGS" ] && command -v jq >/dev/null; then
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  tmp="$(mktemp)"
  # 只删命令路径指向 ~/.claude/hooks/ 下本项目脚本的条目, 其它 hook 原样保留。
  # 删完变成空数组的事件键也一并去掉, 免得留一堆 "Stop": [] 的空壳。
  jq --arg dir "$HOOKS_DST" '
    def ours($cmd): $cmd | startswith($dir + "/") and (
      test("/(_common|notify-confirm|pet-prompt|pet-stop|pet-session-start|pet-session-end)\\.sh$"));
    if .hooks then
      .hooks |= with_entries(
        .value |= map(select(
          ((.hooks // []) | map(.command) | map(ours(.)) | any) | not
        ))
      )
      | .hooks |= with_entries(select(.value | length > 0))
      | if (.hooks | length) == 0 then del(.hooks) else . end
    else . end
  ' "$SETTINGS" > "$tmp"
  if jq empty "$tmp" 2>/dev/null; then
    mv "$tmp" "$SETTINGS"
    echo "     已摘除(备份见 $SETTINGS.bak.*)"
  else
    rm -f "$tmp"
    echo "     ❌ 处理后 JSON 非法, 原文件未动"; exit 1
  fi
else
  echo "     跳过(没有 settings.json 或缺 jq)"
fi

echo "==> 4/5 删掉 hook 脚本"
removed=0
for s in _common.sh notify-confirm.sh pet-prompt.sh pet-stop.sh pet-session-start.sh pet-session-end.sh; do
  [ -f "$HOOKS_DST/$s" ] && { rm -f "$HOOKS_DST/$s"; removed=$((removed + 1)); }
done
echo "     删了 $removed 个"
# 目录空了才删, 别把用户自己的其它 hook 连窝带走
rmdir "$HOOKS_DST" 2>/dev/null && echo "     hooks/ 已空, 一并删除" || true

echo "==> 5/5 数据"
if [ "$PURGE" = "1" ]; then
  rm -rf "$STATE_DIR" "$PETS_DIR"
  rm -f "$CONFIG" "$POS_FILE"
  echo "     已清除配置 / 会话状态 / 宠物形象(--purge)"
else
  echo "     保留: $CONFIG, $STATE_DIR/, $PETS_DIR/, $POS_FILE"
  echo "     要一起清: ./uninstall.sh --purge"
fi

# 装到 PATH 里的软链(install.sh --link 建的), 只在确实指向本仓库时才删
for d in "$HOME/.local/bin" /usr/local/bin; do
  link="$d/claudepet"
  if [ -L "$link" ] && [ "$(readlink "$link")" = "$REPO/bin/claudepet" ]; then
    rm -f "$link" && echo "     已移除软链 $link"
  fi
done

echo
echo "✅ 卸载完成。仓库本身没动, 想彻底清掉直接删目录: $REPO"
echo "   注意: 已开着的 claude 会话仍带着旧 hook, 重启会话才彻底生效。"
