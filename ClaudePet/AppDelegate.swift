import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var dirSource: DispatchSourceFileSystemObject?
    var dirFD: Int32 = -1
    var refreshTimer: Timer?
    let pet = PetController()

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

    // MARK: - 读配置(第2层)。enabled=总开关; showPet=是否显示桌面宠物; activePet=已装宠物 slug
    func readConfig() -> (enabled: Bool, showPet: Bool, activePet: String?) {
        guard let data = try? Data(contentsOf: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return (true, true, nil) }
        // 只有显式 false 才关闭
        let enabled = (obj["enabled"] as? Bool) ?? true
        let showPet = (obj["pet"] as? Bool) ?? true
        let activePet = obj["activePet"] as? String
        return (enabled, showPet, activePet)
    }

    // 已装宠物的精灵图路径: ~/.claude/pets/<slug>/spritesheet.webp (或 .png)
    func spritePath(for slug: String?) -> String? {
        guard let slug = slug else { return nil }
        let dir = home.appendingPathComponent(".claude/pets/\(slug)")
        for name in ["spritesheet.webp", "spritesheet.png", "sprite.webp", "sprite.png"] {
            let p = dir.appendingPathComponent(name).path
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return nil
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
            let age = now.timeIntervalSince(updated)

            // 按状态分级判定"卡住/过期"并清理陈旧文件:
            //  - running 正常几秒~几分钟就转 idle; 超 15 分钟没更新 → 会话多半已崩溃
            //  - waiting 可以合理等你很久, 但封顶 2 小时, 避免永远卡红
            //  - idle 不影响宠物, 超 5 分钟只是垃圾文件, 清掉
            let expired: Bool
            switch status {
            case "running": expired = age > 15 * 60
            case "waiting": expired = age > 2 * 3600
            default:        expired = age > 5 * 60   // idle 及未知状态
            }
            if expired {
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
        if !cfg.enabled {
            overall = .disabled
        } else if sessions.contains(where: { $0.status == "waiting" }) {
            overall = .waiting
        } else if sessions.contains(where: { $0.status == "running" }) {
            overall = .running
        } else {
            overall = .idle
        }

        let waitingSessions = sessions.filter { $0.status == "waiting" }
        updateIcon(overall, waitingCount: waitingSessions.count)
        buildMenu(overall: overall, sessions: sessions, cfg: cfg)
        updatePet(overall: overall, cfg: cfg, waiting: waitingSessions)
    }

    // MARK: - 驱动桌面宠物窗口
    func updatePet(overall: OverallState, cfg: (enabled: Bool, showPet: Bool, activePet: String?), waiting: [SessionState]) {
        // 总开关关 或 宠物开关关 → 隐藏窗口
        guard cfg.enabled && cfg.showPet else { pet.hide(); return }
        pet.show()
        pet.setContextMenu(buildPetContextMenu())
        pet.loadSprite(path: spritePath(for: cfg.activePet))

        let emoji: String
        let anim: PetAnim
        var bubble: String? = nil
        switch overall {
        case .waiting:
            emoji = "🐔"; anim = .review    // 有项目等确认 → review 动画
            if let first = waiting.sorted(by: { $0.updatedAt > $1.updatedAt }).first {
                bubble = waiting.count > 1 ? "\(first.project) +\(waiting.count - 1)" : first.project
            }
        case .running:  emoji = "🐥"; anim = .run
        case .idle:     emoji = "🐣"; anim = .idle
        case .disabled: emoji = "😴"; anim = .idle
        }
        pet.update(emoji: emoji, anim: anim, bubble: bubble)
    }

    // 宠物的右键菜单
    func buildPetContextMenu() -> NSMenu {
        let menu = NSMenu()
        let hide = NSMenuItem(title: "隐藏桌面宠物", action: #selector(togglePet), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)
        let reset = NSMenuItem(title: "重置状态", action: #selector(resetState), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 ClaudePet", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
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
    func buildMenu(overall: OverallState, sessions: [SessionState], cfg: (enabled: Bool, showPet: Bool, activePet: String?)) {
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

        // 选择宠物: 列出 ~/.claude/pets/ 下已装的形象
        let installed = installedPets()
        let petMenu = NSMenu()
        if installed.isEmpty {
            let none = NSMenuItem(title: "(未安装, 用 emoji 占位)", action: nil, keyEquivalent: "")
            none.isEnabled = false
            petMenu.addItem(none)
        } else {
            for slug in installed {
                let it = NSMenuItem(title: slug, action: #selector(selectPet(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = slug
                if slug == cfg.activePet { it.state = .on }
                petMenu.addItem(it)
            }
        }
        let petParent = NSMenuItem(title: "选择宠物形象", action: nil, keyEquivalent: "")
        menu.setSubmenu(petMenu, for: petParent)
        menu.addItem(petParent)

        menu.addItem(.separator())

        // 总开关(改 pet-config.json 的 enabled): 关掉后菜单栏转 😴、宠物隐藏、hook 不再写状态
        let toggle = NSMenuItem(title: cfg.enabled ? "停用(全部)" : "启用",
                                action: #selector(toggleEnabled), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)

        // 桌面宠物开关(改 pet 字段): 只控制浮动宠物窗口显隐, 不影响菜单栏与弹窗
        let petToggle = NSMenuItem(title: cfg.showPet ? "隐藏桌面宠物" : "显示桌面宠物",
                                   action: #selector(togglePet), keyEquivalent: "")
        petToggle.target = self
        petToggle.isEnabled = cfg.enabled   // 总开关关了时宠物开关无意义
        menu.addItem(petToggle)

        // 重置状态: 清空所有会话状态文件。万一某会话崩溃留下卡住的 waiting/running, 一键清干净
        let reset = NSMenuItem(title: "重置状态", action: #selector(resetState), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)

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
    // 翻转 pet-config.json 里某个布尔开关(缺失视为 true), 写回后刷新
    private func toggleFlag(_ key: String) {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: configPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        let current = (obj[key] as? Bool) ?? true
        obj[key] = !current
        if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? out.write(to: configPath)
        }
        refresh()
    }

    @objc func toggleEnabled() { toggleFlag("enabled") }
    @objc func togglePet()     { toggleFlag("pet") }

    // 清空所有会话状态文件(手动兜底: 卡住时一键归位)
    @objc func resetState() {
        if let files = try? FileManager.default.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil) {
            for f in files where f.pathExtension == "json" {
                try? FileManager.default.removeItem(at: f)
            }
        }
        refresh()
    }

    // 扫描 ~/.claude/pets/ 下每个含精灵图的子目录, 返回 slug 列表
    func installedPets() -> [String] {
        let petsDir = home.appendingPathComponent(".claude/pets")
        guard let subs = try? FileManager.default.contentsOfDirectory(
            at: petsDir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        return subs.compactMap { url -> String? in
            let slug = url.lastPathComponent
            return spritePath(for: slug) != nil ? slug : nil
        }.sorted()
    }

    // 选择某个宠物形象: 写入 activePet 并刷新
    @objc func selectPet(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String else { return }
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: configPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        obj["activePet"] = slug
        if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? out.write(to: configPath)
        }
        refresh()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
