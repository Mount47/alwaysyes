#!/usr/bin/env bash
# install-anime-pets.sh — 安装一组动漫桌宠形象到 ~/.claude/pets/
#
# 用法:
#   ./install-anime-pets.sh              # 装全部四只
#   ./install-anime-pets.sh conan kid    # 只装指定的
#   ./install-anime-pets.sh --list       # 看有哪些
#
# 素材来自 chenxin-dlut/codex-anime-pets(同人二创, MIT 只覆盖该仓库的代码与文档,
# pets/ 下的图仅授权个人非商用)。所以本项目**不打包也不转发**这些图, 只是替你从上游
# 下载到本机 —— 和 install-pet.sh 对 petdex 的处理是同一个口径。详见 README 的版权说明。
#
# 依赖: git。整仓 190MB, 这里用 sparse-checkout 只取需要的目录(四只约 7MB)。

set -euo pipefail

REPO="https://github.com/chenxin-dlut/codex-anime-pets.git"
PETS_DIR="$HOME/.claude/pets"

# slug<TAB>中文显示名。上游用的是规避性的英文名, 菜单里看着认不出是谁, 装的时候改写掉。
PETS=$'conan\t柯南\nkid\t怪盗基德\nshinchan\t蜡笔小新\naiko\t灰原哀'

list_pets() {
  echo "可安装的动漫宠物:"
  printf '%s\n' "$PETS" | while IFS=$'\t' read -r slug name; do
    printf '  %-10s %s\n' "$slug" "$name"
  done
}

[ "${1:-}" = "--list" ] && { list_pets; exit 0; }
command -v git >/dev/null || { echo "❌ 需要 git"; exit 1; }

# 选要装哪几只: 没给参数就全装
if [ $# -gt 0 ]; then
  want=("$@")
  for s in "${want[@]}"; do
    printf '%s\n' "$PETS" | cut -f1 | grep -qx "$s" || {
      echo "❌ 未知 slug: $s"; echo; list_pets; exit 1
    }
  done
else
  # mapfile 在 macOS 自带的 bash 3.2 里没有, 老实用 while read
  want=()
  while IFS= read -r s; do want+=("$s"); done < <(printf '%s\n' "$PETS" | cut -f1)
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "==> 从上游拉取(只取 ${#want[@]} 只, 不是整个 190MB 的仓库)"
git clone --filter=blob:none --no-checkout --depth 1 -q "$REPO" "$tmp/repo"
git -C "$tmp/repo" sparse-checkout init --cone
paths=(); for s in "${want[@]}"; do paths+=("pets/$s"); done
git -C "$tmp/repo" sparse-checkout set "${paths[@]}"
git -C "$tmp/repo" checkout -q

mkdir -p "$PETS_DIR"
installed=0
for slug in "${want[@]}"; do
  src="$tmp/repo/pets/$slug"
  if [ ! -f "$src/spritesheet.webp" ]; then
    echo "  ⚠️  $slug 在上游已不存在, 跳过"   # 上游留了下架流程, 可能哪天就没了
    continue
  fi
  name="$(printf '%s\n' "$PETS" | grep "^$slug"$'\t' | cut -f2)"
  dest="$PETS_DIR/$slug"
  mkdir -p "$dest"
  cp "$src/spritesheet.webp" "$dest/spritesheet.webp"
  cat > "$dest/pet.json" <<EOF
{
  "id": "$slug",
  "displayName": "$name",
  "spritesheetPath": "spritesheet.webp",
  "source": "codex-anime-pets"
}
EOF
  echo "  ✅ $name ($slug)"
  installed=$((installed + 1))
done

[ "$installed" -gt 0 ] || { echo "❌ 一只都没装上"; exit 1; }
echo
echo "已装 $installed 只到 $PETS_DIR"
echo "现在点菜单栏 AY 图标 → 选择宠物形象 → 挑一只"
