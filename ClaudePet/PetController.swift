// PetController — 桌面浮动宠物窗口
// 透明、无边框、浮在所有窗口最上层、可鼠标拖到屏幕任意位置(含多显示器)。
// 显示一个大 emoji 作为宠物形象(占位, 后续换像素美术/动画帧),
// 有项目在 waiting 时头顶冒气泡显示是哪个项目。位置持久化。

import Cocoa

// 宠物窗口的自定义视图: 画精灵帧(有则优先) 或 emoji 占位, 加可选气泡
class PetView: NSView {
    var emoji: String = "🐣"
    var frame_: NSImage? = nil  // 当前精灵帧; 非 nil 时替代 emoji
    var waitingProjects: [String] = []  // 正在等确认的项目名(可多个)
    var bubbleVisible: Bool = false     // 气泡是否显示: 仅在悬停/点击时为 true
    var contextMenu: NSMenu?    // 右键菜单(由 AppDelegate 注入)
    var onDesiredHeightChange: ((CGFloat) -> Void)?  // 请求窗口按气泡高度伸缩

    static let petAreaH: CGFloat = 150  // 底部固定留给宠物, 气泡在其上方, 二者不重叠
    private var trackingArea: NSTrackingArea?

    // 右键(或 Control+左键)时弹出上下文菜单
    override func menu(for event: NSEvent) -> NSMenu? {
        return contextMenu
    }

    // 悬停进入/离开 → 显隐气泡
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        // 只跟踪底部宠物区域, 避免气泡展开后的空白区误触发
        let petRect = NSRect(x: 0, y: 0, width: bounds.width, height: PetView.petAreaH)
        let ta = NSTrackingArea(rect: petRect,
                                options: [.mouseEnteredAndExited, .activeAlways],
                                owner: self, userInfo: nil)
        addTrackingArea(ta)
        trackingArea = ta
    }

    private func setBubble(_ visible: Bool) {
        guard visible != bubbleVisible else { return }
        bubbleVisible = visible && !waitingProjects.isEmpty
        onDesiredHeightChange?(desiredHeight())
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) { setBubble(true) }
    override func mouseExited(with event: NSEvent)  { setBubble(false) }
    override func mouseDown(with event: NSEvent) {
        if !waitingProjects.isEmpty { setBubble(!bubbleVisible) }
        super.mouseDown(with: event)   // 不拦截, 保留拖动窗口能力
    }

    // 气泡框尺寸(宽,高); 空列表时为 0
    private func bubbleMetrics() -> (CGFloat, CGFloat) {
        guard !waitingProjects.isEmpty else { return (0, 0) }
        let attrs = bubbleAttrs()
        let sizes = waitingProjects.map { ($0 as NSString).size(withAttributes: attrs) }
        let textW = min(sizes.map { $0.width }.max() ?? 0, bounds.width - 16) // 不超窗宽
        let lineH = sizes.first?.height ?? 14
        let n = CGFloat(waitingProjects.count)
        let padX: CGFloat = 8, padY: CGFloat = 4, gap: CGFloat = 2
        return (textW + padX * 2, lineH * n + gap * (n - 1) + padY * 2)
    }

    // 期望窗口高度: 无气泡时只需宠物区; 有气泡时 = 宠物区 + 间隙 + 气泡
    func desiredHeight() -> CGFloat {
        let base = PetView.petAreaH + 4
        guard bubbleVisible, !waitingProjects.isEmpty else { return base }
        let (_, bh) = bubbleMetrics()
        return PetView.petAreaH + 6 + bh
    }

    private func bubbleAttrs() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
    }

    override func draw(_ dirtyRect: NSRect) {
        // 宠物本体: 固定画在底部 petAreaH 区域内(精灵帧优先, 否则 emoji)
        let petH = PetView.petAreaH
        if let frame = frame_ {
            let sz = frame.size
            let scale = min(bounds.width / sz.width, petH / sz.height, 1.0)
            let w = sz.width * scale, h = sz.height * scale
            frame.draw(in: NSRect(x: (bounds.width - w) / 2, y: 2, width: w, height: h))
        } else {
            let petAttrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 44)]
            let petStr = emoji as NSString
            let petSize = petStr.size(withAttributes: petAttrs)
            petStr.draw(at: NSPoint(x: (bounds.width - petSize.width) / 2, y: 4), withAttributes: petAttrs)
        }

        // 气泡: 仅在悬停/点击且有等待项目时显示; 逐行列出全部项目, 位于宠物上方不重叠
        guard bubbleVisible, !waitingProjects.isEmpty else { return }
        let attrs = bubbleAttrs()
        let (bw, bh) = bubbleMetrics()
        let padX: CGFloat = 8, padY: CGFloat = 4, gap: CGFloat = 2
        let lineH = (waitingProjects.first! as NSString).size(withAttributes: attrs).height
        let bx = (bounds.width - bw) / 2
        let by = bounds.height - bh - 2

        let path = NSBezierPath(roundedRect: NSRect(x: bx, y: by, width: bw, height: bh), xRadius: 6, yRadius: 6)
        NSColor(calibratedRed: 0.85, green: 0.2, blue: 0.2, alpha: 0.92).setFill()
        path.fill()
        for (i, line) in waitingProjects.enumerated() {
            let ly = by + bh - padY - lineH * CGFloat(i + 1) - gap * CGFloat(i)
            (line as NSString).draw(at: NSPoint(x: bx + padX, y: ly), withAttributes: attrs)
        }
    }
}

