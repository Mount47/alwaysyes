# ClaudePet

给正在运行的 Claude Code 当"状态灯 + 桌面宠物"。**轻量、macOS 原生**(Swift/AppKit,几 MB,无 Electron),专注把 mac 上"一眼看到该去点 yes"这件事做顺。

- **菜单栏图标**始终反映所有会话状态:有项目等你点 yes 时变红并提示是哪个项目,同时弹桌面通知。
- **桌面浮动宠物**:一只透明背景、可全屏拖动的小宠物,跟着会话状态换动画。形象可从 [petdex](https://petdex.dev) 画廊安装。

> 平台:**仅 macOS**(依赖 Cocoa/AppKit)。需要跨平台(Windows/Linux)或联动实体硬件桌宠,可以看看 [Seeed-Solution/vibe-pet](https://github.com/Seeed-Solution/vibe-pet)。

## 安装(clone 后)

```bash
git clone <本仓库>
cd alwaysyes
./install.sh              # 装 hook 脚本 + 合并配置 + 构建 app
bin/claudepet start       # 启动
```

想让 `claudepet` 命令全局可用,把 `bin/` 加进 PATH,或建个软链:

```bash
ln -s "$PWD/bin/claudepet" /usr/local/bin/claudepet   # 之后可直接 claudepet start
```

`install.sh` 幂等、安全,做四件事:
1. 复制 `hooks/` 三个脚本到 `~/.claude/hooks/`
2. 用 jq 把 hooks 配置**合并**进你的 `~/.claude/settings.json`(不覆盖原有配置,自动备份)
3. 生成默认 `~/.claude/pet-config.json`(已存在则保留)
4. 用 swiftc 构建 `ClaudePet.app`

依赖:`jq`、`swiftc`(Xcode 命令行工具)、`curl`。缺 swiftc 只是跳过构建,其余照装。

## 命令行(claudepet)

```bash
claudepet start           # 启动桌面宠物(菜单栏出现 AY 图标)
claudepet stop            # 退出桌面宠物
claudepet install         # 安装 hooks 并首次构建 app(幂等)
claudepet status          # 命令行查看各项目当前状态
claudepet pet --list [kw] # 列出 petdex 可安装的宠物形象
claudepet pet <slug>      # 安装一只宠物形象
```

## 桌面宠物

启动后,桌面右下角出现一只宠物(默认 emoji 占位)。

- **拖动**:按住宠物拖到屏幕任意位置(含多显示器、全屏空间),位置会记住。
- **右键宠物**:弹出菜单——隐藏宠物 / 重置状态 / 退出。
- **换形象**:从 petdex 装一只精灵图宠物,再在菜单栏"选择宠物形象"里选中。
- **点击穿透**:鼠标只被画到实际像素的地方拦截,宠物周围的透明区域点下去会落到底下的窗口,不挡事。
- **一键跳回终端**:点气泡里的项目名(或菜单里的会话行),把那个会话所在的终端切到最前。

### 安装一只宠物形象

```bash
./install-pet.sh --list          # 浏览可用宠物(可加关键词过滤: --list cat)
./install-pet.sh homelander      # 按 slug 安装到 ~/.claude/pets/<slug>/
```

装好后点菜单栏图标 → **选择宠物形象** → 选中它。宠物会从 emoji 变成逐帧动画精灵。

除了本脚本装到的 `~/.claude/pets/`,app 还会扫描 `~/.codex/pets/`(Codex App 与 awesome-codex-pet 的位置,`CODEX_HOME` 可覆盖)和 `~/.petdex/pets/`(petdex CLI 的位置),所以用官方渠道装的宠物也能直接选:

```bash
npx petdex install boba                                    # → ~/.petdex/pets/ + ~/.codex/pets/
curl -fsSL https://raw.githubusercontent.com/legeling/awesome-codex-pet/main/scripts/install-pet.sh \
  | bash -s -- firefly--lingxiaotian                       # → ~/.codex/pets/
```

宠物形象遵循 petdex / Codex 精灵图规范,两代都支持:v1 是 8 列 × 9 行(1536×1872),v2 是 8 列 × 11 行(1536×2288,多出的两行是 16 个朝向,本 app 暂不用)。单帧恒为 192×208px,行=动画状态(idle/wave/run/failed/review/jump),每态 6 帧循环。行数按帧宽高比自动反推,不写死。找不到精灵图时自动回退 emoji。

## 图标 / 动画含义

菜单栏是常驻的 **AY** 品牌图标(项目缩写),用颜色和红点编码状态:

| 菜单栏 AY | 宠物动画 | 含义 |
|---|---|---|
| AY 变红 + 红点(多个时跟数字) | review | 有项目在等你点 yes |
| AY 变橙 + 橙点 | failed | 有任务出错 |
| AY + 灰点 | run | 有会话运行中 |
| AY(模板色,随深浅色菜单栏) | idle | 全部空闲 |
| AY 变灰 | idle | 已停用 |

状态切换时还会插播一次性动画:**新冒出一个要点 yes 的项目 → jump 跳一下**引起注意,**手头的活全干完 → wave 挥手庆祝** 2 秒,然后回到常态动画。

菜单栏下拉逐条列出:`项目名 — 状态 (等待时长)`,waiting 的排最前。**每一行都可以点**,点了就把该会话所在的终端切到最前。

**桌面宠物的项目气泡是按需显示的**:默认只用动画表达状态,不常驻文字;把鼠标**悬停**到宠物上、或**左键点一下**,才弹出气泡并逐行列出全部正在等待的项目,移开即收起。项目多时气泡向上伸展,不遮挡宠物。**点气泡里的项目名**同样跳到对应终端。

### 跳回终端能跳多准

hook 会把会话所在的 tty 和 `$TERM_PROGRAM` 一起写进状态文件:

- **iTerm2 / Apple Terminal**:按 tty 精确定位到那一个标签页并选中(它们的 AppleScript 词典里标签页有 `tty` 属性)。
- **其它终端**(VS Code 集成终端 / Ghostty / WezTerm / kitty / Alacritty / Warp …):没有可脚本化的标签页模型,退化为把那个 app 拉到最前。

首次点击时 macOS 会弹"允许 ClaudePet 控制 iTerm"的自动化授权框,同意一次即可。本 app 是 ad-hoc 签名,重新构建后签名会变,系统可能再问一次。

## 组成

```
状态来源(hook 脚本, 在 ~/.claude/hooks/)          app(本项目)
  notify-confirm.sh  Notification → waiting + 通知      ClaudePet.app
  pet-prompt.sh      UserPromptSubmit → running   ──▶   读 ~/.claude/pet-state/*.json
  pet-stop.sh        Stop → idle                        汇总 → 菜单栏图标 + 桌面宠物
```

每个会话写一个 `~/.claude/pet-state/<session_id>.json`,互不干扰。app 用 FSEvents 实时监听该目录。字段:`project / cwd / status / session_id / updated_at / tty / term_program`,后两个用于跳回终端。

`status` 除 `waiting / running / idle` 外还认 `failed`(菜单栏变橙、宠物播 failed 动画)。app 侧已就绪,但目前没有 hook 会写它 —— 要让工具报错自动变脸,需要再挂一个 `PostToolUse` hook 判断返回体里的错误。

### 状态过期与重置

会话正常结束会触发 Stop 转 idle。若会话异常退出留下卡住的状态,app 会按状态分级自动清理:running 超 15 分钟、waiting 超 40 分钟、failed 超 15 分钟、idle 超 5 分钟视为失效。也可随时点菜单/右键的**重置状态**一键清空。

## 三层开关

1. **菜单项** —— 最方便:"停用(全部)"、"隐藏桌面宠物";本质是改下面的配置
2. **`~/.claude/pet-config.json`** —— 单一事实来源:
   ```json
   { "enabled": 总开关, "notification": 桌面通知, "pet": 桌面宠物显隐, "activePet": "已选宠物slug" }
   ```
   (只有显式 `false` 才关闭;`enabled` 关掉后 hook 不再写状态、菜单栏 AY 变灰、宠物隐藏)
3. **`~/.claude/settings.json` 的 hooks 段** —— 最硬,摘掉 hook 就彻底不触发

## 源码 vs 运行时

仓库是**唯一事实来源**,`~/.claude/` 下的是**安装产物**(不进 git):

| 在仓库里(git 管理) | 安装到(运行时) |
|---|---|
| `hooks/*.sh` 脚本源码 | `~/.claude/hooks/*.sh` |
| `ClaudePet/` swift 源码 | `ClaudePet.app`(.gitignore 排除) |
| — | `~/.claude/settings.json` 的 hooks 段(合并写入) |
| — | `~/.claude/pet-config.json` |
| — | `~/.claude/pets/<slug>/`(宠物精灵图,用户本地下载;另会读 `~/.codex/pets/`、`~/.petdex/pets/`) |

## 仅重新构建 app(改了 swift 源码后)

```bash
./build.sh                # 只编译, 不碰配置
bin/claudepet start       # 重启宠物
```

开机自启:系统设置 → 通用 → 登录项 → 添加 `ClaudePet.app`。

## 生效说明

hook 配置对**新会话**加载,已有会话需重启 `claude`。配置对所有项目全局生效。

## 宠物形象来源与版权

桌面宠物的精灵图来自社区画廊 [petdex](https://petdex.dev)(`petdex.dev/api/manifest`)。ClaudePet 只是通过其公开 API **下载到用户本地** `~/.claude/pets/`,不在本仓库打包或转发任何精灵图。

petdex 的美术资源版权归**各自提交者**所有,其中部分为同人作品(fan art)。这些资源不适用本项目的代码许可。如需商用或再分发,请自行确认相应形象的授权,并遵循 petdex 的使用条款与下架流程。

## 后续(未做)

- 状态机细化:`PreToolUse/PostToolUse` 分出"在敲代码"、`Task` 工具推断子 agent 数、`PreCompact` 扫地动画、`PostToolUse` 报错写 failed
- 60 秒没鼠标动静就睡觉,鼠标一动惊醒
- 贴边 mini 模式(拖到屏幕边缘半隐藏,hover 探头)
- 完成/等待音效 + 免打扰开关
- 用量环(读 Claude Code statusline 的 `rate_limits`,在宠物外圈画 5h / 7d 额度)
- 气泡里直接 Allow/Deny(要接 permission hook)
- 区分"当前活跃会话"与"后台等待项目"(当前会把你正在看的会话也算作等待)
- Homebrew 分发(`brew install claudepet`)
