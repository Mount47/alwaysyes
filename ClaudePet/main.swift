// ClaudePet — 菜单栏状态指示器 (MVP)
// 监听 ~/.claude/pet-state/*.json，图标反映所有 Claude Code 会话的汇总状态。
// 有会话 waiting(需要点 yes)时图标醒目提醒，下拉菜单列出是哪个项目在等。
// 三层开关的第2层配置: ~/.claude/pet-config.json

import Cocoa

// MARK: - 路径常量
let home = FileManager.default.homeDirectoryForCurrentUser
let stateDir = home.appendingPathComponent(".claude/pet-state")
let configPath = home.appendingPathComponent(".claude/pet-config.json")

// MARK: - 单个会话状态模型
struct SessionState {
    let project: String
    let status: String       // waiting / running / review / failed / idle
    let sessionId: String
    let updatedAt: Date
    let tty: String?         // 该会话所在终端的 tty, 用于一键跳回去
    let termProgram: String? // $TERM_PROGRAM, 如 iTerm.app / Apple_Terminal / ghostty
    let cwd: String?         // 会话工作目录, 跳转时用来匹配 IDE 窗口
    let pid: pid_t?          // 会话所属的 claude 进程, 用来判活(hook 记录, 老文件可能没有)
    let inferred: Bool       // true = 扫描进程推断出来的, 不是 hook 写的

    // 进程还活着吗? 没记 pid 的老状态文件返回 nil(交给按时间超时的老办法)
    var isAlive: Bool? {
        guard let pid = pid, pid > 0 else { return nil }
        // kill(pid, 0): 进程存在返回 0; ESRCH 表示没这个进程; EPERM 表示存在但不是我们能管的
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH ? true : false
    }
}

// 汇总后的整体态：等待 > 出错 > 审阅 > 运行 > 空闲 > 停用
//
// 状态语义对齐 Codex 桌宠: running(在干活) / waiting(等你输入或确认) /
// review(代码写完了等你看 diff)。review 排在 running 之前 —— 需要你动手的事
// 优先于机器自己在跑的事。
enum OverallState {
    case disabled     // 总开关关闭
    case waiting      // 至少一个会话需要你点 yes
    case failed       // 有会话报错(由写 status:"failed" 的 hook 驱动)
    case review       // 有会话干完了, 等你看改动
    case running      // 有会话在干活
    case idle         // 全部空闲
}

// review 放置多久没新动静就降级成 idle。不这么做的话, 一轮对话结束后宠物会永远
// 停在"检查中"—— 你早就看过 diff 了, 它还在那儿举着。
let reviewDecayInterval: TimeInterval = 10 * 60

// MARK: - ~/.claude/pet-config.json 的内容
struct PetConfig {
    var enabled = true                                  // 总开关
    var showPet = true                                  // 桌面宠物窗口显隐
    var activePet: String?                              // 当前选中的宠物形象 slug
    var iconStyle: IconStyle = .vector                  // 菜单栏图标: 矢量重绘 / 位图
    var waitingEmphasis: WaitingEmphasis = .solid       // waiting 时图标怎么加重
}

// MARK: - 启动
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate

// `ClaudePet --dump-state`: 不起界面, 把 app 眼里的会话状态和汇总态打出来就退出。
// 排查"菜单栏为什么是这个颜色"时不用猜 —— 它走的就是 app 自己那套读取与降级逻辑。
if CommandLine.arguments.contains("--dump-state") {
    let sessions = delegate.readSessions()
    for s in sessions.sorted(by: { delegate.statusRank($0.status) < delegate.statusRank($1.status) }) {
        let age = Int(Date().timeIntervalSince(s.updatedAt))
        print("\(s.project)\t\(s.status)\t\(age)s\t\(s.inferred ? "inferred" : "hook")")
    }
    let cfg = delegate.readConfig()
    print("overall: \(delegate.overallState(sessions: sessions, enabled: cfg.enabled))")
    exit(0)
}

// `ClaudePet --dump-icons <out.png>`: 把六状态 × 两种样式 × 深浅背景渲染成一张对比图。
// 必须在 app bundle 里跑 —— 位图那条路径走 Bundle.main, 外面的测试程序加载不到资源。
if let i = CommandLine.arguments.firstIndex(of: "--dump-icons") {
    let out = CommandLine.arguments.count > i + 1 ? CommandLine.arguments[i + 1] : "/tmp/icons.png"
    IconSheet.write(to: out)
    exit(0)
}

app.setActivationPolicy(.accessory)  // 无 Dock 图标，纯菜单栏
app.run()
