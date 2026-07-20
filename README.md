# ClaudePet

给正在运行的 Claude Code 当"状态灯 + 桌面宠物"。

- **菜单栏图标**始终反映所有会话状态:有项目等你点 yes 时变红并提示是哪个项目,同时弹桌面通知。
- **桌面浮动宠物**:一只透明背景、可全屏拖动的小宠物,跟着会话状态换动画。形象可从 [petdex](https://petdex.dev) 画廊安装。

## 安装(clone 后)

```bash
git clone <本仓库>
cd alwaysyes
./install.sh          # 装 hook 脚本 + 合并配置 + 构建 app
open ClaudePet.app    # 启动
```

`install.sh` 幂等、安全,做四件事:
1. 复制 `hooks/` 三个脚本到 `~/.claude/hooks/`
2. 用 jq 把 hooks 配置**合并**进你的 `~/.claude/settings.json`(不覆盖原有配置,自动备份)
3. 生成默认 `~/.claude/pet-config.json`(已存在则保留)
4. 用 swiftc 构建 `ClaudePet.app`

依赖:`jq`、`swiftc`(Xcode 命令行工具)、`curl`。缺 swiftc 只是跳过构建,其余照装。

## 桌面宠物

启动后,桌面右下角出现一只宠物(默认 emoji 占位)。

- **拖动**:按住宠物拖到屏幕任意位置(含多显示器、全屏空间),位置会记住。
- **右键宠物**:弹出菜单——隐藏宠物 / 重置状态 / 退出。
- **换形象**:从 petdex 装一只精灵图宠物,再在菜单栏"选择宠物形象"里选中。

### 安装一只宠物形象

```bash
./install-pet.sh --list          # 浏览可用宠物(可加关键词过滤: --list cat)
./install-pet.sh homelander      # 按 slug 安装到 ~/.claude/pets/<slug>/
```

装好后点菜单栏图标 → **选择宠物形象** → 选中它。宠物会从 emoji 变成逐帧动画精灵。

宠物形象遵循 petdex 精灵图规范:8 列 × 9 行网格,每帧 192×208px,行=动画状态(idle/wave/run/failed/review/jump),每态 6 帧循环。找不到精灵图时自动回退 emoji。

## 图标 / 动画含义

| 菜单栏图标 | 宠物动画 | 含义 |
|---|---|---|
| 🔴 / 🔴N | review | 有 N 个项目在等你点 yes |
| 🐥 | run | 有会话运行中 |
| 🐣 | idle | 全部空闲 |
| 😴 | idle | 已停用 |

菜单栏下拉逐条列出:`项目名 — 状态 (等待时长)`,waiting 的排最前。有项目 waiting 时,宠物头顶冒气泡显示是哪个项目。

## 组成

```
状态来源(hook 脚本, 在 ~/.claude/hooks/)          app(本项目)
  notify-confirm.sh  Notification → waiting + 通知      ClaudePet.app
  pet-prompt.sh      UserPromptSubmit → running   ──▶   读 ~/.claude/pet-state/*.json
  pet-stop.sh        Stop → idle                        汇总 → 菜单栏图标 + 桌面宠物
```

每个会话写一个 `~/.claude/pet-state/<session_id>.json`,互不干扰。app 用 FSEvents 实时监听该目录。

### 状态过期与重置

会话正常结束会触发 Stop 转 idle。若会话异常退出留下卡住的状态,app 会按状态分级自动清理:running 超 15 分钟、waiting 超 2 小时、idle 超 5 分钟视为失效。也可随时点菜单/右键的**重置状态**一键清空。

## 三层开关

1. **菜单项** —— 最方便:"停用(全部)"、"隐藏桌面宠物";本质是改下面的配置
2. **`~/.claude/pet-config.json`** —— 单一事实来源:
   ```json
   { "enabled": 总开关, "notification": 桌面通知, "pet": 桌面宠物显隐, "activePet": "已选宠物slug" }
   ```
   (只有显式 `false` 才关闭;`enabled` 关掉后 hook 不再写状态、菜单栏转 😴、宠物隐藏)
3. **`~/.claude/settings.json` 的 hooks 段** —— 最硬,摘掉 hook 就彻底不触发

## 源码 vs 运行时

仓库是**唯一事实来源**,`~/.claude/` 下的是**安装产物**(不进 git):

| 在仓库里(git 管理) | 安装到(运行时) |
|---|---|
| `hooks/*.sh` 脚本源码 | `~/.claude/hooks/*.sh` |
| `ClaudePet/` swift 源码 | `ClaudePet.app`(.gitignore 排除) |
| — | `~/.claude/settings.json` 的 hooks 段(合并写入) |
| — | `~/.claude/pet-config.json` |
| — | `~/.claude/pets/<slug>/`(宠物精灵图,用户本地下载) |

## 仅重新构建 app(改了 swift 源码后)

```bash
./build.sh            # 只编译, 不碰配置
open ClaudePet.app
```

开机自启:系统设置 → 通用 → 登录项 → 添加 `ClaudePet.app`。

## 生效说明

hook 配置对**新会话**加载,已有会话需重启 `claude`。配置对所有项目全局生效。

## 宠物形象来源与版权

桌面宠物的精灵图来自社区画廊 [petdex](https://petdex.dev)(`petdex.dev/api/manifest`)。ClaudePet 只是通过其公开 API **下载到用户本地** `~/.claude/pets/`,不在本仓库打包或转发任何精灵图。

petdex 的美术资源版权归**各自提交者**所有,其中部分为同人作品(fan art)。这些资源不适用本项目的代码许可。如需商用或再分发,请自行确认相应形象的授权,并遵循 petdex 的使用条款与下架流程。

## 后续(未做)

- 更多动画态映射(failed/jump 等)与像素美术
- 区分"当前活跃会话"与"后台等待项目"(当前会把你正在看的会话也算作等待)
- 点击宠物跳回对应 IDE
- 更便捷的分发方式(curl 一行 / npm)
