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
        statusItem.button?.image = StatusIcon.image(for: .idle, waitingCount: 0, style: .vector)

        startWatching()
        // 兜底: 每 5 秒刷新一次(处理"等待时长"文案更新 & 陈旧文件清理)
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
        // 启动时扫一次进程: 把 app 没开着的时候就已经在跑的会话补进来。静默, 不弹通知。
        runScan(notify: false)
    }

    // MARK: - 进程扫描(兜底): 补回活着但没状态的会话, 清掉没记 pid 的残留
    func runScan(notify: Bool) {
        SessionScanner.scan { [weak self] added, removed in
            guard let self = self else { return }
            self.refresh()
            guard notify, added + removed > 0 else { return }
            var parts: [String] = []
            if added > 0   { parts.append("补回 \(added) 个会话") }
            if removed > 0 { parts.append("清掉 \(removed) 条陈旧状态") }
            self.notifyBanner(parts.joined(separator: ", "))
        }
    }

    // 弹一条 macOS 通知。用 osascript(本项目 hook 里也是这个方案, 本机验证可用)。
    func notifyBanner(_ message: String) {
        let esc = message.replacingOccurrences(of: "\\", with: "\\\\")
                         .replacingOccurrences(of: "\"", with: "\\\"")
        let src = "display notification \"\(esc)\" with title \"ClaudePet\" subtitle \"已刷新项目状态\""
        DispatchQueue.global(qos: .utility).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", src]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { return }
            p.waitUntilExit()
        }
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
    func readConfig() -> PetConfig {
        var cfg = PetConfig()
        guard let data = try? Data(contentsOf: configPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return cfg }
        // 只有显式 false 才关闭
        cfg.enabled = (obj["enabled"] as? Bool) ?? true
        cfg.showPet = (obj["pet"] as? Bool) ?? true
        cfg.activePet = obj["activePet"] as? String
        cfg.iconStyle = IconStyle(configValue: obj["iconStyle"] as? String)
        cfg.waitingEmphasis = WaitingEmphasis(configValue: obj["waitingEmphasis"] as? String)
        return cfg
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
            let rawStatus = obj["status"] as? String ?? "idle"
            let sid = obj["session_id"] as? String ?? f.lastPathComponent
            let ts = (obj["updated_at"] as? Double) ?? 0
            let updated = Date(timeIntervalSince1970: ts)
            let age = now.timeIntervalSince(updated)
            let tty = (obj["tty"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let term = (obj["term_program"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let cwd = (obj["cwd"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let pid = (obj["pid"] as? NSNumber).map { pid_t($0.int32Value) }
            let inferred = (obj["inferred"] as? Bool) ?? false

            // review 放久了降级成 idle: 活干完摆着等你看 diff 是有时效的, 过了这阵就
            // 当你已经看过了。只降级不改文件 —— 下轮 hook 一写就自然覆盖。
            let status = (rawStatus == "review" && age > reviewDecayInterval) ? "idle" : rawStatus

            let s = SessionState(project: project, status: status,
                                 sessionId: sid, updatedAt: updated,
                                 tty: tty, termProgram: term, cwd: cwd,
                                 pid: pid, inferred: inferred)

            // 清理规则, 按可靠性排序:
            //  ① 记了 pid 且进程已死 → 立刻清, 不用猜。
            //  ② 否则按状态分级超时兜底。waiting/running/failed 保持原阈值, 防止某个
            //     会话卡在提醒态; 但 pid 还活着时放宽到 12 小时, 免得长任务被误清。
            //  ③ idle 从 5 分钟放宽到 12 小时 —— 5 分钟正是"活会话从菜单里消失"的元凶,
            //     现在有 SessionEnd hook + pid 判活 + 手动刷新兜底, 不需要它了。
            let alive = s.isAlive          // nil = 老文件没记 pid
            if alive == false {
                try? FileManager.default.removeItem(at: f)
                continue
            }
            let limit: TimeInterval
            switch status {
            case "waiting": limit = alive == true ? 12 * 3600 : 40 * 60
            case "running": limit = alive == true ? 12 * 3600 : 15 * 60
            case "failed":  limit = 15 * 60
            default:        limit = 12 * 3600     // idle 及未知状态
            }
            if age > limit {
                try? FileManager.default.removeItem(at: f)
                continue
            }
            result.append(s)
        }

        // 去重: 同一个 pid 若既有 hook 写的、又有扫描推断的(扫描先补上、随后该会话触发了 hook),
        // 以 hook 那份为准, 顺手把推断的文件删掉, 免得菜单里一个会话显示两行。
        let authoritativePids = Set(result.filter { !$0.inferred }.compactMap { $0.pid })
        var kept: [SessionState] = []
        for s in result {
            if s.inferred, let p = s.pid, authoritativePids.contains(p) {
                try? FileManager.default.removeItem(
                    at: stateDir.appendingPathComponent("\(s.sessionId).json"))
                continue
            }
            kept.append(s)
        }
        return kept
    }

    // 汇总: 需要你动手的事(waiting/failed/review)排在机器自己在跑的事(running)前面。
    func overallState(sessions: [SessionState], enabled: Bool) -> OverallState {
        if !enabled { return .disabled }
        if sessions.contains(where: { $0.status == "waiting" }) { return .waiting }
        if sessions.contains(where: { $0.status == "failed" })  { return .failed }
        if sessions.contains(where: { $0.status == "review" })  { return .review }
        if sessions.contains(where: { $0.status == "running" }) { return .running }
        return .idle
    }

    // MARK: - 刷新图标与菜单
    func refresh() {
        let cfg = readConfig()
        let sessions = readSessions()
        let overall = overallState(sessions: sessions, enabled: cfg.enabled)

        let waitingSessions = sessions.filter { $0.status == "waiting" }
        updateIcon(overall, waitingCount: waitingSessions.count, cfg: cfg)
        buildMenu(overall: overall, sessions: sessions, cfg: cfg)
        updatePet(overall: overall, cfg: cfg, waiting: waitingSessions)
        playTransition(overall: overall, waiting: waitingSessions, cfg: cfg)
    }

    // 状态跃迁时放一次性动画。首次刷新不放, 免得一开机就庆祝一遍。
    func playTransition(overall: OverallState, waiting: [SessionState],
                        cfg: PetConfig) {
        let waitingIds = Set(waiting.map { $0.sessionId })
        defer { lastOverall = overall; lastWaitingIds = waitingIds }
        guard cfg.enabled, cfg.showPet, let last = lastOverall else { return }

        if !waitingIds.subtracting(lastWaitingIds).isEmpty {
            pet.playOnce(.jumping, emoji: "❗️", duration: 1.4)   // 新冒出一个要点 yes 的 → 跳一下引起注意
        } else if overall == .review || overall == .idle, last == .running || last == .waiting {
            pet.playOnce(.waving, emoji: "🎉", duration: 2.0)    // 手头的活全干完了 → 挥手庆祝
        }
    }

    // MARK: - 驱动桌面宠物窗口
    func updatePet(overall: OverallState, cfg: PetConfig, waiting: [SessionState]) {
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
            emoji = "🐔"; anim = .waiting   // 有项目等你点 yes → waiting 动画
            // 全部等待项目, 最近的在前(气泡按需展开时逐行列出)
            let sorted = waiting.sorted(by: { $0.updatedAt > $1.updatedAt })
            projects = sorted.map { $0.project }
            // 点气泡里的项目名 → 跳到那个会话所在的终端标签页 / IDE 窗口
            pet.onProjectClick = { idx in
                guard idx >= 0, idx < sorted.count else { return }
                TerminalFocus.focus(tty: sorted[idx].tty,
                                    termProgram: sorted[idx].termProgram,
                                    cwd: sorted[idx].cwd)
            }
        case .failed:   emoji = "💥"; anim = .failed
        case .review:   emoji = "🔍"; anim = .review    // 活干完了, 等你看 diff
        case .running:  emoji = "🐥"; anim = .running
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
        let rescan = NSMenuItem(title: "刷新状态", action: #selector(refreshScan), keyEquivalent: "")
        rescan.target = self
        menu.addItem(rescan)
        let reset = NSMenuItem(title: "重置状态", action: #selector(resetState), keyEquivalent: "")
        reset.target = self
        menu.addItem(reset)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出 ClaudePet", action: #selector(quitApp), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        return menu
    }

    func updateIcon(_ state: OverallState, waitingCount: Int, cfg: PetConfig) {
        guard let button = statusItem.button else { return }
        // 全程纯黑白模板图, 状态靠形状区分, 不靠颜色。编码见 StatusIcon。
        button.image = StatusIcon.image(for: state, waitingCount: waitingCount,
                                        style: cfg.iconStyle, emphasis: cfg.waitingEmphasis)
        // 停用态交给系统的半透明处理, 不自己画第二套灰版 —— 这是 macOS 的标准表达
        button.appearsDisabled = (state == .disabled)
        // waiting 只有一个时也把数字打出来: 纯黑白下这是除形状之外唯一的强化手段
        button.title = (state == .waiting && waitingCount >= 1) ? " \(waitingCount)" : ""
    }

    // MARK: - 构建下拉菜单
    func buildMenu(overall: OverallState, sessions: [SessionState], cfg: PetConfig) {
        let menu = NSMenu()

        // 顶部汇总
        let header: String
        switch overall {
        case .disabled: header = "已停用"
        case .waiting:  header = "有项目在等你确认"
        case .failed:   header = "有任务出错"
        case .review:   header = "有改动等你审阅"
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
                case "review":  mark = "🔍"
                case "running": mark = "🐥"
                default:        mark = "· "
                }
                let ago = timeAgo(s.updatedAt)
                let line = "\(mark) \(s.project) — \(statusLabel(s.status)) (\(ago))"
                // 可点: 跳到该会话所在的终端标签页
                let item = NSMenuItem(title: line, action: #selector(focusSession(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = s
                item.toolTip = s.inferred ? "由进程扫描发现 — 点击跳到该会话" : "跳到该会话所在的终端"
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
                let title = petDisplayName(slug).map { "\($0)  (\(slug))" } ?? slug
                let it = NSMenuItem(title: title, action: #selector(selectPet(_:)), keyEquivalent: "")
                it.target = self
                it.representedObject = slug
                if slug == cfg.activePet { it.state = .on }
                petMenu.addItem(it)
            }
        }
        let petParent = NSMenuItem(title: "选择宠物形象", action: nil, keyEquivalent: "")
        menu.setSubmenu(petMenu, for: petParent)
        menu.addItem(petParent)

        // 菜单栏图标: 矢量重绘 / 位图, 外加 waiting 的三种加重方式。
        // 放在菜单里而不是只留个配置字段, 是为了能在真机菜单栏上直接切着比。
        let iconMenu = NSMenu()
        for (title, value) in [("矢量重绘(锐利)", IconStyle.vector.rawValue),
                               ("原图位图", IconStyle.bitmap.rawValue)] {
            let it = NSMenuItem(title: title, action: #selector(selectIconStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = value
            if cfg.iconStyle.rawValue == value { it.state = .on }
            iconMenu.addItem(it)
        }
        iconMenu.addItem(.separator())
        let emphHeader = NSMenuItem(title: "等待确认时的加重方式", action: nil, keyEquivalent: "")
        emphHeader.isEnabled = false
        iconMenu.addItem(emphHeader)
        for (title, value) in [("实心(最醒目)", WaitingEmphasis.solid.rawValue),
                               ("加粗", WaitingEmphasis.bold.rawValue),
                               ("不变, 只显数字", WaitingEmphasis.plain.rawValue)] {
            let it = NSMenuItem(title: title, action: #selector(selectWaitingEmphasis(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = value
            if cfg.waitingEmphasis.rawValue == value { it.state = .on }
            iconMenu.addItem(it)
        }
        let iconParent = NSMenuItem(title: "菜单栏图标样式", action: nil, keyEquivalent: "")
        menu.setSubmenu(iconMenu, for: iconParent)
        menu.addItem(iconParent)

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

        // 刷新状态: 扫一遍进程, 把"活着但漏检"的会话补回来(hook 是事件驱动的, 会漏)
        let rescan = NSMenuItem(title: "刷新状态", action: #selector(refreshScan), keyEquivalent: "r")
        rescan.target = self
        menu.addItem(rescan)

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
        switch s {
        case "waiting": return 0; case "failed": return 1
        case "review":  return 2; case "running": return 3
        default:        return 4
        }
    }
    func statusLabel(_ s: String) -> String {
        switch s {
        case "waiting": return "等你确认"
        case "failed":  return "出错"
        case "review":  return "等你审阅"
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
    // 宠物的中文/自定义显示名, 取自它目录里的 pet.json。没有或和 slug 一样时返回 nil,
    // 菜单就只显示 slug —— 免得出现 "conan (conan)" 这种废话。
    func petDisplayName(_ slug: String) -> String? {
        for dir in petSearchDirs() {
            let p = dir.appendingPathComponent(slug).appendingPathComponent("pet.json")
            guard let data = try? Data(contentsOf: p),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let name = obj["displayName"] as? String,
                  !name.isEmpty, name != slug
            else { continue }
            return name
        }
        return nil
    }

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

    // 点菜单里的会话行 / 气泡里的项目名 → 把那个终端(或 IDE 窗口)拉到最前
    @objc func focusSession(_ sender: NSMenuItem) {
        guard let s = sender.representedObject as? SessionState else { return }
        TerminalFocus.focus(tty: s.tty, termProgram: s.termProgram, cwd: s.cwd)
    }

    // 手动刷新: 扫进程对账, 有改动时弹条通知说明补/清了什么
    @objc func refreshScan() {
        runScan(notify: true)
    }

    // 选择某个宠物形象: 写入 activePet 并刷新
    @objc func selectPet(_ sender: NSMenuItem) {
        guard let slug = sender.representedObject as? String else { return }
        writeConfig(["activePet": slug])
    }

    // 菜单里选了图标样式 / waiting 强调方式
    @objc func selectIconStyle(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        writeConfig(["iconStyle": v])
    }

    @objc func selectWaitingEmphasis(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        writeConfig(["waitingEmphasis": v])
    }

    // 往 pet-config.json 合并几个键, 其余原样保留(这个文件也可能被用户手改)
    func writeConfig(_ patch: [String: Any]) {
        var obj: [String: Any] = [:]
        if let data = try? Data(contentsOf: configPath),
           let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            obj = parsed
        }
        for (k, v) in patch { obj[k] = v }
        if let out = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? out.write(to: configPath)
        }
        refresh()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }
}
