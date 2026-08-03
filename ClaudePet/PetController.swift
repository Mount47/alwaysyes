// PetController — 桌面浮动宠物窗口
// 透明、无边框、浮在所有窗口最上层、可鼠标拖到屏幕任意位置(含多显示器)。
// 显示精灵帧(有则优先)或大 emoji 作为宠物形象,
// 有项目在 waiting 时头顶冒气泡显示是哪个项目, 点气泡里的项目名可跳到对应终端。位置持久化。
//
// 鼠标只被"画到实际像素的地方"拦截: 宠物周围的透明区域点击穿透到底下的窗口。

import Cocoa

// 宠物窗口的自定义视图: 画精灵帧(有则优先) 或 emoji 占位, 加可选气泡
class PetView: NSView {
    var emoji: String = "🐣"
    var frame_: NSImage? = nil  // 当前精灵帧; 非 nil 时替代 emoji
    var mask: [Bool]? = nil     // 当前帧的不透明掩膜(SpriteSheet.maskW×maskH), 用于点击穿透
    var waitingProjects: [String] = []  // 正在等确认的项目名(可多个)
    var bubbleVisible: Bool = false     // 气泡是否显示: 仅在悬停/点击时为 true
    var contextMenu: NSMenu?    // 右键菜单(由 AppDelegate 注入)
    var onDesiredHeightChange: ((CGFloat) -> Void)?  // 请求窗口按气泡高度伸缩
    var onProjectClick: ((Int) -> Void)?             // 点了气泡里第 i 行项目

    static let petAreaH: CGFloat = 150  // 底部固定留给宠物, 气泡在其上方, 二者不重叠
    private var trackingArea: NSTrackingArea?
    private var hoverTimer: Timer?      // 点击穿透后 mouseExited 可能收不到, 用轮询兜底收气泡

    // 右键(或 Control+左键)时弹出上下文菜单
    override func menu(for event: NSEvent) -> NSMenu? {
        return contextMenu
    }

    // MARK: - 命中测试: 只有不透明的宠物本体和气泡拦鼠标, 其余区域穿透

    override func hitTest(_ point: NSPoint) -> NSView? {
        let p = convert(point, from: superview)
        return isInteractive(at: p) ? self : nil
    }

    // p 为本视图坐标(左下原点)
    func isInteractive(at p: NSPoint) -> Bool {
        if bubbleVisible, !waitingProjects.isEmpty, bubbleRect().contains(p) { return true }
        let r = petDrawRect()
        guard r.contains(p), r.width > 0, r.height > 0 else { return false }
        guard let mask = mask, mask.count == SpriteSheet.maskW * SpriteSheet.maskH else {
            return true   // emoji 模式 / 没掩膜 → 整块宠物区可点(退回旧行为)
        }
        let nx = (p.x - r.minX) / r.width           // 0..1 左→右
        let ny = (p.y - r.minY) / r.height          // 0..1 下→上
        let mx = min(SpriteSheet.maskW - 1, max(0, Int(nx * CGFloat(SpriteSheet.maskW))))
        let my = min(SpriteSheet.maskH - 1, max(0, Int((1 - ny) * CGFloat(SpriteSheet.maskH))))  // 掩膜行号自上而下
        return mask[my * SpriteSheet.maskW + mx]
    }

