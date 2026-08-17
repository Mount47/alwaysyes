// TerminalFocus — 把某个会话对应的终端窗口/标签页拉到最前
//
// 状态文件里带 tty(如 /dev/ttys003, 由 hook 用 `ps -o tty=` 取)和 term_program($TERM_PROGRAM)。
// iTerm2 / Apple Terminal 的 AppleScript 词典里标签页有 tty 属性, 能精确定位到那一个标签页;
// 其它终端(Ghostty/WezTerm/kitty/Alacritty/Warp...)没有可脚本化的标签页模型, 退化为把 app 拉到最前。
//
// 注意: 用 AppleScript 控制别的 app 需要系统"自动化"权限, 首次点击会弹授权框。
// 本 app 是 ad-hoc 签名, 每次重新构建签名会变, 系统可能再问一次。

import Cocoa

enum TerminalFocus {

    // TERM_PROGRAM 里的关键字 → bundle id。顺序有意义: iterm 要排在 terminal 前面。
    private static let known: [(keys: [String], bundleId: String)] = [
        (["iterm"],                      "com.googlecode.iterm2"),
        (["apple_terminal", "terminal"], "com.apple.Terminal"),
        (["ghostty"],                    "com.mitchellh.ghostty"),
        (["wezterm"],                    "com.github.wez.wezterm"),
        (["kitty"],                      "net.kovidgoyal.kitty"),
        (["alacritty"],                  "org.alacritty"),
        (["warp"],                       "dev.warp.Warp-Stable"),
        (["vscode"],                     "com.microsoft.VSCode"),
        (["hyper"],                      "co.zeit.hyper"),
        (["tabby"],                      "org.tabby"),
    ]

    // 入口: 异步执行, 不阻塞菜单栏。cwd 用于 VS Code 插件那类"不占终端"的会话兜底。
    static func focus(tty rawTTY: String?, termProgram: String?, cwd: String?) {
        let prog = (termProgram ?? "").lowercased()
        let tty = normalizeTTY(rawTTY)
        DispatchQueue.global(qos: .userInitiated).async {
            // 1) 能按 tty 精确定位的两家。app 没在跑就别试 —— tell application 会把它启动起来。
            if let tty = tty {
                if prog.isEmpty || prog.contains("iterm"),
                   isRunning("com.googlecode.iterm2"), run(itermScript(tty)) { return }
                if prog.isEmpty || prog.contains("terminal"),
                   isRunning("com.apple.Terminal"), run(terminalScript(tty)) { return }
            }
            // 2) 其余终端没有可脚本化的标签页模型 → 把对应 app 拉到最前
            if activate(bundleId: bundleId(forTermProgram: prog)) { return }
            // 3) 最后一招: VS Code 插件里的会话既没有 tty 也没有 TERM_PROGRAM,
            //    靠 cwd 命中 ~/.claude/ide/*.lock 的 workspaceFolders 找出是哪个 IDE
            _ = activate(bundleId: ideBundleId(forCwd: cwd))
        }
    }

    // ps -o tty= 的输出形如 s003 / ttys003 / ?? , 统一成 /dev/ttys003
    private static func normalizeTTY(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines),
              !t.isEmpty, t != "??" else { return nil }
        // 只允许安全字符, 免得拼进 AppleScript 字面量里出岔子
        let ok = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/_.-")
        guard t.unicodeScalars.allSatisfy({ ok.contains($0) }) else { return nil }
        if t.hasPrefix("/dev/") { return t }
        if t.hasPrefix("tty")   { return "/dev/" + t }
        return "/dev/tty" + t
    }

    private static func itermScript(_ tty: String) -> String {
        """
        tell application "iTerm2"
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(tty)" then
                  select w
                  select t
                  select s
                  activate
                  return "1"
                end if
              end repeat
            end repeat
          end repeat
        end tell
        return "0"
        """
    }

    private static func terminalScript(_ tty: String) -> String {
        """
        tell application "Terminal"
          repeat with w in windows
            repeat with t in tabs of w
              if tty of t is "\(tty)" then
                set selected tab of w to t
                set index of w to 1
                activate
                return "1"
              end if
            end repeat
          end repeat
        end tell
        return "0"
        """
    }

    // 跑一段 AppleScript, 脚本返回 "1" 视为命中。用 osascript 子进程, 避免 NSAppleScript 的线程限制。
    private static func run(_ source: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text == "1"
    }

    private static func isRunning(_ bundleId: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).isEmpty
    }

    private static func bundleId(forTermProgram prog: String) -> String? {
        guard !prog.isEmpty else { return nil }
        return known.first(where: { $0.keys.contains(where: { prog.contains($0) }) })?.bundleId
    }

    /// 把某个 app 拉到最前。没在跑(或 bundleId 为空)就什么都不做, 绝不顺手启动一个新的。
    @discardableResult
    private static func activate(bundleId: String?) -> Bool {
        guard let id = bundleId,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first
        else { return false }
        app.activate(options: [.activateAllWindows])
        return true
    }

    /// IDE 集成锁: `~/.claude/ide/<port>.lock`, 内容形如
    /// `{"pid":1232,"workspaceFolders":["/Users/…/ragflow"],"ideName":"Visual Studio Code"}`
    /// VS Code 插件里的会话不占终端(tty 和 TERM_PROGRAM 都是空), 只能靠 cwd 命中
    /// workspaceFolders 反推是哪个 IDE。多个窗口都命中时取路径最长的那个(最具体)。
    private static func ideBundleId(forCwd cwd: String?) -> String? {
        guard let cwd = cwd, !cwd.isEmpty else { return nil }
        let dir = home.appendingPathComponent(".claude/ide")
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil) else { return nil }

        var best: (depth: Int, ide: String)?
        for f in files where f.pathExtension == "lock" {
            guard let d = try? Data(contentsOf: f),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                  let folders = o["workspaceFolders"] as? [String] else { continue }
            let ide = (o["ideName"] as? String ?? "").lowercased()
            for folder in folders where cwd == folder || cwd.hasPrefix(folder + "/") {
                if best == nil || folder.count > best!.depth { best = (folder.count, ide) }
            }
        }
        guard let ide = best?.ide else { return nil }
        if ide.contains("cursor") { return "com.todesktop.230313mzl4w4u92" }
        return "com.microsoft.VSCode"   // 认不出来就按 VS Code 试; 它没在跑的话 activate 自己会放弃
    }
}
