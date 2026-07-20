# ClaudePet

菜单栏状态指示器(MVP)——给正在运行的 Claude Code 当"状态灯"。
有项目需要你点 yes 时菜单栏图标变红并提示是哪个项目,同时弹桌面通知。
奔着后续升级成 Codex 那样的桌面浮动宠物设计,技术栈一路复用。

## 安装(clone 后)

```bash
git clone <本仓库>
cd alwaysyes
./install.sh          # 装 hook 脚本 + 合并配置 + 构建 app
open ClaudePet.app    # 启动
```

`install.sh` 幂等、安全,做四件事:
1. 复制 `hooks/` 三个脚本到 `~/.claude/hooks/`
2. 用 jq 把 hooks 配置**合并**进你的 `~/.claude/settings.json`(不覆盖你原有的任何配置,自动备份)
3. 生成默认 `~/.claude/pet-config.json`(已存在则保留)
4. 用 swiftc 构建 `ClaudePet.app`

依赖:`jq`、`swiftc`(Xcode 命令行工具)。缺 swiftc 只是跳过构建,其余照装。

## 源码 vs 运行时(为什么这样分)

仓库是**唯一事实来源**,`~/.claude/` 下的是**安装产物**(不进 git):

| 在仓库里(git 管理) | 安装到(运行时, install.sh 生成) |
|---|---|
| `hooks/*.sh` 脚本源码 | `~/.claude/hooks/*.sh` |
| —(不存任何人的配置) | `~/.claude/settings.json` 的 hooks 段(合并写入) |
| —(含 token,不入库) | `~/.claude/pet-config.json` |
| `ClaudePet/` swift 源码 | `ClaudePet.app`(.gitignore 排除) |

所以 clone 下来跑 `install.sh` 即可,不需要手工配置。

## 组成

```
状态来源(hook 脚本, 在 ~/.claude/hooks/)          菜单栏 app(本项目)
  notify-confirm.sh  Notification → waiting + 通知      ClaudePet.app
  pet-prompt.sh      UserPromptSubmit → running   ──▶   读 ~/.claude/pet-state/*.json
  pet-stop.sh        Stop → idle                        汇总 → 图标 + 下拉菜单
```

每个会话写一个 `~/.claude/pet-state/<session_id>.json`,互不干扰。app 用 FSEvents 实时监听该目录。

## 图标含义

| 图标 | 含义 |
|---|---|
| 🔴 / 🔴N | 有 N 个项目在等你点 yes |
| 🐥 | 有会话运行中 |
| 🐣 | 全部空闲 |
| 😴 | 已停用 |

下拉菜单逐条列出:`项目名 — 状态 (等待时长)`,waiting 的排最前。

## 三层开关

1. **菜单里点"停用宠物"** —— 最方便,本质是改下面的配置文件
2. **`~/.claude/pet-config.json`** —— 单一事实来源:
   `{ "enabled": 总开关, "notification": 桌面通知, "pet": 状态/宠物 }`
   (只有显式 `false` 才关闭;hook 和 app 都读它)
3. **`~/.claude/settings.json` 的 hooks 段** —— 最硬,摘掉 hook 就彻底不触发

## 仅重新构建 app(改了 swift 源码后)

```bash
./build.sh            # 只编译, 不碰配置
open ClaudePet.app
```

### 开机自启(可选)

系统设置 → 通用 → 登录项 → 添加 `ClaudePet.app`。

## 生效说明

hook 配置对**新会话**加载,已有会话需重启 `claude`。配置对所有项目全局生效。

## 后续(未做)

- 桌面浮动宠物动画帧(当前是菜单栏 emoji 占位)
- 像素美术、喂养/成长互动
- 点击图标跳回对应 IDE