    // MARK: - 悬停显隐气泡

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
        let want = visible && !waitingProjects.isEmpty
        guard want != bubbleVisible else { return }
        bubbleVisible = want
        if want { startHoverWatch() } else { stopHoverWatch() }
        onDesiredHeightChange?(desiredHeight())
        needsDisplay = true
    }

    // 气泡打开期间轮询鼠标位置: 一旦离开可交互区域就收起。
    // (透明区域已经穿透, 鼠标从那里离开时系统不会再发 mouseExited 给我们)
    private func startHoverWatch() {
        stopHoverWatch()
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            guard let self = self, let win = self.window else { return }
            let p = self.convert(win.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
            if !self.isInteractive(at: p) { self.setBubble(false) }
        }
    }

    private func stopHoverWatch() {
        hoverTimer?.invalidate()
        hoverTimer = nil
    }

    func closeBubble() { setBubble(false) }

    override func mouseEntered(with event: NSEvent) { setBubble(true) }
    override func mouseExited(with event: NSEvent)  { setBubble(false) }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // 点在气泡的某一行项目上 → 跳到那个终端, 不拖窗口也不收气泡
        if bubbleVisible {
            for (i, r) in bubbleLineRects().enumerated() where r.contains(p) {
                onProjectClick?(i)
                return
            }
        }
        if !waitingProjects.isEmpty { setBubble(!bubbleVisible) }
        super.mouseDown(with: event)   // 不拦截, 保留拖动窗口能力
    }

    // MARK: - 布局计算(draw 和命中测试共用, 避免两处漂移)

    // 宠物本体的绘制矩形(精灵帧优先, 否则 emoji 的外框)
    func petDrawRect() -> NSRect {
        let petH = PetView.petAreaH
        if let frame = frame_ {
            let sz = frame.size
            guard sz.width > 0, sz.height > 0 else { return .zero }
            let scale = min(bounds.width / sz.width, petH / sz.height, 1.0)
            let w = sz.width * scale, h = sz.height * scale
            return NSRect(x: (bounds.width - w) / 2, y: 2, width: w, height: h)
        }
        let size = (emoji as NSString).size(withAttributes: emojiAttrs())
        return NSRect(x: (bounds.width - size.width) / 2, y: 4, width: size.width, height: size.height)
    }

    private func emojiAttrs() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: 44)]
    }

    private func bubbleAttrs() -> [NSAttributedString.Key: Any] {
        [.font: NSFont.boldSystemFont(ofSize: 11), .foregroundColor: NSColor.white]
    }

    private let padX: CGFloat = 8, padY: CGFloat = 4, gap: CGFloat = 2

    // 气泡框尺寸(宽,高); 空列表时为 0
    private func bubbleMetrics() -> (CGFloat, CGFloat) {
        guard !waitingProjects.isEmpty else { return (0, 0) }
        let attrs = bubbleAttrs()
        let sizes = waitingProjects.map { ($0 as NSString).size(withAttributes: attrs) }
        let textW = min(sizes.map { $0.width }.max() ?? 0, bounds.width - 16) // 不超窗宽
        let lineH = sizes.first?.height ?? 14
        let n = CGFloat(waitingProjects.count)
        return (textW + padX * 2, lineH * n + gap * (n - 1) + padY * 2)
    }

    // 气泡外框(视图坐标)
    func bubbleRect() -> NSRect {
        let (bw, bh) = bubbleMetrics()
        guard bw > 0 else { return .zero }
        return NSRect(x: (bounds.width - bw) / 2, y: bounds.height - bh - 2, width: bw, height: bh)
    }

    // 气泡内每行项目的矩形, 顺序与 waitingProjects 一致
    func bubbleLineRects() -> [NSRect] {
        guard !waitingProjects.isEmpty else { return [] }
        let box = bubbleRect()
        guard box.width > 0 else { return [] }
        let lineH = (waitingProjects[0] as NSString).size(withAttributes: bubbleAttrs()).height
        return waitingProjects.indices.map { i in
            let ly = box.maxY - padY - lineH * CGFloat(i + 1) - gap * CGFloat(i)
            return NSRect(x: box.minX, y: ly, width: box.width, height: lineH)
        }
    }

    // 期望窗口高度: 无气泡时只需宠物区; 有气泡时 = 宠物区 + 间隙 + 气泡
    func desiredHeight() -> CGFloat {
        let base = PetView.petAreaH + 4
        guard bubbleVisible, !waitingProjects.isEmpty else { return base }
        let (_, bh) = bubbleMetrics()
        return PetView.petAreaH + 6 + bh
    }

    // MARK: - 绘制

    override func draw(_ dirtyRect: NSRect) {
        // 宠物本体: 固定画在底部 petAreaH 区域内(精灵帧优先, 否则 emoji)
        let r = petDrawRect()
        if let frame = frame_ {
            frame.draw(in: r)
        } else {
            (emoji as NSString).draw(at: r.origin, withAttributes: emojiAttrs())
        }

        // 气泡: 仅在悬停/点击且有等待项目时显示; 逐行列出全部项目, 位于宠物上方不重叠
        guard bubbleVisible, !waitingProjects.isEmpty else { return }
        let box = bubbleRect()
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor(calibratedRed: 0.85, green: 0.2, blue: 0.2, alpha: 0.92).setFill()
        path.fill()
        let attrs = bubbleAttrs()
        for (i, lr) in bubbleLineRects().enumerated() {
            (waitingProjects[i] as NSString).draw(at: NSPoint(x: lr.minX + padX, y: lr.minY), withAttributes: attrs)
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

    // 常态动画/表情 与 一次性动画(庆祝、提醒), 后者在时长内覆盖前者
    private var baseAnim: PetAnim = .idle
    private var baseEmoji = "🐣"
    private var transientAnim: PetAnim?
    private var transientEmoji: String?
    private var transientTimer: Timer?

    // 点了气泡里第 i 行项目时回调(由 AppDelegate 注入, 每次刷新重新绑定当前等待列表)
    var onProjectClick: ((Int) -> Void)? {
        get { view.onProjectClick }
        set { view.onProjectClick = newValue }
    }

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
        w.ignoresMouseEvents = false              // 逐像素穿透由 PetView.hitTest 决定
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
        transientTimer?.invalidate()
        transientTimer = nil
        transientAnim = nil
        transientEmoji = nil
        view.closeBubble()
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
            view.mask = nil
        }
        apply()
    }

    private func startAnimating() {
        animTimer?.invalidate()
        animTimer = Timer.scheduledTimer(withTimeInterval: SpriteSheet.frameInterval, repeats: true) { [weak self] _ in
            guard let self = self, let sp = self.sprite, self.window != nil else { return }
            sp.advance()
            self.view.frame_ = sp.currentFrame()
            self.view.mask = sp.currentMask()
            self.view.needsDisplay = true
        }
    }

    // 更新: emoji 回退文案 + 常态动画 + 等待项目列表(气泡内容, 按需显示)
    func update(emoji: String, anim: PetAnim, waitingProjects: [String]) {
        baseEmoji = emoji
        baseAnim = anim
        view.waitingProjects = waitingProjects
        if waitingProjects.isEmpty && view.bubbleVisible {
            view.closeBubble()                  // 没等待项目 → 收起气泡
            resizeKeepingBottom(to: view.desiredHeight())
        }
        apply()
    }

    // 播放一次性动画(如完成时挥手庆祝、新等待时跳一下), duration 后自动回到常态
    func playOnce(_ anim: PetAnim, emoji: String, duration: TimeInterval) {
        guard window != nil else { return }
        transientTimer?.invalidate()
        transientAnim = anim
        transientEmoji = emoji
        transientTimer = Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            self.transientAnim = nil
            self.transientEmoji = nil
            self.transientTimer = nil
            self.apply()
        }
        apply()
    }

    // 把"一次性动画优先于常态"的结果落到视图上
    private func apply() {
        view.emoji = transientEmoji ?? baseEmoji
        if let sp = sprite {
            sp.setState(transientAnim ?? baseAnim)
            view.frame_ = sp.currentFrame()
            view.mask = sp.currentMask()
        } else {
            view.frame_ = nil
            view.mask = nil
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
