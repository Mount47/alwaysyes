import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var dirSource: DispatchSourceFileSystemObject?
    var dirFD: Int32 = -1
    var refreshTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 确保状态目录存在，否则无法监听
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐣"

        startWatching()
        // 兜底: 每 5 秒刷新一次(处理"等待时长"文案更新 & 陈旧文件清理)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    // MARK: - 监听状态目录变化(实时响应)
    func startWatching() {
        dirFD = open(stateDir.path, O_EVTONLY)
        guard dirFD >= 0 else { return }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: dirFD,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: .main)
        src.setEventHandler { [weak self] in self?.refresh() }
        src.setCancelHandler { [weak self] in
            if let fd = self?.dirFD, fd >= 0 { close(fd) }
        }
        src.resume()
        dirSource = src
    }

    // MARK: - 读配置总开关(第2层)
    func readConfig() -> (enabled: Bool, pet: Bool) {
        guard let data = try? Data(contentsOf: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (true, true) }
        // 只有显式 false 才关闭
        let enabled = (obj["enabled"] as? Bool) ?? true
        let pet = (obj["pet"] as? Bool) ?? true
        return (enabled, pet)
    }

    // MARK: - 读所有会话状态
    func readSessions() -> [SessionState] {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: stateDir, includingPropertiesForKeys: nil) else { return [] }
        var result: [SessionState] = []
        let now = Date()
        for f in files where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            let project = obj["project"] as? String ?? "?"
            let status = obj["status"] as? String ?? "idle"
            let sid = obj["session_id"] as? String ?? f.lastPathComponent
            let ts = (obj["updated_at"] as? Double) ?? 0
            let updated = Date(timeIntervalSince1970: ts)
            // 清理超过 8 小时的陈旧会话文件
            if now.timeIntervalSince(updated) > 8 * 3600 {
                try? FileManager.default.removeItem(at: f)
                continue
            }
            result.append(SessionState(project: project, status: status,
                                       sessionId: sid, updatedAt: updated))
        }
        return result
    }

    // MARK: - 刷新图标与菜单
    func refresh() {
        let cfg = readConfig()
        let sessions = readSessions()

        let overall: OverallState
        if !cfg.enabled || !cfg.pet {
            overall = .disabled
        } else if sessions.contains(where: { $0.status == "waiting" }) {
            overall = .waiting
        } else if sessions.contains(where: { $0.status == "running" }) {
            overall = .running
        } else {
            overall = .idle
        }

        updateIcon(overall, waitingCount: sessions.filter { $0.status == "waiting" }.count)
        buildMenu(overall: overall, sessions: sessions, cfg: cfg)
    }

    func updateIcon(_ state: OverallState, waitingCount: Int) {
        guard let button = statusItem.button else { return }
        switch state {
        case .disabled: button.title = "😴"
        case .waiting:  button.title = waitingCount > 1 ? "🔴\(waitingCount)" : "🔴"
        case .running:  button.title = "🐥"
        case .idle:     button.title = "🐣"
        }
    }

    // MARK: - 构建下拉菜单
    func buildMenu(overall: OverallState, sessions: [SessionState], cfg: (enabled: Bool, pet: Bool)) {
        let menu = NSMenu()

        // 顶部汇总
        let header: String
        switch overall {
        case .disabled: header = "已停用"
        case .waiting:  header = "有项目在等你确认"
        case .running:  header = "运行中"
        case .idle:     header = "空闲"
        }
        let hItem = NSMenuItem(title: header, action: nil, keyEquivalent: "")
        hItem.isEnabled = false
        menu.addItem(hItem)
        menu.addItem(.separator())

        // 逐个项目列出，waiting 的排前面
        let sorted = sessions.sorted { a, b in
            if a.status == b.status { return a.updatedAt > b.updatedAt }
            return statusRank(a.status) < statusRank(b.status)
        }
        if sorted.isEmpty {
            let none = NSMenuItem(title: "(无活动会话)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        } else {
            for s in sorted {
                let mark: String
                switch s.status {
                case "waiting": mark = "🔴"
                case "running": mark = "🐥"
                default:        mark = "· "
                }
                let ago = timeAgo(s.updatedAt)
                let line = "\(mark) \(s.project) — \(statusLabel(s.status)) (\(ago))"
                let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        // 启用/停用 开关(第1层 UI，作用是改第2层 pet-config.json)
        let toggle = NSMenuItem(title: cfg.enabled ? "停用宠物" : "启用宠物",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    func statusRank(_ s: String) -> Int {
        switch s { case "waiting": return 0; case "running": return 1; default: return 2 }
    }
    func statusLabel(_ s: String) -> String {
        switch s { case "waiting": return "等你确认"; case "running": return "运行中"; default: return "空闲" }
    }
    func timeAgo(_ d: Date) -> String {
        let sec = Int(Date().timeIntervalSince(d))
        if sec < 60 { return "\(sec)秒前" }
        if sec < 3600 { return "\(sec/60)分前" }
        return "\(sec/3600)时前"
    }

    // MARK: - 菜单动作
    @objc func toggleEnabled() {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: configPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        let current = (obj["enabled"] as? Bool) ?? true
        obj["enabled"] = !current
        if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? out.write(to: configPath)
        }
        refresh()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
