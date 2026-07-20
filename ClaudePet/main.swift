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
    let status: String   // waiting / running / idle
    let sessionId: String
    let updatedAt: Date
}

// 汇总后的整体态：等待 > 运行 > 空闲 > 停用
enum OverallState {
    case disabled     // 总开关关闭
    case waiting      // 至少一个会话需要你点 yes
    case running      // 有会话在干活
    case idle         // 全部空闲
}

// MARK: - 启动
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)  // 无 Dock 图标，纯菜单栏
app.run()
