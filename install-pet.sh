#!/usr/bin/env bash
# install-pet.sh — 从 petdex 画廊安装一只宠物形象到 ~/.claude/pets/<slug>/
#
# 用法:
#   ./install-pet.sh <slug>        # 按 slug 安装, 如 homelander
#   ./install-pet.sh --list [关键词] # 列出可用宠物(可选关键词过滤)
#
# 依赖: curl, jq。宠物精灵图遵循 petdex 规范(8×9 网格, 192×208/帧)。
# 装完在菜单栏"选择宠物形象"里选中即可。

set -euo pipefail
MANIFEST="https://petdex.dev/api/manifest"
PETS_DIR="$HOME/.claude/pets"

command -v jq   >/dev/null || { echo "需要 jq";   exit 1; }
command -v curl >/dev/null || { echo "需要 curl"; exit 1; }

if [ "${1:-}" = "--list" ]; then
  kw="${2:-}"
  echo "拉取 petdex 画廊列表..."
  curl -sL "$MANIFEST" | jq -r --arg kw "$kw" \
    '.pets[] | select(($kw=="") or (.slug|test($kw;"i")) or (.displayName|test($kw;"i"))) | "\(.slug)\t\(.displayName)"' \
    | column -t -s $'\t' | head -60
  echo "(如列表很长, 加关键词过滤: ./install-pet.sh --list cat)"
  exit 0
fi

slug="${1:-}"
[ -n "$slug" ] || { echo "用法: ./install-pet.sh <slug>  |  ./install-pet.sh --list [关键词]"; exit 1; }

echo "查找 '$slug' ..."
entry=$(curl -sL "$MANIFEST" | jq -c --arg s "$slug" '.pets[] | select(.slug==$s)')
[ -n "$entry" ] || { echo "未找到 slug: $slug  (先 ./install-pet.sh --list 查名字)"; exit 1; }

url=$(echo "$entry" | jq -r '.spritesheetUrl')
name=$(echo "$entry" | jq -r '.displayName')
# 保留原扩展名(.webp 或 .png)
ext="${url##*.}"; [ "$ext" = "webp" ] || ext="png"

dest="$PETS_DIR/$slug"
mkdir -p "$dest"
echo "下载 $name 精灵图..."
curl -sL -o "$dest/spritesheet.$ext" "$url"

# 写一份精简 pet.json(记录来源, app 目前只需精灵图)
cat > "$dest/pet.json" <<EOF
{
  "id": "$slug",
  "displayName": "$name",
  "spritesheetPath": "spritesheet.$ext",
  "source": "petdex"
}
EOF

echo "✅ 已安装到 $dest"
echo "   现在点菜单栏图标 → 选择宠物形象 → $slug"
