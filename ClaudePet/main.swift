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
    let status: String       // waiting / running / failed / idle
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

// 汇总后的整体态：等待 > 出错 > 运行 > 空闲 > 停用
enum OverallState {
    case disabled     // 总开关关闭
    case waiting      // 至少一个会话需要你点 yes
    case failed       // 有会话报错(由写 status:"failed" 的 hook 驱动)
    case running      // 有会话在干活
    case idle         // 全部空闲
}

// MARK: - 启动
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 无 Dock 图标，纯菜单栏
app.run()
