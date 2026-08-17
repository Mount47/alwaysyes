// SessionScanner — 独立于 hook 的兜底: 直接扫进程, 把"活着但状态目录里没有"的会话补回来。
//
// 为什么需要: hook 是事件驱动的, 会话开着但没交互就不产生任何事件。装 hook 之前就开着的
// 会话、状态文件被手动清掉的会话、以及异常退出没触发 SessionEnd 的残留, 只能靠扫进程对账。
//
// 两条命令各跑一次(不是每进程一次):
//   ps -axww -o pid=,ppid=,tty=,command=   -ww 必须有, 否则 argv 被截断, 读不到 --resume=
//   lsof -a -d cwd -p <pid,pid,…> -Fpn     一次批量拿所有候选进程的 cwd
//
// 原则: hook 写的状态永远优先。扫描只补缺和清死, 绝不把 waiting 覆盖成别的。

import Foundation

struct LiveSession {
    let pid: pid_t
    let cwd: String
    let tty: String?
    let sessionId: String?   // argv 里的 --resume=<uuid>; 新开的会话没有这个参数
}

enum SessionScanner {

    /// 后台扫描, 完成后回主线程。added = 补回来几条, removed = 清掉几条陈旧的。
    static func scan(completion: @escaping (_ added: Int, _ removed: Int) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let live = liveSessions()
            let result = reconcile(live: live)
            DispatchQueue.main.async { completion(result.added, result.removed) }
        }
    }

    // MARK: - 扫进程

    private static func liveSessions() -> [LiveSession] {
        guard let psOut = runCommand("/bin/ps", ["-axww", "-o", "pid=,ppid=,tty=,command="]) else { return [] }

        var cands: [(pid: pid_t, ppid: pid_t, tty: String?, cmd: String)] = []
        for line in psOut.split(separator: "\n") {
            // 形如: "10972  1232 ??  /path/to/claude --resume=… "; command 在最后, 用 maxSplits 保住它
            let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { continue }
            let cmd = String(parts[3])
            guard isClaudeSession(cmd) else { continue }
            let tty = String(parts[2])
            cands.append((pid, ppid, tty == "??" ? nil : tty, cmd))
        }
        guard !cands.isEmpty else { return [] }

        // 插件会多套一层壳进程(父子都是 claude)。丢掉"是另一个候选的父进程"的那个, 只留最里层。
        // 万一父子成环把候选滤光了, 就退回不滤 —— 宁可多一条也别一条不剩。
        let parentPids = Set(cands.map { $0.ppid })
        let leaves = cands.filter { !parentPids.contains($0.pid) }
        if !leaves.isEmpty { cands = leaves }

        // 一次 lsof 拿到所有候选的 cwd
        let cwds = cwdMap(for: cands.map { $0.pid })

        var live: [LiveSession] = []
        for c in cands {
            guard let cwd = cwds[c.pid] else { continue }   // 拿不到 cwd 就没法归属项目, 跳过
            live.append(LiveSession(pid: c.pid, cwd: cwd, tty: c.tty,
                                    sessionId: resumeSessionId(from: c.cmd)))
        }

        // 同一 cwd 下若已有带 session_id 的候选, 丢掉没有 session_id 的(多半是同一会话的壳)。
        // 只做这一种合并 —— 两个都认得出 id 的会话绝不合并, 那是真的两个会话。
        let cwdsWithId = Set(live.filter { $0.sessionId != nil }.map { $0.cwd })
        return live.filter { $0.sessionId != nil || !cwdsWithId.contains($0.cwd) }
    }

    /// argv[0] 的 basename 恰好是 claude 才算会话进程。
    /// 这样能精确排除 `node …/npm view @anthropic-ai/claude-code@latest` 这类噪声, 也排除 ClaudePet 自己。
    private static func isClaudeSession(_ cmd: String) -> Bool {
        guard let argv0 = cmd.split(separator: " ", maxSplits: 1).first else { return false }
        return (argv0 as NSString).lastPathComponent == "claude"
    }

    private static func resumeSessionId(from cmd: String) -> String? {
        guard let r = cmd.range(of: "--resume=") else { return nil }
        let rest = cmd[r.upperBound...]
        let id = rest.prefix { !$0.isWhitespace }
        return id.isEmpty ? nil : String(id)
    }

    private static func cwdMap(for pids: [pid_t]) -> [pid_t: String] {
        let list = pids.map(String.init).joined(separator: ",")
        guard let out = runCommand("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", list, "-Fpn", "-w"]) else { return [:] }
        var map: [pid_t: String] = [:]
        var current: pid_t?
        for line in out.split(separator: "\n") {
            if line.hasPrefix("p") {
                current = pid_t(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = current {
                map[pid] = String(line.dropFirst())
            }
        }
        return map
    }

    // MARK: - 与状态文件对账

    private static func reconcile(live: [LiveSession]) -> (added: Int, removed: Int) {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(at: stateDir, includingPropertiesForKeys: nil) else {
            return (0, 0)
        }
        var existing: [(url: URL, obj: [String: Any])] = []
        for u in urls where u.pathExtension == "json" {
            if let d = try? Data(contentsOf: u),
               let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                existing.append((u, o))
            }
        }

        var removed = 0
        let liveCwds = Set(live.map { $0.cwd })
        let now = Date().timeIntervalSince1970

        // 清死: 记了 pid 的交给 AppDelegate 每次 refresh 判活(那边更及时)。
        // 这里只补它管不了的那类 —— 没记 pid 的老文件, 若其 cwd 下压根没有活着的 claude 进程,
        // 且已经放了 5 分钟以上(免得误杀 hook 刚写完还没来得及被扫到的), 就是残留。
        if !live.isEmpty {
            for e in existing where e.obj["pid"] == nil || e.obj["pid"] is NSNull {
                let cwd = e.obj["cwd"] as? String ?? ""
                let ts = (e.obj["updated_at"] as? Double) ?? 0
                if !liveCwds.contains(cwd), now - ts > 5 * 60 {
                    try? fm.removeItem(at: e.url)
                    removed += 1
                }
            }
        }

        // 补缺 / 补料
        var added = 0
        for s in live {
            // 先把这个进程对应的 session_id 定下来再判断, 顺序反了会误伤:
            // 没有 --resume 的会话要靠转录文件名才知道 id, 不先算出来就会当成"没登记过"而覆盖掉 hook 的状态。
            let transcript = transcriptURL(for: s)
            let sid = s.sessionId
                ?? transcript.map { $0.deletingPathExtension().lastPathComponent }
                ?? "scan-\(s.pid)"

            if let e = existing.first(where: { o in
                (o.obj["session_id"] as? String) == sid
                    || (o.obj["pid"] as? NSNumber).map({ pid_t($0.int32Value) }) == s.pid
            }) {
                enrich(e, with: s)   // 已登记 → 只补 pid/tty, 绝不碰 status
                continue
            }
            if writeInferred(s, sid: sid, transcript: transcript) { added += 1 }
        }
        return (added, removed)
    }

    /// 只补 pid / tty 这类客观事实, 绝不碰 status —— hook 写的状态永远优先。
    /// 老状态文件没有 pid, 补上之后 app 才能对它做 kill(pid,0) 判活。
    private static func enrich(_ e: (url: URL, obj: [String: Any]), with s: LiveSession) {
        var obj = e.obj
        var changed = false
        if obj["pid"] == nil || obj["pid"] is NSNull {
            obj["pid"] = Int(s.pid); changed = true
        }
        if let tty = s.tty, (obj["tty"] as? String ?? "").isEmpty {
            obj["tty"] = tty; changed = true
        }
        guard changed,
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        else { return }
        try? data.write(to: e.url)
    }

    /// 造一条推断出来的状态。标 inferred:true, 与 hook 写的区分开。
    private static func writeInferred(_ s: LiveSession, sid: String, transcript: URL?) -> Bool {
        let mtime = transcript.flatMap { url -> Date? in
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        // 转录文件近 60 秒还在写 → 正在干活; 否则当空闲。推断不出 waiting, 那个只有 hook 说了算。
        let status = (mtime.map { Date().timeIntervalSince($0) < 60 } ?? false) ? "running" : "idle"

        let obj: [String: Any] = [
            "project": (s.cwd as NSString).lastPathComponent,
            "cwd": s.cwd,
            "status": status,
            "session_id": sid,
            "updated_at": (mtime ?? Date()).timeIntervalSince1970,
            "tty": s.tty ?? "",
            "term_program": "",          // 扫不出来; TerminalFocus 会靠 tty 和 cwd 兜底
            "pid": Int(s.pid),
            "inferred": true,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) else { return false }
        try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
        do {
            try data.write(to: stateDir.appendingPathComponent("\(sid).json"))
            return true
        } catch { return false }
    }

    /// 会话的转录文件: ~/.claude/projects/<cwd 的 / 换成 ->/<session_id>.jsonl
    private static func transcriptURL(for s: LiveSession) -> URL? {
        let fm = FileManager.default
        let root = home.appendingPathComponent(".claude/projects")

        if let sid = s.sessionId {
            // 按目录名编码直接命中
            let guess = root.appendingPathComponent(s.cwd.replacingOccurrences(of: "/", with: "-"))
                .appendingPathComponent("\(sid).jsonl")
            if fm.fileExists(atPath: guess.path) { return guess }
            // 编码规则万一不同(比如路径里有 "."), 退化为按文件名全目录找一遍
            if let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
                for d in dirs {
                    let u = d.appendingPathComponent("\(sid).jsonl")
                    if fm.fileExists(atPath: u.path) { return u }
                }
            }
            return nil
        }

        // 没有 session_id: 取该项目目录下最新的一个转录
        let dir = root.appendingPathComponent(s.cwd.replacingOccurrences(of: "/", with: "-"))
        guard let files = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { $0.pathExtension == "jsonl" }.max { a, b in
            let ta = (try? a.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            let tb = (try? b.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            return ta < tb
        }
    }

    // MARK: - 跑外部命令

    private static func runCommand(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
