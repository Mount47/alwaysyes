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
claudepet start           # 启动桌面宠物(菜单栏出现圆形徽标)
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

装好后点菜单栏图标 → **选择宠物形象** → 选中它。宠物会从 emoji 变成逐帧动画精灵。菜单里显示的是 `pet.json` 里的 `displayName`(没有就退回 slug)。

### 动漫宠物

另外备了一组动漫形象,一条命令装齐:

```bash
./install-anime-pets.sh              # 柯南 / 怪盗基德 / 蜡笔小新 / 灰原哀, 共约 7MB
./install-anime-pets.sh conan aiko   # 只装指定的
./install-anime-pets.sh --list       # 看有哪些
# 等价于 claudepet pet --anime
```

素材来自 [chenxin-dlut/codex-anime-pets](https://github.com/chenxin-dlut/codex-anime-pets)。上游整仓 190MB,脚本用 `git sparse-checkout` 只取需要的目录,并把上游那套规避性英文名(`aiko` 等)改写成中文显示名。**版权见文末说明 —— 本项目不打包也不转发这些图,只是替你从上游下载到本机。**

除了本脚本装到的 `~/.claude/pets/`,app 还会扫描 `~/.codex/pets/`(Codex App 与 awesome-codex-pet 的位置,`CODEX_HOME` 可覆盖)和 `~/.petdex/pets/`(petdex CLI 的位置),所以用官方渠道装的宠物也能直接选:

```bash
npx petdex install boba                                    # → ~/.petdex/pets/ + ~/.codex/pets/
curl -fsSL https://raw.githubusercontent.com/legeling/awesome-codex-pet/main/scripts/install-pet.sh \
  | bash -s -- firefly--lingxiaotian                       # → ~/.codex/pets/
```

宠物形象遵循 petdex / Codex 精灵图规范:8 列,单帧恒为 192×208px,行数按帧宽高比自动反推(9 行 = 1536×1872;11 行 = 1536×2288,多出的两行是 16 个朝向,本 app 暂不用)。找不到精灵图时自动回退 emoji。

**行语义有两代,app 会自动识别**,因为混用会让动画整体错位(挥手播成向右跑、等待播成跳跃):

| 布局 | 行 | 帧数 |
|---|---|---|
| `codex9` — Codex / petdex 官方动作库 | 0 idle · 1 running-right · 2 running-left · 3 waving · 4 jumping · 5 failed · 6 waiting · 7 running · 8 review | 每行不等,`[6,8,8,4,5,8,6,6,6]` |
| `legacy6` — 本仓库 `make-pet.py` 自产 | 0 idle · 1 wave · 2 run · 3 failed · 4 review · 5 jump(6~8 复用 idle) | 每行恒 6 |

识别方式不看文件名也不看 `pet.json`,而是加载时把整图缩绘到一张小位图,数出每行非空帧数当指纹 —— `legacy6` 是清一色 6 帧,`codex9` 的 row1 有 8 帧且 row3 只有 4 帧。每行循环几帧也用这个实测值,所以 4 帧的挥手行不会播出空白格。`legacy6` 缺的状态(如 `waiting`)自动回退到最接近的行。

帧率按状态给:跑动 100ms、跳跃 110ms、挥手 150ms、其余 ~183ms。

## 图标 / 动画含义

菜单栏是一枚黑白圆形徽标(外环 + 四扇形 + 中心圆,造型见 `resources/image-1.png`)。**全程纯黑白**:它是模板图,由系统按菜单栏深浅自动取色,不带任何自有颜色。状态靠**形状**区分:

| 菜单栏图标 | 宠物动画 | 含义 |
|---|---|---|
| 徽标填实成四块 + 数字 | waiting | 有项目在等你点 yes |
| 徽标 + 感叹号角标 | failed | 有任务出错 |
| 徽标 + 空心角标 | review | 有改动写完了等你审阅 |
| 徽标 + 实心角标 | running | 有会话运行中 |
| 常规徽标 | idle | 全部空闲 |
| 常规徽标 + 系统半透明 | idle | 已停用 |

角标带一圈 **knockout 分离环**(先挖掉一圈透明再画),否则它零间隙贴在徽标上会糊成一起,看着像瑕疵而不像徽标。有角标时徽标缩到 80% 并靠左上,给右下角腾地方 —— 18pt 的画布里不缩的话角标会从徽标身上咬掉一大块。

`waiting` 是这个 app 的核心状态,纯黑白下最难做醒目,所以做成可选:**实心**(默认,把徽标填实再挖出十字缝和中心圆,视觉重量最大且保住十字准星的辨识度)/ **加粗** / **不变只显数字**。菜单里「菜单栏图标样式」可直接切换对比。

> 试过"整体反白"(实心盘挖掉徽标墨迹),实测不行:这个徽标本身墨迹占比就高,负片几乎是空的,反而比常态更不显眼。

图标有两条渲染路径,同样在那个子菜单里切:

- **矢量重绘**(默认)—— 按原图构图用 `NSBezierPath` 重画。原图是三层同心结构,但缩到菜单栏的 18pt 后,环间空隙只剩 0.40px、内细环只剩 0.28px,是亚像素,必然糊成一坨。所以矢量版砍掉内细环和中间那道 hairline,只留这个尺寸下真正看得见的东西,换来任何分辨率都锐利。
- **原图位图** —— `resources/menubar-icon*.png`(已裁掉水印、白转 alpha),忠于原图,但 @1x 下双环会并成一根粗边。强调态没有对应素材,回退矢量绘制。

> 模板图只认 alpha:不透明像素一律被重绘成前景色。所以"白色"必须是**透明**而不是真的填白 —— 位图是全局 `alpha = 255 - 灰度` 转出来的,矢量则用 `.clear` 合成模式挖空,否则在深色菜单栏上会变成一坨实心。
>
> 改了图标几何,跑 `ClaudePet.app/Contents/MacOS/ClaudePet --dump-icons /tmp/icons.png` 可以把六状态 × 两种样式 × 深浅背景一次渲成对比图,比在真机上一个个状态凑出来快。

状态切换时还会插播一次性动画:**新冒出一个要点 yes 的项目 → jumping 跳一下**引起注意,**手头的活全干完 → waving 挥手庆祝** 2 秒,然后回到常态动画。

菜单栏下拉逐条列出:`项目名 — 状态 (等待时长)`,waiting 的排最前。**每一行都可以点**,点了就把该会话所在的终端切到最前。

**桌面宠物的项目气泡是按需显示的**:默认只用动画表达状态,不常驻文字;把鼠标**悬停**到宠物上、或**左键点一下**,才弹出气泡并逐行列出全部正在等待的项目,移开即收起。**点气泡里的项目名**同样跳到对应终端。

气泡走 macOS HUD/tooltip 那一套:深色半透明底 + 细高光描边 + 投影 + 指向宠物的小三角,每行前置状态圆点,鼠标压住的那一行整行高亮。多个项目时顶部加一行计数标题。气泡按项目名的实际长度撑开窗口(上限 300px,再长就中间省略),伸缩时底边和水平中心都不动,所以宠物看上去纹丝不动、只有气泡在头顶长出来。

### 跳回终端能跳多准

hook 会把会话所在的 tty、`$TERM_PROGRAM` 和 cwd 一起写进状态文件:

- **iTerm2 / Apple Terminal**:按 tty 精确定位到那一个标签页并选中(它们的 AppleScript 词典里标签页有 `tty` 属性)。
- **其它终端**(Ghostty / WezTerm / kitty / Alacritty / Warp / VS Code 集成终端 …):没有可脚本化的标签页模型,退化为把那个 app 拉到最前。
- **VS Code / Cursor 插件里的会话**:它跑在 stdio 上,既没有 tty 也没有 `TERM_PROGRAM`。这时靠 cwd 去命中 `~/.claude/ide/*.lock` 里的 `workspaceFolders`,反推出是哪个 IDE 再激活它。

首次点击时 macOS 会弹"允许 ClaudePet 控制 iTerm"的自动化授权框,同意一次即可。本 app 是 ad-hoc 签名,重新构建后签名会变,系统可能再问一次。

## 组成

```
状态来源(hook 脚本, 在 ~/.claude/hooks/)             app(本项目)
  _common.sh          共用: 取 cwd/tty/pid + 写状态       ClaudePet.app
  pet-session-start.sh SessionStart     → idle            读 ~/.claude/pet-state/*.json
  pet-prompt.sh        UserPromptSubmit → running   ──▶   + 扫进程兜底(SessionScanner)
  notify-confirm.sh    Notification     → waiting + 通知  汇总 → 菜单栏图标 + 桌面宠物
  pet-stop.sh          Stop             → review
  pet-session-end.sh   SessionEnd       → 删除状态文件
```

会话状态语义对齐 Codex 桌宠的三态,加上本项目自己的 `failed` / `idle`:

| status | 触发 | 含义 | 宠物动画 |
|---|---|---|---|
| `running` | UserPromptSubmit | 在干活,AI 正在思考或写代码 | running |
| `waiting` | Notification | 等你输入或点 yes | waiting |
| `review` | Stop | 一轮回应结束,diff 摆在那儿等你看 | review |
| `failed` | (暂无 hook 写) | 出错 | failed |
| `idle` | SessionStart / review 超时降级 | 没事干 | idle |

优先级 `waiting > failed > review > running > idle` —— 需要你动手的事排在机器自己在跑的事前面。`review` 超过 **10 分钟**没新动静会自动降级成 `idle`,否则一轮对话结束后宠物会永远停在"检查中",而你早就看过 diff 了。

每个会话写一个 `~/.claude/pet-state/<session_id>.json`,互不干扰。app 用 FSEvents 实时监听该目录。字段:

| 字段 | 用途 |
|---|---|
| `project` / `cwd` | 菜单里显示哪个项目;cwd 还用于反推 IDE 窗口 |
| `status` | `waiting` / `running` / `review` / `idle` / `failed` |
| `session_id` / `updated_at` | 文件名与时效判断 |
| `tty` / `term_program` | 跳回终端 |
| `pid` | 会话所属的 claude 进程,用来判活 |
| `inferred` | true = 扫描推断出来的,不是 hook 写的 |

`status` 里的 `failed` app 侧已就绪(菜单栏变橙、宠物播 failed 动画),但目前没有 hook 会写它 —— 要让工具报错自动变脸,需要再挂一个 `PostToolUse` hook 判断返回体里的错误。

### 为什么会漏检,以及「刷新状态」干了什么

hook 是**事件驱动**的:不发生事件就不写状态。所以有三种情况会漏:

1. 装 hook **之前**就开着的会话 —— 它永远不会补触发 `SessionStart`。
2. 会话开着但你一直没说话 —— 以前只有 `UserPromptSubmit` 才登记,现在 `SessionStart` 已经堵上这个口。
3. 会话异常退出(`kill -9`、关窗口)没触发 `SessionEnd`,留下陈旧状态。

**「刷新状态」**(菜单和宠物右键菜单里都有,快捷键 `R`)直接扫进程对账,绕过 hook:

- `ps -axww` 找出所有 argv[0] 是 `claude` 的进程,`lsof` 批量取它们的 cwd,argv 里的 `--resume=<uuid>` 给出 session_id
- **活着但状态目录里没有** → 补一条。状态由转录文件 `~/.claude/projects/*/<session_id>.jsonl` 的 mtime 推断:近 60 秒还在写算 `running`,否则算 `idle`
- **没记 pid 的老状态文件、其 cwd 下又没有活着的进程** → 当残留清掉
- **hook 写的状态永远优先**,扫描只补缺和清死,绝不会把 `waiting` 覆盖成别的

app 启动时也会静默扫一次(把它没开着时就已经在跑的会话捞回来),平时不做定时扫描。

### 状态过期与清理

清理规则按可靠性排序:

1. **进程判活**(最准):状态文件里记了 `pid`,app 每 5 秒 `kill(pid, 0)` 一下,进程没了立刻清,不用猜。
2. **SessionEnd hook**:会话正常结束直接删文件。
3. **时间超时**(兜底,给没记 pid 的老文件用):`waiting` 40 分钟 / `running` 15 分钟 / `failed` 15 分钟;进程还活着时这两个放宽到 12 小时,免得长任务被误清。`idle` 统一 12 小时 —— 它以前是 5 分钟,而这正是"会话还活着、菜单里却没了"的元凶。

也可随时点菜单/右键的**重置状态**一键清空全部。

## 三层开关

1. **菜单项** —— 最方便:"停用(全部)"、"隐藏桌面宠物";本质是改下面的配置
2. **`~/.claude/pet-config.json`** —— 单一事实来源:
   ```json
   { "enabled": 总开关, "notification": 桌面通知, "pet": 桌面宠物显隐, "activePet": "已选宠物slug",
     "iconStyle": "vector|bitmap", "waitingEmphasis": "solid|bold|plain" }
   ```
   (只有显式 `false` 才关闭;`enabled` 关掉后 hook 不再写状态、菜单栏图标转半透明、宠物隐藏)
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

`install-anime-pets.sh` 装的那四只来自 [codex-anime-pets](https://github.com/chenxin-dlut/codex-anime-pets)。该仓库的 MIT 许可**只覆盖它自己的代码与文档**,`pets/` 下的图是同人二创,上游明确标注仅限个人非商用,且不授予任何底层角色或商标的权利 —— 柯南、基德、灰原哀的相关权利属青山刚昌与小学馆,蜡笔小新属臼井仪人与双叶社。因此本仓库**不打包、不转发**这些图,脚本只是替你从上游下载到本机 `~/.claude/pets/`。上游保留了权利人下架流程,某只哪天消失属正常,app 找不到精灵图会自动回退 emoji。

## 后续(未做)

- 状态机细化:`PreToolUse/PostToolUse` 分出"在敲代码"、`Task` 工具推断子 agent 数、`PreCompact` 扫地动画、`PostToolUse` 报错写 failed
- 60 秒没鼠标动静就睡觉,鼠标一动惊醒
- 贴边 mini 模式(拖到屏幕边缘半隐藏,hover 探头)
- 完成/等待音效 + 免打扰开关
- 用量环(读 Claude Code statusline 的 `rate_limits`,在宠物外圈画 5h / 7d 额度)
- 气泡里直接 Allow/Deny(要接 permission hook)
- 区分"当前活跃会话"与"后台等待项目"(当前会把你正在看的会话也算作等待)
- `claudepet refresh` 命令行版的刷新(现在只有菜单里有;命令行版要在 bash 里重写一遍扫描逻辑,暂不做)
- Homebrew 分发(`brew install claudepet`)
