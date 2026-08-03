import Cocoa

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var dirSource: DispatchSourceFileSystemObject?
    var dirFD: Int32 = -1
    var refreshTimer: Timer?
    let pet = PetController()

    // 上一次刷新的汇总态与等待中的会话集合, 用于判断"刚变成什么样"→ 放一次性动画
    var lastOverall: OverallState?
    var lastWaitingIds: Set<String> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 确保状态目录存在，否则无法监听
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = ayImage(color: nil, dot: nil)

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

    // 宠物精灵图的搜索目录, 依次尝试:
    //   ~/.claude/pets   本项目 install-pet.sh / make-pet.py 生成的
    //   ~/.codex/pets    Codex App 和 awesome-codex-pet 的安装位置(CODEX_HOME 可覆盖)
    //   ~/.petdex/pets   petdex CLI 的安装位置
    // 这样用任何官方渠道装的宠物都能直接在菜单里选, 不用再复制一份。
    func petSearchDirs() -> [URL] {
        var dirs = [home.appendingPathComponent(".claude/pets")]
        if let ch = ProcessInfo.processInfo.environment["CODEX_HOME"], !ch.isEmpty {
            dirs.append(URL(fileURLWithPath: (ch as NSString).expandingTildeInPath)
                .appendingPathComponent("pets"))
        }
        dirs.append(home.appendingPathComponent(".codex/pets"))
        dirs.append(home.appendingPathComponent(".petdex/pets"))
        // 去重(CODEX_HOME 可能就指向 ~/.codex)
        var seen = Set<String>()
        return dirs.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    // 已装宠物的精灵图路径: <搜索目录>/<slug>/spritesheet.webp (或 .png)
    func spritePath(for slug: String?) -> String? {
        guard let slug = slug, !slug.isEmpty else { return nil }
        for dir in petSearchDirs() {
            let sub = dir.appendingPathComponent(slug)
            for name in ["spritesheet.webp", "spritesheet.png", "sprite.webp", "sprite.png"] {
                let p = sub.appendingPathComponent(name).path
                if FileManager.default.fileExists(atPath: p) { return p }
            }
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
            let tty = (obj["tty"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let term = (obj["term_program"] as? String).flatMap { $0.isEmpty ? nil : $0 }

            // 按状态分级判定"卡住/过期"并清理陈旧文件:
            //  - running 正常几秒~几分钟就转 idle; 超 15 分钟没更新 → 会话多半已崩溃
            //  - waiting 会话若正常收尾会转 idle; 超 40 分钟没更新多半是异常退出没触发
            //    Stop(如直接关窗口/切权限模式), 视为失效清掉, 避免宠物永远卡红
            //  - failed 只是提醒你看一眼, 15 分钟后自动消气
            //  - idle 不影响宠物, 超 5 分钟只是垃圾文件, 清掉
            let expired: Bool
            switch status {
            case "running": expired = age > 15 * 60
            case "waiting": expired = age > 40 * 60
            case "failed":  expired = age > 15 * 60
            default:        expired = age > 5 * 60   // idle 及未知状态
            }
            if expired {
                try? FileManager.default.removeItem(at: f)
                continue
            }
            result.append(SessionState(project: project, status: status,
                                       sessionId: sid, updatedAt: updated,
                                       tty: tty, termProgram: term))
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
        } else if sessions.contains(where: { $0.status == "failed" }) {
            overall = .failed
        } else if sessions.contains(where: { $0.status == "running" }) {
            overall = .running
        } else {
            overall = .idle
        }

        let waitingSessions = sessions.filter { $0.status == "waiting" }
        updateIcon(overall, waitingCount: waitingSessions.count)
        buildMenu(overall: overall, sessions: sessions, cfg: cfg)
        updatePet(overall: overall, cfg: cfg, waiting: waitingSessions)
        playTransition(overall: overall, waiting: waitingSessions, cfg: cfg)
    }

    // 状态跃迁时放一次性动画。首次刷新不放, 免得一开机就庆祝一遍。
    func playTransition(overall: OverallState, waiting: [SessionState],
                        cfg: (enabled: Bool, showPet: Bool, activePet: String?)) {
        let waitingIds = Set(waiting.map { $0.sessionId })
        defer { lastOverall = overall; lastWaitingIds = waitingIds }
        guard cfg.enabled, cfg.showPet, let last = lastOverall else { return }

        if !waitingIds.subtracting(lastWaitingIds).isEmpty {
            pet.playOnce(.jump, emoji: "❗️", duration: 1.4)     // 新冒出一个要点 yes 的 → 跳一下引起注意
        } else if overall == .idle, last == .running || last == .waiting {
            pet.playOnce(.wave, emoji: "🎉", duration: 2.0)     // 手头的活全干完了 → 挥手庆祝
        }
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
        var projects: [String] = []
        switch overall {
        case .waiting:
            emoji = "🐔"; anim = .review    // 有项目等确认 → review 动画
            // 全部等待项目, 最近的在前(气泡按需展开时逐行列出)
            let sorted = waiting.sorted(by: { $0.updatedAt > $1.updatedAt })
            projects = sorted.map { $0.project }
            // 点气泡里的项目名 → 跳到那个会话所在的终端标签页
            pet.onProjectClick = { idx in
                guard idx >= 0, idx < sorted.count else { return }
                TerminalFocus.focus(tty: sorted[idx].tty, termProgram: sorted[idx].termProgram)
            }
        case .failed:   emoji = "💥"; anim = .failed
        case .running:  emoji = "🐥"; anim = .run
        case .idle:     emoji = "🐣"; anim = .idle
        case .disabled: emoji = "😴"; anim = .idle
        }
        if projects.isEmpty { pet.onProjectClick = nil }
        pet.update(emoji: emoji, anim: anim, waitingProjects: projects)
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
        // 品牌图标 "AY" 常驻, 用颜色/红点编码状态(方案A)
        switch state {
        case .idle:
            button.image = ayImage(color: nil, dot: nil)      // 模板色, 跟随菜单栏深浅
            button.title = ""
        case .running:
            button.image = ayImage(color: nil, dot: .systemGray) // 灰点=在动
            button.title = ""
        case .waiting:
            button.image = ayImage(color: .systemRed, dot: .systemRed) // 红字+红点, 最醒目
            button.title = waitingCount > 1 ? " \(waitingCount)" : ""
        case .failed:
            button.image = ayImage(color: .systemOrange, dot: .systemOrange) // 橙=有任务出错
            button.title = ""
        case .disabled:
            button.image = ayImage(color: .systemGray, dot: nil) // 灰字=停用
            button.title = ""
        }
    }

    // 画 "AY" 菜单栏图标。color=nil → 模板图(自动适配深/浅色); 否则彩色图。
    // dot 非空时在右上角画一个小圆点。
    func ayImage(color: NSColor?, dot: NSColor?) -> NSImage {
        let w: CGFloat = 30, h: CGFloat = 18
        let img = NSImage(size: NSSize(width: w, height: h))
        img.lockFocus()
        let font = NSFont.systemFont(ofSize: 15, weight: .heavy)
        let fg = color ?? .black
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: fg,
            .kern: -1.0,                 // 紧凑字距, 两字母不太散
        ]
        let s = NSAttributedString(string: "AY", attributes: attrs)
        let sz = s.size()
        s.draw(at: NSPoint(x: (w - sz.width)/2 - 3, y: (h - sz.height)/2))
        if let dc = dot {
            dc.setFill()
            let r: CGFloat = 5
            NSBezierPath(ovalIn: NSRect(x: w - r - 1, y: h - r - 1, width: r, height: r)).fill()
        }
        img.unlockFocus()
        img.isTemplate = (color == nil)   // 无色 → 模板图跟随系统; 有色 → 保留彩色
        return img
    }

    // MARK: - 构建下拉菜单
    func buildMenu(overall: OverallState, sessions: [SessionState], cfg: (enabled: Bool, showPet: Bool, activePet: String?)) {
        let menu = NSMenu()

        // 顶部汇总
        let header: String
        switch overall {
        case .disabled: header = "已停用"
        case .waiting:  header = "有项目在等你确认"
        case .failed:   header = "有任务出错"
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
                case "failed":  mark = "💥"
                case "running": mark = "🐥"
                default:        mark = "· "
                }
                let ago = timeAgo(s.updatedAt)
                let line = "\(mark) \(s.project) — \(statusLabel(s.status)) (\(ago))"
                // 可点: 跳到该会话所在的终端标签页
                let item = NSMenuItem(title: line, action: #selector(focusSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s
                item.toolTip = "跳到该会话所在的终端"
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
        switch s { case "waiting": return 0; case "failed": return 1; case "running": return 2; default: return 3 }
    }
    func statusLabel(_ s: String) -> String {
        switch s {
        case "waiting": return "等你确认"
        case "failed":  return "出错"
        case "running": return "运行中"
        default:        return "空闲"
        }
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

    // 扫描所有搜索目录下每个含精灵图的子目录, 返回去重后的 slug 列表
    func installedPets() -> [String] {
        var slugs: [String] = []
        var seen = Set<String>()
        for dir in petSearchDirs() {
            guard let subs = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for url in subs {
                let slug = url.lastPathComponent
                guard !seen.contains(slug), spritePath(for: slug) != nil else { continue }
                seen.insert(slug)
                slugs.append(slug)
            }
        }
        return slugs.sorted()
    }

    // 点菜单里的会话行 / 气泡里的项目名 → 把那个终端拉到最前
    @objc func focusSession(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? SessionState else { return }
        TerminalFocus.focus(tty: s.tty, termProgram: s.termProgram)
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