class PetController {
    private var window: NSWindow?
    private let view = PetView()
    private let baseSize = NSSize(width: 150, height: 156)  // 无气泡时: 底部宠物区
    private let posPath = home.appendingPathComponent(".claude/pet-pos.json")
    private var sprite: SpriteSheet?
    private var animTimer: Timer?
    private var currentSpritePath: String?

    // 显示宠物窗口(幂等)
    func show() {
        if window != nil { return }
        let w = NSWindow(
            contentRect: NSRect(origin: .zero, size: baseSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        w.isOpaque = false
        w.backgroundColor = .clear
        w.hasShadow = false
        w.level = .floating                       // 浮在普通窗口之上
        w.isMovableByWindowBackground = true      // 拖背景即可移动窗口
        w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // 所有桌面/全屏都跟随
        w.ignoresMouseEvents = false
        view.frame = NSRect(origin: .zero, size: baseSize)
        w.contentView = view
        w.setFrameOrigin(loadPosition())
        w.orderFrontRegardless()
        window = w

        // 气泡展开/收起时, 保持底边不动、向上伸缩窗口(宠物始终贴底、气泡在其上方)
        view.onDesiredHeightChange = { [weak self] h in
            self?.resizeKeepingBottom(to: h)
        }

        // 拖动结束后记住位置
        NotificationCenter.default.addObserver(
            self, selector: #selector(savePosition),
            name: NSWindow.didMoveNotification, object: w)
    }

    // 改变窗口高度但保持底边固定(原点在左下角, 故底边=origin.y 不变)
    private func resizeKeepingBottom(to height: CGFloat) {
        guard let w = window else { return }
        var f = w.frame
        f.size.height = height
        w.setFrame(f, display: true)              // origin 不变 → 底边不动, 向上伸展
        view.frame = NSRect(origin: .zero, size: f.size)
        view.needsDisplay = true
    }

    func hide() {
        if let w = window {
            NotificationCenter.default.removeObserver(self, name: NSWindow.didMoveNotification, object: w)
            w.orderOut(nil)
        }
        window = nil
        animTimer?.invalidate()
        animTimer = nil
    }

    var isVisible: Bool { window != nil }

    // 注入右键菜单(由 AppDelegate 提供,含"隐藏宠物"等动作)
    func setContextMenu(_ menu: NSMenu) {
        view.contextMenu = menu
    }

    // 加载精灵图(路径变化时才重载)。传 nil 或加载失败 → 回退 emoji 模式
    func loadSprite(path: String?) {
        if path == currentSpritePath { return }
        currentSpritePath = path
        if let p = path, let s = SpriteSheet(path: p) {
            sprite = s
            startAnimating()
        } else {
            sprite = nil
            animTimer?.invalidate(); animTimer = nil
            view.frame_ = nil
        }
    }

    private func startAnimating() {
        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: SpriteSheet.frameInterval, repeats: true) { [weak self] _ in
            guard let self = self, let sp = self.sprite, self.window != nil else { return }
            sp.advance()
            self.view.frame_ = sp.currentFrame()
            self.view.needsDisplay = true
        }
    }

    // 更新: emoji 回退文案 + 动画状态 + 等待项目列表(气泡内容, 按需显示)
    func update(emoji: String, anim: PetAnim, waitingProjects: [String]) {
        view.emoji = emoji
        view.waitingProjects = waitingProjects
        if waitingProjects.isEmpty && view.bubbleVisible {
            view.bubbleVisible = false          // 没等待项目 → 收起气泡
            resizeKeepingBottom(to: view.desiredHeight())
        }
        if let sp = sprite {
            sp.setState(anim)
            view.frame_ = sp.currentFrame()
        } else {
            view.frame_ = nil
        }
        view.needsDisplay = true
    }

    // MARK: - 位置持久化
    @objc private func savePosition() {
        guard let origin = window?.frame.origin else { return }
        let obj: [String: Any] = ["x": origin.x, "y": origin.y]
        if let data = try? JSONSerialization.data(withJSONObject: obj) {
            try? data.write(to: posPath)
        }
    }

    private func loadPosition() -> NSPoint {
        if let data = try? Data(contentsOf: posPath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let x = obj["x"] as? Double, let y = obj["y"] as? Double {
            return NSPoint(x: x, y: y)
        }
        // 默认: 主屏右下角
        if let screen = NSScreen.main {
            let vf = screen.visibleFrame
            return NSPoint(x: vf.maxX - baseSize.width - 40, y: vf.minY + 40)
        }
        return NSPoint(x: 200, y: 200)
    }
}
