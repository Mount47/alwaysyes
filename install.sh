#!/bin/bash
# ClaudePet 安装器
# 把 hook 脚本装到 ~/.claude/hooks/、合并 hooks 配置进 ~/.claude/settings.json、
# 生成默认 pet-config.json,并(可选)构建菜单栏 app。
# 幂等: 可反复运行, 不会覆盖你 settings.json 里的其他配置。
set -e
cd "$(dirname "$0")"
REPO="$(pwd)"

CLAUDE_DIR="$HOME/.claude"
HOOKS_DST="$CLAUDE_DIR/hooks"
SETTINGS="$CLAUDE_DIR/settings.json"
CONFIG="$CLAUDE_DIR/pet-config.json"
STATE_DIR="$CLAUDE_DIR/pet-state"

command -v jq >/dev/null || { echo "❌ 需要 jq,请先: brew install jq"; exit 1; }

echo "==> 1/5 创建目录"
mkdir -p "$HOOKS_DST" "$STATE_DIR"

echo "==> 2/5 安装 hook 脚本到 $HOOKS_DST"
# _common.sh 是各 hook 共用的取值/写状态逻辑, 必须先装(缺了各 hook 会静默跳过)
for s in _common.sh notify-confirm.sh pet-prompt.sh pet-stop.sh pet-session-start.sh pet-session-end.sh; do
  cp "$REPO/hooks/$s" "$HOOKS_DST/$s"
  chmod +x "$HOOKS_DST/$s"
  echo "     $s"
done

echo "==> 3/5 生成默认配置(已存在则跳过,保留你的开关设置)"
if [ ! -f "$CONFIG" ]; then
  echo '{"enabled":true,"notification":true,"pet":true}' > "$CONFIG"
  echo "     已创建 $CONFIG"
else
  echo "     $CONFIG 已存在, 保留不动"
fi

echo "==> 4/5 合并 hooks 配置进 $SETTINGS"
# settings.json 不存在则从空对象开始
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

N="$HOOKS_DST/notify-confirm.sh"
P="$HOOKS_DST/pet-prompt.sh"
S="$HOOKS_DST/pet-stop.sh"
SS="$HOOKS_DST/pet-session-start.sh"
SE="$HOOKS_DST/pet-session-end.sh"

# 用 jq 合并: 对每个事件, 先滤掉指向本项目脚本的旧条目(保证幂等/不重复),
# 再把本项目的 hook 追加进该事件的数组。其它事件与配置原样保留。
tmp="$(mktemp)"
jq \
  --arg n "$N" --arg p "$P" --arg s "$S" --arg ss "$SS" --arg se "$SE" '
  def add($event; $cmd):
    .hooks[$event] = (
      ((.hooks[$event] // [])
        | map(select(
            ((.hooks // []) | map(.command) | index($cmd)) | not
          ))
      )
      + [ { "hooks": [ { "type": "command", "command": $cmd } ] } ]
    );
  (.hooks //= {})
  | add("Notification"; $n)
  | add("UserPromptSubmit"; $p)
  | add("Stop"; $s)
  | add("SessionStart"; $ss)
  | add("SessionEnd"; $se)
' "$SETTINGS" > "$tmp"

if jq empty "$tmp" 2>/dev/null; then
  mv "$tmp" "$SETTINGS"
  echo "     已合并 Notification / UserPromptSubmit / Stop / SessionStart / SessionEnd (备份见 $SETTINGS.bak.*)"
else
  rm -f "$tmp"
  echo "❌ 合并后 JSON 非法, 已保留原文件"; exit 1
fi

echo "==> 5/5 构建菜单栏 app"
if command -v swiftc >/dev/null; then
  ./build.sh >/dev/null && echo "     ClaudePet.app 已构建"
else
  echo "     跳过(未找到 swiftc / Xcode 命令行工具)"
fi

echo
echo "✅ 安装完成。"
echo "   启动宠物:   open \"$REPO/ClaudePet.app\""
echo "   开机自启:   系统设置 → 通用 → 登录项 → 添加 ClaudePet.app"
echo "   注意: hook 对新的 claude 会话生效, 已有会话请重启。"
